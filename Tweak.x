#import 
#import 
#import 

// 1. 顶部横幅（PAC Safe）
static NSTimeInterval gLastBanner = 0;

static void CamHookShowBanner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastBanner < 3.0) return;
        gLastBanner = now;

        UIWindow *win = nil;
        UIWindow *anyWin = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!anyWin) anyWin = w;
                    if (w.isKeyWindow) { win = w; break; }
                }
            }
            if (win) break;
        }
        if (!win) win = anyWin;
        if (!win) return;

        CGFloat width = win.bounds.size.width - 24.0;
        CGFloat topY = win.safeAreaInsets.top > 0 ? win.safeAreaInsets.top : 44.0;

        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(12, -90, width, 60)];
        banner.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        banner.layer.cornerRadius = 14.0;
        banner.clipsToBounds = YES;
        banner.userInteractionEnabled = NO;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, width - 28, 60)];
        label.text = [NSString stringWithUTF8String:"\xE2\x9C\x93 CamHook \xE5\xB7\xB2\xE6\x9B\xBF\xE6\x8D\xA2\xE7\x9B\xB8\xE6\x9C\xBA\xE7\x94\xBB\xE9\x9D\xA2"];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:16.0];
        label.numberOfLines = 2;
        [banner addSubview:label];
        [win addSubview:banner];

        [UIView animateWithDuration:0.35 animations:^{
            banner.frame = CGRectMake(12, topY + 8, width, 60);
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.35 animations:^{
                    banner.frame = CGRectMake(12, -90, width, 60);
                } completion:^(BOOL f2) {
                    [banner removeFromSuperview];
                }];
            });
        }];
    });
}

// 2. 纯 C 状态解码器（无自定义 ObjC 类）
typedef struct {
    AVAsset *asset;
    AVAssetReader *reader;
    AVAssetReaderTrackOutput *output;
    BOOL isInitialized;
} VCamCState;

static VCamCState g_vcam = {nil, nil, nil, NO};

static void InitVCamDecoder(NSString *videoPath) {
    if (g_vcam.isInitialized && g_vcam.reader && g_vcam.reader.status == AVAssetReaderStatusReading) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:videoPath]) {
        os_log(OS_LOG_DEFAULT, "[CamHook] ⚠️ 找不到视频文件: %{public}@", videoPath);
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:videoPath];
    g_vcam.asset = [AVAsset assetWithURL:url];
    
    NSError *error = nil;
    g_vcam.reader = [[AVAssetReader alloc] initWithAsset:g_vcam.asset error:&error];
    if (error || !g_vcam.reader) {
        os_log(OS_LOG_DEFAULT, "[CamHook] ❌ AVAssetReader 创建失败");
        return;
    }

    AVAssetTrack *videoTrack = [[g_vcam.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) return;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };

    g_vcam.output = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    if ([g_vcam.reader canAddOutput:g_vcam.output]) {
        [g_vcam.reader addOutput:g_vcam.output];
        [g_vcam.reader startReading];
        g_vcam.isInitialized = YES;
        os_log(OS_LOG_DEFAULT, "[CamHook] ✅ C 解码器初始化成功");
    }
}

static CMSampleBufferRef CopyVideoBufferWithCameraTiming(CMSampleBufferRef origSampleBuffer) {
    if (!g_vcam.isInitialized || !g_vcam.output) {
        return NULL;
    }

    CMSampleBufferRef videoSampleBuffer = [g_vcam.output copyNextSampleBuffer];
    
    if (!videoSampleBuffer) {
        g_vcam.isInitialized = NO;
        InitVCamDecoder(@"/var/mobile/demo.mp4");
        if (g_vcam.output) {
            videoSampleBuffer = [g_vcam.output copyNextSampleBuffer];
        }
    }

    if (!videoSampleBuffer) return NULL;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer);
    if (!imageBuffer) {
        CFRelease(videoSampleBuffer);
        return NULL;
    }

    CMSampleTimingInfo timingInfo;
    CMSampleBufferGetSampleTimingInfo(origSampleBuffer, 0, &timingInfo);

    CMVideoFormatDescriptionRef formatDescription = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &formatDescription);

    CMSampleBufferRef customSampleBuffer = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                       imageBuffer,
                                       true,
                                       NULL,
                                       NULL,
                                       formatDescription,
                                       &timingInfo,
                                       &customSampleBuffer);

    if (formatDescription) CFRelease(formatDescription);
    CFRelease(videoSampleBuffer);

    return customSampleBuffer;
}

// 3. Hooks
%hook AVCaptureSession

- (void)startRunning {
    %orig;
    os_log(OS_LOG_DEFAULT, "[CamHook] Session startRunning");
    CamHookShowBanner();
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    InitVCamDecoder(@"/var/mobile/demo.mp4");
    os_log(OS_LOG_DEFAULT, "[CamHook] setSampleBufferDelegate 已拦截");
    %orig;
}

%end

%hookf(void, "-[NSObject captureOutput:didOutputSampleBuffer:fromConnection:]", id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    
    if (!sampleBuffer) {
        %orig(self, _cmd, output, sampleBuffer, connection);
        return;
    }

    CMSampleBufferRef replacementBuffer = CopyVideoBufferWithCameraTiming(sampleBuffer);
    
    if (replacementBuffer) {
        %orig(self, _cmd, output, replacementBuffer, connection);
        CFRelease(replacementBuffer);
    } else {
        %orig(self, _cmd, output, sampleBuffer, connection);
    }
}

%ctor {
    os_log(OS_LOG_DEFAULT, "[CamHook] 画面替换版 (C-Decoder) 已加载");
}