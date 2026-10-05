// CamHook 换帧版 —— 在日志版基础上增加 VCamProvider + 帧替换
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <objc/runtime.h>
#import "VCamProvider.h"

// ===================== 全局 =====================
static VCamProvider *gProvider = NULL;
static NSTimeInterval gLastBanner = 0;

// 测试视频路径
static const char *kTestVideoPath = "/var/mobile/Media/test.mp4";

// ===================== 横幅 =====================
static void CamHookShowBanner(const char *msg) {
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
        label.text = [NSString stringWithUTF8String:msg];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:15.0];
        label.numberOfLines = 2;
        [banner addSubview:label];
        [win addSubview:banner];

        [UIView animateWithDuration:0.35 animations:^{
            banner.frame = CGRectMake(12, topY + 8, width, 60);
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
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

// ===================== 创建替换后的 CMSampleBuffer =====================
static CMSampleBufferRef CamHookCreateSampleBuffer(CVPixelBufferRef pixelBuffer,
                                                   CMTime pts,
                                                   CMTime duration) {
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                    pixelBuffer,
                                                                    &formatDesc);
    if (status != noErr || !formatDesc) {
        os_log(OS_LOG_DEFAULT, "[CamHook] CreateForImageBuffer format failed: %d", (int)status);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef newBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                                pixelBuffer,
                                                true,
                                                NULL, NULL,
                                                formatDesc,
                                                &timing,
                                                &newBuffer);
    CFRelease(formatDesc);

    if (status != noErr) {
        os_log(OS_LOG_DEFAULT, "[CamHook] CMSampleBufferCreateForImageBuffer failed: %d", (int)status);
        return NULL;
    }
    return newBuffer;
}

// ===================== 轻量 Proxy Delegate =====================
@interface CamHookProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, strong) dispatch_queue_t realQueue;
@end

@implementation CamHookProxy

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if (!gProvider || !VCamProviderIsReady(gProvider)) {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
        return;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    if (CMTIME_IS_INVALID(duration) || CMTimeCompare(duration, kCMTimeZero) == 0) {
        duration = CMTimeMake(1, 30);
    }

    CVPixelBufferRef videoPB = VCamProviderCopyPixelBufferForTime(gProvider, pts);
    if (videoPB) {
        CMSampleBufferRef fake = CamHookCreateSampleBuffer(videoPB, pts, duration);
        CFRelease(videoPB);

        if (fake) {
            if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.realDelegate captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
            }
            CFRelease(fake);
            return;
        }
    }

    if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if ([self.realDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

// ===================== Hooks =====================
%hook AVCaptureSession
- (void)startRunning {
    %orig;

    // 每次打开相机都重新尝试加载视频（方便调试）
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    gProvider = VCamProviderCreate(kTestVideoPath);

    if (gProvider && VCamProviderIsReady(gProvider)) {
        CamHookShowBanner("\xE2\x9C\x93 CamHook \xE6\x8D\xA2\xE5\xB8\xA7\xE6\xA8\xA1\xE5\xBC\x8F\xE5\xB7\xB2\xE5\x90\xAF\xE7\x94\xA8");
        os_log(OS_LOG_DEFAULT, "[CamHook] startRunning + VCam ready");
    } else {
        CamHookShowBanner("\xE2\x9C\x93 CamHook \xE5\xB7\xB2\xE5\x8A\xA0\xE8\xBD\xBD (\xE6\x97\xA0\xE8\xA7\x86\xE9\xA2\x91)");
        os_log(OS_LOG_DEFAULT, "[CamHook] startRunning but VCam FAILED, path=%s", kTestVideoPath);
    }
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    os_log(OS_LOG_DEFAULT, "[CamHook] setSampleBufferDelegate: %{public}@ queue=%p",
           NSStringFromClass(object_getClass(sampleBufferDelegate)), sampleBufferCallbackQueue);

    if (sampleBufferDelegate && sampleBufferCallbackQueue) {
        CamHookProxy *proxy = [CamHookProxy new];
        proxy.realDelegate = sampleBufferDelegate;
        proxy.realQueue = sampleBufferCallbackQueue;

        objc_setAssociatedObject(self, "camhook_proxy", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        %orig(proxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

%ctor {
    os_log(OS_LOG_DEFAULT, "[CamHook] 换帧版已加载 (VCamProvider + Proxy)");
}
