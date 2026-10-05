#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VCamProvider VCamProvider;

/// 创建。path 为本地 MP4 绝对路径。失败返回 NULL。
VCamProvider *VCamProviderCreate(const char *mp4Path);

/// 销毁
void VCamProviderDestroy(VCamProvider *p);

/// 根据相机回调的 PTS 取对应视频帧（内部做循环 + 时间对齐）
/// 返回的 CVPixelBuffer 需要调用方 CFRelease
CVPixelBufferRef VCamProviderCopyPixelBufferForTime(VCamProvider *p, CMTime cameraPts);

/// 强制重新从头开始
void VCamProviderReset(VCamProvider *p);

/// 是否已成功加载视频
bool VCamProviderIsReady(VCamProvider *p);

#ifdef __cplusplus
}
#endif