#import "VCamProvider.h"
#import <os/log.h>
#import <pthread.h>

struct VCamProvider {
    AVAsset           *asset;
    AVAssetReader     *reader;
    AVAssetReaderTrackOutput *output;
    CMTime             duration;
    CMTime             frameDuration;
    CMTime             firstCameraPts;
    bool               hasFirstPts;
    bool               loop;
    char              *path;
    pthread_mutex_t    lock;
    int                width;
    int                height;
};

static bool VCamProviderRestartReader(VCamProvider *p) {
    if (!p || !p->asset) return false;

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:p->asset error:&err];
    if (!reader || err) {
        os_log(OS_LOG_DEFAULT, "[CamHook] AVAssetReader create failed: %{public}@", err);
        return false;
    }

    AVAssetTrack *track = [[p->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        os_log(OS_LOG_DEFAULT, "[CamHook] no video track");
        return false;
    }

    // 优先用相机常见的 YUV 格式，减少后续转换
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;   // 性能更好

    if (![reader canAddOutput:output]) {
        os_log(OS_LOG_DEFAULT, "[CamHook] cannot add output");
        return false;
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        os_log(OS_LOG_DEFAULT, "[CamHook] startReading failed: %{public}@", reader.error);
        return false;
    }

    p->reader = reader;
    p->output = output;
    return true;
}

VCamProvider *VCamProviderCreate(const char *mp4Path) {
    if (!mp4Path || strlen(mp4Path) == 0) return NULL;

    VCamProvider *p = (VCamProvider *)calloc(1, sizeof(VCamProvider));
    if (!p) return NULL;

    pthread_mutex_init(&p->lock, NULL);
    p->loop = true;
    p->path = strdup(mp4Path);

    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:mp4Path]];
    p->asset = [AVAsset assetWithURL:url];
    if (!p->asset) {
        os_log(OS_LOG_DEFAULT, "[CamHook] asset load failed: %s", mp4Path);
        VCamProviderDestroy(p);
        return NULL;
    }

    // 同步拿 duration（简单测试够用）
    p->duration = p->asset.duration;
    if (CMTIME_IS_INVALID(p->duration) || CMTimeCompare(p->duration, kCMTimeZero) <= 0) {
        os_log(OS_LOG_DEFAULT, "[CamHook] invalid duration");
        VCamProviderDestroy(p);
        return NULL;
    }

    AVAssetTrack *track = [[p->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (track) {
        float fps = track.nominalFrameRate;
        if (fps < 1.0f) fps = 30.0f;
        p->frameDuration = CMTimeMake(1, (int32_t)fps);
        CGSize size = track.naturalSize;
        p->width  = (int)size.width;
        p->height = (int)size.height;
    } else {
        p->frameDuration = CMTimeMake(1, 30);
    }

    if (!VCamProviderRestartReader(p)) {
        VCamProviderDestroy(p);
        return NULL;
    }

    os_log(OS_LOG_DEFAULT, "[CamHook] VCamProvider ready: %s  %dx%d  duration=%.2fs",
           mp4Path, p->width, p->height, CMTimeGetSeconds(p->duration));
    return p;
}

void VCamProviderDestroy(VCamProvider *p) {
    if (!p) return;
    pthread_mutex_lock(&p->lock);
    p->reader = nil;
    p->output = nil;
    p->asset = nil;
    free(p->path);
    pthread_mutex_unlock(&p->lock);
    pthread_mutex_destroy(&p->lock);
    free(p);
}

void VCamProviderReset(VCamProvider *p) {
    if (!p) return;
    pthread_mutex_lock(&p->lock);
    p->hasFirstPts = false;
    VCamProviderRestartReader(p);
    pthread_mutex_unlock(&p->lock);
}

bool VCamProviderIsReady(VCamProvider *p) {
    return p && p->reader && p->output;
}

CVPixelBufferRef VCamProviderCopyPixelBufferForTime(VCamProvider *p, CMTime cameraPts) {
    if (!p) return NULL;

    pthread_mutex_lock(&p->lock);

    if (!p->hasFirstPts) {
        p->firstCameraPts = cameraPts;
        p->hasFirstPts = true;
    }

    // 用相机真实时间推进，视频循环
    CMTime elapsed = CMTimeSubtract(cameraPts, p->firstCameraPts);
    if (CMTimeCompare(elapsed, kCMTimeZero) < 0) elapsed = kCMTimeZero;

    CMTime videoTime = elapsed;
    if (p->loop && CMTIME_IS_VALID(p->duration) && CMTimeCompare(p->duration, kCMTimeZero) > 0) {
        // 简单模运算实现循环
        Float64 sec = fmod(CMTimeGetSeconds(elapsed), CMTimeGetSeconds(p->duration));
        videoTime = CMTimeMakeWithSeconds(sec, p->duration.timescale);
    }

    // 这里用「连续取下一帧」近似对齐（简单可靠）
    // 更精确可用 AVAssetReader 的 timeRange + seek，但开销更大
    CMSampleBufferRef sb = [p->output copyNextSampleBuffer];
    if (!sb) {
        // 读到结尾，循环重启
        if (p->loop) {
            os_log(OS_LOG_DEFAULT, "[CamHook] video ended, restart loop");
            VCamProviderRestartReader(p);
            sb = [p->output copyNextSampleBuffer];
        }
    }

    CVPixelBufferRef pb = NULL;
    if (sb) {
        pb = CMSampleBufferGetImageBuffer(sb);
        if (pb) {
            CFRetain(pb);   // 调用方负责 Release
        }
        CFRelease(sb);
    }

    pthread_mutex_unlock(&p->lock);
    return pb;
}