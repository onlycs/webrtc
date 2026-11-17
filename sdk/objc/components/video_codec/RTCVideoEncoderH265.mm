/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCVideoEncoderH265.h"

#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <vector>

#if defined(WEBRTC_IOS)
#import "helpers/UIDevice+RTCDevice.h"
#endif
#import "RTCCodecSpecificInfoH265.h"
#import "RTCH265ProfileLevelId.h"
#import "api/peerconnection/RTCVideoCodecInfo+Private.h"
#import "base/RTCCodecSpecificInfo.h"
#import "base/RTCI420Buffer.h"
#import "base/RTCVideoEncoder.h"
#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"
#import "helpers.h"

#include "api/video/video_timing.h"
#include "api/video_codecs/h265_profile_tier_level.h"
#include "common_video/h265/h265_bitstream_parser.h"
#include "common_video/include/bitrate_adjuster.h"
#include "media/base/media_constants.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/buffer.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"
#include "sdk/objc/components/video_codec/nalu_rewriter.h"
#include "system_wrappers/include/clock.h"
#include "third_party/libyuv/include/libyuv/convert_from.h"

@interface RTC_OBJC_TYPE (RTCVideoEncoderH265)
()

    - (void)frameWasEncoded : (OSStatus)status flags
    : (VTEncodeInfoFlags)infoFlags sampleBuffer
    : (CMSampleBufferRef)sampleBuffer codecSpecificInfo
    : (id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo width
    : (int32_t)width height : (int32_t)height renderTimeMs
    : (int64_t)renderTimeMs timestamp : (uint32_t)timestamp rotation
    : (RTCVideoRotation)rotation;

@end

namespace {  // anonymous namespace

// The ratio between kVTCompressionPropertyKey_DataRateLimits and
// kVTCompressionPropertyKey_AverageBitRate. The data rate limit is set higher
// than the average bit rate to avoid undershooting the target.
const float kLimitToAverageBitRateFactor = 1.5f;
// H265 uses the same QP range as H264, so use the thresholds that have been
// found to work well for the VideoToolbox H264 encoder.
const int kLowH265QpThreshold = 28;
const int kHighH265QpThreshold = 39;
// The resolution used to probe for a hardware encoder. This matches the
// largest resolution allowed by level 3.1.
const int32_t kProbeWidth = 1280;
const int32_t kProbeHeight = 720;

const OSType kNV12PixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

// Struct that we pass to the encoder per frame to encode. We receive it again
// in the encoder callback.
struct RTCFrameEncodeParams {
  RTCFrameEncodeParams(RTC_OBJC_TYPE(RTCVideoEncoderH265) * e,
                       RTC_OBJC_TYPE(RTCCodecSpecificInfoH265) * csi,
                       int32_t w,
                       int32_t h,
                       int64_t rtms,
                       uint32_t ts,
                       RTCVideoRotation r)
      : encoder(e),
        width(w),
        height(h),
        render_time_ms(rtms),
        timestamp(ts),
        rotation(r) {
    if (csi) {
      codecSpecificInfo = csi;
    } else {
      codecSpecificInfo =
          [[RTC_OBJC_TYPE(RTCCodecSpecificInfoH265) alloc] init];
    }
  }

  RTC_OBJC_TYPE(RTCVideoEncoderH265) * encoder;
  RTC_OBJC_TYPE(RTCCodecSpecificInfoH265) * codecSpecificInfo;
  int32_t width;
  int32_t height;
  int64_t render_time_ms;
  uint32_t timestamp;
  RTCVideoRotation rotation;
};

// We receive I420Frames as input, but we need to feed CVPixelBuffers into the
// encoder. This performs the copy and format conversion.
// TODO(tkchin): See if encoder will accept i420 frames and compare performance.
bool CopyVideoFrameToNV12PixelBuffer(
    id<RTC_OBJC_TYPE(RTCI420Buffer)> frameBuffer,
    CVPixelBufferRef pixelBuffer) {
  RTC_DCHECK(pixelBuffer);
  RTC_DCHECK_EQ(CVPixelBufferGetPixelFormatType(pixelBuffer), kNV12PixelFormat);
  RTC_DCHECK_EQ(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                frameBuffer.height);
  RTC_DCHECK_EQ(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                frameBuffer.width);

  CVReturn cvRet = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  if (cvRet != kCVReturnSuccess) {
    RTC_LOG(LS_ERROR) << "Failed to lock base address: " << cvRet;
    return false;
  }
  uint8_t *dstY = reinterpret_cast<uint8_t *>(
      CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
  int dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  uint8_t *dstUV = reinterpret_cast<uint8_t *>(
      CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
  int dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  // Convert I420 to NV12.
  int ret = libyuv::I420ToNV12(frameBuffer.dataY,
                               frameBuffer.strideY,
                               frameBuffer.dataU,
                               frameBuffer.strideU,
                               frameBuffer.dataV,
                               frameBuffer.strideV,
                               dstY,
                               dstStrideY,
                               dstUV,
                               dstStrideUV,
                               frameBuffer.width,
                               frameBuffer.height);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  if (ret) {
    RTC_LOG(LS_ERROR) << "Error converting I420 VideoFrame to NV12 :" << ret;
    return false;
  }
  return true;
}

CVPixelBufferRef CreatePixelBuffer(
    VTCompressionSessionRef compression_session) {
  if (!compression_session) {
    RTC_LOG(LS_ERROR) << "Failed to get compression session.";
    return nullptr;
  }
  CVPixelBufferPoolRef pixel_buffer_pool =
      VTCompressionSessionGetPixelBufferPool(compression_session);

  if (!pixel_buffer_pool) {
    RTC_LOG(LS_ERROR) << "Failed to get pixel buffer pool.";
    return nullptr;
  }
  CVPixelBufferRef pixel_buffer;
  CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(
      nullptr, pixel_buffer_pool, &pixel_buffer);
  if (ret != kCVReturnSuccess) {
    RTC_LOG(LS_ERROR) << "Failed to create pixel buffer: " << ret;
    // We probably want to drop frames here, since failure probably means
    // that the pool is empty.
    return nullptr;
  }
  return pixel_buffer;
}

// This is the callback function that VideoToolbox calls when encode is
// complete. From inspection this happens on its own queue.
void compressionOutputCallback(void *encoder,
                               void *params,
                               OSStatus status,
                               VTEncodeInfoFlags infoFlags,
                               CMSampleBufferRef sampleBuffer) {
  if (!params) {
    // If there are pending callbacks when the encoder is destroyed, this can
    // happen.
    return;
  }
  std::unique_ptr<RTCFrameEncodeParams> encodeParams(
      reinterpret_cast<RTCFrameEncodeParams *>(params));
  [encodeParams->encoder frameWasEncoded:status
                                   flags:infoFlags
                            sampleBuffer:sampleBuffer
                       codecSpecificInfo:encodeParams->codecSpecificInfo
                                   width:encodeParams->width
                                  height:encodeParams->height
                            renderTimeMs:encodeParams->render_time_ms
                               timestamp:encodeParams->timestamp
                                rotation:encodeParams->rotation];
}

// Returns the encoder specification to create compression sessions with.
// H265 must only ever be encoded in hardware.
NSDictionary *EncoderSpecification() {
#if defined(WEBRTC_MAC) && !defined(WEBRTC_IOS)
  return @{
    (NSString *)
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @(YES),
  };
#else
  // On iOS the hardware requirement can't be expressed up front on all
  // supported OS versions, so it is checked after the session is created
  // instead, see `IsUsingHardwareEncoder`.
  return nil;
#endif
}

// Returns true if `compressionSession` is backed by a hardware encoder.
bool IsUsingHardwareEncoder(VTCompressionSessionRef compressionSession) {
  CFBooleanRef hwacclEnabled = nullptr;
  OSStatus status = kVTPropertyNotSupportedErr;
  if (@available(iOS 17.4, macCatalyst 17.4, *)) {
    status = VTSessionCopyProperty(
        compressionSession,
        kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        nullptr,
        &hwacclEnabled);
  }
  if (status != noErr || !hwacclEnabled) {
#if defined(WEBRTC_IOS) && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    // iOS devices only have hardware H265 encoders, so a session that doesn't
    // report the property is still a hardware one.
    return true;
#else
    return false;
#endif
  }
  bool isHardware = CFBooleanGetValue(hwacclEnabled);
  CFRelease(hwacclEnabled);
  return isHardware;
}

// Returns true if a hardware H265 encoder can be created on this device.
bool HasHardwareEncoder() {
  VTCompressionSessionRef compressionSession = nullptr;
  OSStatus status = VTCompressionSessionCreate(
      nullptr,  // use default allocator
      kProbeWidth,
      kProbeHeight,
      kCMVideoCodecType_HEVC,
      (__bridge CFDictionaryRef)EncoderSpecification(),
      nullptr,  // no source image buffer attributes
      nullptr,  // use default compressed data allocator
      nullptr,  // no frames are encoded, so no output callback is needed
      nullptr,
      &compressionSession);
  if (status != noErr || !compressionSession) {
    RTC_LOG(LS_INFO) << "No H265 encoder available: " << status;
    return false;
  }
  bool isHardware = IsUsingHardwareEncoder(compressionSession);
  VTCompressionSessionInvalidate(compressionSession);
  CFRelease(compressionSession);
  if (!isHardware) {
    RTC_LOG(LS_INFO) << "H265 encoder is not hardware accelerated.";
  }
  return isHardware;
}
}  // namespace

@implementation RTC_OBJC_TYPE (RTCVideoEncoderH265) {
  RTC_OBJC_TYPE(RTCVideoCodecInfo) * _codecInfo;
  std::unique_ptr<webrtc::BitrateAdjuster> _bitrateAdjuster;
  uint32_t _targetBitrateBps;
  uint32_t _encoderBitrateBps;
  uint32_t _encoderFrameRate;
  RTCVideoEncoderCallback _callback;
  int32_t _width;
  int32_t _height;
  VTCompressionSessionRef _compressionSession;
  RTCVideoCodecMode _mode;

  webrtc::H265BitstreamParser _h265BitstreamParser;
  std::vector<uint8_t> _frameScaleBuffer;
}

+ (BOOL)isSupported {
  // Only cache success: probing can fail transiently (e.g. while the app is
  // in the background for an incoming call), and that must not disable H265
  // for the rest of the process.
  static std::atomic<bool> supported{false};
  if (supported.load(std::memory_order_relaxed)) {
    return YES;
  }
  if (!HasHardwareEncoder()) {
    return NO;
  }
  supported.store(true, std::memory_order_relaxed);
  return YES;
}

+ (NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo) *> *)supportedCodecs {
  if (![self isSupported]) {
    return @[];
  }

  // Main profile, Main tier, level 3.1 (720p).
  NSDictionary<NSString *, NSString *> *mainParams = @{
    @(webrtc::kH265FmtpProfileId) :
        @(webrtc::H265ProfileToString(webrtc::H265Profile::kProfileMain)
              .c_str()),
    @(webrtc::kH265FmtpTierFlag) :
        @(webrtc::H265TierToString(webrtc::H265Tier::kTier0).c_str()),
    @(webrtc::kH265FmtpLevelId) :
        @(webrtc::H265LevelToString(webrtc::H265Level::kLevel3_1).c_str()),
    @(webrtc::kH265FmtpTxMode) : @"SRST",
  };
  RTC_OBJC_TYPE(RTCVideoCodecInfo) *mainInfo =
      [[RTC_OBJC_TYPE(RTCVideoCodecInfo) alloc]
          initWithName:kRTCVideoCodecH265Name
            parameters:mainParams];

  return @[ mainInfo ];
}

// .5 is set as a mininum to prevent overcompensating for large temporary
// overshoots. We don't want to degrade video quality too badly.
// .95 is set to prevent oscillations. When a lower bitrate is set on the
// encoder than previously set, its output seems to have a brief period of
// drastically reduced bitrate, so we want to avoid that. In steady state
// conditions, 0.95 seems to give us better overall bitrate over long periods
// of time.
- (instancetype)initWithCodecInfo:
    (RTC_OBJC_TYPE(RTCVideoCodecInfo) *)codecInfo {
  self = [super init];
  if (self) {
    _codecInfo = codecInfo;
    _bitrateAdjuster = std::make_unique<webrtc::BitrateAdjuster>(
        webrtc::Clock::GetRealTimeClock(), .5, .95);
    RTC_CHECK([codecInfo.name isEqualToString:kRTCVideoCodecH265Name]);
  }
  return self;
}

- (void)dealloc {
  [self destroyCompressionSession];
}

- (NSInteger)startEncodeWithSettings:
                 (RTC_OBJC_TYPE(RTCVideoEncoderSettings) *)settings
                       numberOfCores:(int)numberOfCores {
  RTC_DCHECK(settings);
  RTC_DCHECK([settings.name isEqualToString:kRTCVideoCodecH265Name]);

  _width = settings.width;
  _height = settings.height;
  _mode = settings.mode;

  // We can only set average bitrate on the HW encoder.
  _targetBitrateBps = settings.startBitrate * 1000;  // startBitrate is in kbps.
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  _encoderFrameRate = settings.maxFramerate;

  return [self resetCompressionSessionWithPixelFormat:kNV12PixelFormat];
}

- (NSInteger)encode:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
    codecSpecificInfo:
        (nullable id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
  if (!_callback || !_compressionSession) {
    return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
  }
  BOOL isKeyframeRequired = NO;

  // Get a pixel buffer from the pool and copy frame data over.
  if ([self resetCompressionSessionIfNeededWithFrame:frame]) {
    isKeyframeRequired = YES;
  }

  CVPixelBufferRef pixelBuffer = nullptr;
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    // Native frame buffer
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *rtcPixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    if (![rtcPixelBuffer requiresCropping]) {
      // This pixel buffer might have a higher resolution than what the
      // compression session is configured to. The compression session can
      // handle that and will output encoded frames in the configured
      // resolution regardless of the input pixel buffer resolution.
      pixelBuffer = rtcPixelBuffer.pixelBuffer;
      CVBufferRetain(pixelBuffer);
    } else {
      // Cropping required, we need to crop and scale to a new pixel buffer.
      pixelBuffer = CreatePixelBuffer(_compressionSession);
      if (!pixelBuffer) {
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
      int dstWidth = CVPixelBufferGetWidth(pixelBuffer);
      int dstHeight = CVPixelBufferGetHeight(pixelBuffer);
      if ([rtcPixelBuffer requiresScalingToWidth:dstWidth height:dstHeight]) {
        int size =
            [rtcPixelBuffer bufferSizeForCroppingAndScalingToWidth:dstWidth
                                                            height:dstHeight];
        _frameScaleBuffer.resize(size);
      } else {
        _frameScaleBuffer.clear();
      }
      _frameScaleBuffer.shrink_to_fit();
      if (![rtcPixelBuffer cropAndScaleTo:pixelBuffer
                           withTempBuffer:_frameScaleBuffer.data()]) {
        CVBufferRelease(pixelBuffer);
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
    }
  }

  if (!pixelBuffer) {
    // We did not have a native frame buffer
    RTC_DCHECK_EQ(frame.width, _width);
    RTC_DCHECK_EQ(frame.height, _height);

    pixelBuffer = CreatePixelBuffer(_compressionSession);
    if (!pixelBuffer) {
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    RTC_DCHECK(pixelBuffer);
    if (!CopyVideoFrameToNV12PixelBuffer([frame.buffer toI420], pixelBuffer)) {
      RTC_LOG(LS_ERROR) << "Failed to copy frame data.";
      CVBufferRelease(pixelBuffer);
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
  }

  // Check if we need a keyframe.
  if (!isKeyframeRequired && frameTypes) {
    for (NSNumber *frameType in frameTypes) {
      if ((RTCFrameType)frameType.intValue == RTCFrameTypeVideoFrameKey) {
        isKeyframeRequired = YES;
        break;
      }
    }
  }

  CMTime presentationTimeStamp =
      CMTimeMake(frame.timeStampNs / webrtc::kNumNanosecsPerMillisec, 1000);
  CFDictionaryRef frameProperties = nullptr;
  if (isKeyframeRequired) {
    CFTypeRef keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
    CFTypeRef values[] = {kCFBooleanTrue};
    frameProperties = CreateCFTypeDictionary(keys, values, 1);
  }

  std::unique_ptr<RTCFrameEncodeParams> encodeParams;
  encodeParams.reset(new RTCFrameEncodeParams(
      self,
      codecSpecificInfo,
      _width,
      _height,
      frame.timeStampNs / webrtc::kNumNanosecsPerMillisec,
      frame.timeStamp,
      frame.rotation));

  // Update the bitrate if needed.
  [self setBitrateBps:_bitrateAdjuster->GetAdjustedBitrateBps()
            frameRate:_encoderFrameRate];

  OSStatus status = VTCompressionSessionEncodeFrame(_compressionSession,
                                                    pixelBuffer,
                                                    presentationTimeStamp,
                                                    kCMTimeInvalid,
                                                    frameProperties,
                                                    encodeParams.release(),
                                                    nullptr);
  if (frameProperties) {
    CFRelease(frameProperties);
  }
  if (pixelBuffer) {
    CVBufferRelease(pixelBuffer);
  }

  if (status == kVTInvalidSessionErr) {
    // This error occurs when entering foreground after backgrounding the app.
    RTC_LOG(LS_ERROR) << "Invalid compression session, resetting.";
    [self
        resetCompressionSessionWithPixelFormat:[self pixelFormatOfFrame:frame]];

    return WEBRTC_VIDEO_CODEC_NO_OUTPUT;
  } else if (status == kVTVideoEncoderMalfunctionErr) {
    // Sometimes the encoder malfunctions and needs to be restarted.
    RTC_LOG(LS_ERROR) << "Encountered video encoder malfunction error. "
                         "Resetting compression session.";
    [self
        resetCompressionSessionWithPixelFormat:[self pixelFormatOfFrame:frame]];

    return WEBRTC_VIDEO_CODEC_NO_OUTPUT;
  } else if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to encode frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoEncoderCallback)callback {
  _callback = callback;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
  _targetBitrateBps = 1000 * bitrateKbit;
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  [self setBitrateBps:_bitrateAdjuster->GetAdjustedBitrateBps()
            frameRate:framerate];
  return WEBRTC_VIDEO_CODEC_OK;
}

- (NSInteger)resolutionAlignment {
  return 1;
}

- (BOOL)applyAlignmentToAllSimulcastLayers {
  return NO;
}

- (BOOL)supportsNativeHandle {
  return YES;
}

#pragma mark - Private

- (NSInteger)releaseEncoder {
  // Need to destroy so that the session is invalidated and won't use the
  // callback anymore. Do not remove callback until the session is invalidated
  // since async encoder callbacks can occur until invalidation.
  [self destroyCompressionSession];
  _callback = nullptr;
  return WEBRTC_VIDEO_CODEC_OK;
}

- (OSType)pixelFormatOfFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  // Use NV12 for non-native frames.
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *rtcPixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    return CVPixelBufferGetPixelFormatType(rtcPixelBuffer.pixelBuffer);
  }

  return kNV12PixelFormat;
}

- (BOOL)resetCompressionSessionIfNeededWithFrame:
    (RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  BOOL resetCompressionSession = NO;

  // If we're capturing native frames in another pixel format than the
  // compression session is configured with, make sure the compression session
  // is reset using the correct pixel format.
  OSType framePixelFormat = [self pixelFormatOfFrame:frame];

  if (_compressionSession) {
    // The pool attribute `kCVPixelBufferPixelFormatTypeKey` can contain either
    // an array of pixel formats or a single pixel format.

    CVPixelBufferPoolRef pixelBufferPool =
        VTCompressionSessionGetPixelBufferPool(_compressionSession);
    if (!pixelBufferPool) {
      // If we have a compression session but can't acquire the pixel buffer
      // pool, we're in an invalid state and should reset.
      resetCompressionSession = YES;
    } else {
      NSDictionary *poolAttributes =
          (__bridge NSDictionary *)CVPixelBufferPoolGetPixelBufferAttributes(
              pixelBufferPool);
      id pixelFormats = [poolAttributes
          objectForKey:(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey];
      NSArray<NSNumber *> *compressionSessionPixelFormats = nil;
      if ([pixelFormats isKindOfClass:[NSArray class]]) {
        compressionSessionPixelFormats = (NSArray *)pixelFormats;
      } else if ([pixelFormats isKindOfClass:[NSNumber class]]) {
        compressionSessionPixelFormats = @[ (NSNumber *)pixelFormats ];
      }

      if (![compressionSessionPixelFormats
              containsObject:[NSNumber numberWithLong:framePixelFormat]]) {
        resetCompressionSession = YES;
        RTC_LOG(LS_INFO) << "Resetting compression session due to non-matching "
                            "pixel format.";
      }
    }
  } else {
    resetCompressionSession = YES;
  }

  if (resetCompressionSession) {
    [self resetCompressionSessionWithPixelFormat:framePixelFormat];
  }
  return resetCompressionSession;
}

- (int)resetCompressionSessionWithPixelFormat:(OSType)framePixelFormat {
  [self destroyCompressionSession];

  // Set source image buffer attributes. These attributes will be present on
  // buffers retrieved from the encoder's pixel buffer pool.
  NSDictionary *sourceAttributes = @{
#if defined(WEBRTC_IOS) && (TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR)
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @(YES),
#elif defined(WEBRTC_IOS)
    (NSString *)kCVPixelBufferOpenGLESCompatibilityKey : @(YES),
#elif defined(WEBRTC_MAC) && !defined(WEBRTC_ARCH_ARM64)
    (NSString *)kCVPixelBufferOpenGLCompatibilityKey : @(YES),
#endif
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString *)kCVPixelBufferPixelFormatTypeKey : @(framePixelFormat),
  };

  OSStatus status = VTCompressionSessionCreate(
      nullptr,  // use default allocator
      _width,
      _height,
      kCMVideoCodecType_HEVC,
      (__bridge CFDictionaryRef)EncoderSpecification(),
      (__bridge CFDictionaryRef)sourceAttributes,
      nullptr,  // use default compressed data allocator
      compressionOutputCallback,
      nullptr,
      &_compressionSession);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create compression session: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  // Never encode H265 in software.
  if (!IsUsingHardwareEncoder(_compressionSession)) {
    RTC_LOG(LS_ERROR) << "Compression session is not hardware accelerated.";
    [self destroyCompressionSession];
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  [self configureCompressionSession];

  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)configureCompressionSession {
  RTC_DCHECK(_compressionSession);
  SetVTSessionProperty(
      _compressionSession, kVTCompressionPropertyKey_RealTime, true);
  SetVTSessionProperty(_compressionSession,
                       kVTCompressionPropertyKey_ProfileLevel,
                       kVTProfileLevel_HEVC_Main_AutoLevel);
  SetVTSessionProperty(_compressionSession,
                       kVTCompressionPropertyKey_AllowFrameReordering,
                       false);
  [self setEncoderBitrateBps:_targetBitrateBps frameRate:_encoderFrameRate];
  // Set a relatively large value for keyframe emission (7200 frames or 4
  // minutes).
  SetVTSessionProperty(
      _compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200);
  SetVTSessionProperty(_compressionSession,
                       kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                       240);
}

- (void)destroyCompressionSession {
  if (_compressionSession) {
    VTCompressionSessionInvalidate(_compressionSession);
    CFRelease(_compressionSession);
    _compressionSession = nullptr;
  }
}

- (NSString *)implementationName {
  return @"VideoToolbox";
}

- (void)setBitrateBps:(uint32_t)bitrateBps frameRate:(uint32_t)frameRate {
  if (_encoderBitrateBps != bitrateBps || _encoderFrameRate != frameRate) {
    [self setEncoderBitrateBps:bitrateBps frameRate:frameRate];
  }
}

- (void)setEncoderBitrateBps:(uint32_t)bitrateBps
                   frameRate:(uint32_t)frameRate {
  if (_compressionSession) {
    SetVTSessionProperty(_compressionSession,
                         kVTCompressionPropertyKey_AverageBitRate,
                         bitrateBps);

    SetVTSessionProperty(_compressionSession,
                         kVTCompressionPropertyKey_ExpectedFrameRate,
                         frameRate);

    // TODO(tkchin): Add a helper method to set array value.
    int64_t dataLimitBytesPerSecondValue =
        static_cast<int64_t>(bitrateBps * kLimitToAverageBitRateFactor / 8);
    CFNumberRef bytesPerSecond = CFNumberCreate(kCFAllocatorDefault,
                                                kCFNumberSInt64Type,
                                                &dataLimitBytesPerSecondValue);
    int64_t oneSecondValue = 1;
    CFNumberRef oneSecond = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberSInt64Type, &oneSecondValue);
    const void *nums[2] = {bytesPerSecond, oneSecond};
    CFArrayRef dataRateLimits =
        CFArrayCreate(nullptr, nums, 2, &kCFTypeArrayCallBacks);
    OSStatus status =
        VTSessionSetProperty(_compressionSession,
                             kVTCompressionPropertyKey_DataRateLimits,
                             dataRateLimits);
    if (bytesPerSecond) {
      CFRelease(bytesPerSecond);
    }
    if (oneSecond) {
      CFRelease(oneSecond);
    }
    if (dataRateLimits) {
      CFRelease(dataRateLimits);
    }
    if (status != noErr) {
      RTC_LOG(LS_ERROR) << "Failed to set data rate limit with code: "
                        << status;
    }

    _encoderBitrateBps = bitrateBps;
    _encoderFrameRate = frameRate;
  }
}

- (void)frameWasEncoded:(OSStatus)status
                  flags:(VTEncodeInfoFlags)infoFlags
           sampleBuffer:(CMSampleBufferRef)sampleBuffer
      codecSpecificInfo:
          (id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo
                  width:(int32_t)width
                 height:(int32_t)height
           renderTimeMs:(int64_t)renderTimeMs
              timestamp:(uint32_t)timestamp
               rotation:(RTCVideoRotation)rotation {
  RTCVideoEncoderCallback callback = _callback;
  if (!callback) {
    return;
  }
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "H265 encode failed with code: " << status;
    return;
  }
  if (infoFlags & kVTEncodeInfo_FrameDropped) {
    RTC_LOG(LS_INFO) << "H265 encode dropped frame.";
    return;
  }

  BOOL isKeyframe = NO;
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
  if (attachments != nullptr && CFArrayGetCount(attachments)) {
    CFDictionaryRef attachment =
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    isKeyframe =
        !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
  }

  if (isKeyframe) {
    RTC_LOG(LS_INFO) << "Generated keyframe";
  }

  __block std::unique_ptr<webrtc::Buffer> buffer =
      std::make_unique<webrtc::Buffer>();
  if (!webrtc::H265CMSampleBufferToAnnexBBuffer(
          sampleBuffer, isKeyframe, buffer.get())) {
    return;
  }

  RTC_OBJC_TYPE(RTCEncodedImage) *frame =
      [[RTC_OBJC_TYPE(RTCEncodedImage) alloc] init];
  // This assumes ownership of `buffer` and is responsible for freeing it when
  // done.
  frame.buffer =
      [[NSData alloc] initWithBytesNoCopy:buffer->data()
                                   length:buffer->size()
                              deallocator:^(void *bytes, NSUInteger size) {
                                buffer.reset();
                              }];
  frame.encodedWidth = width;
  frame.encodedHeight = height;
  frame.frameType =
      isKeyframe ? RTCFrameTypeVideoFrameKey : RTCFrameTypeVideoFrameDelta;
  frame.captureTimeMs = renderTimeMs;
  frame.timeStamp = timestamp;
  frame.rotation = rotation;
  frame.contentType = (_mode == RTCVideoCodecModeScreensharing) ?
      RTCVideoContentTypeScreenshare :
      RTCVideoContentTypeUnspecified;
  frame.flags = webrtc::VideoSendTiming::kInvalid;

  _h265BitstreamParser.ParseBitstream(*buffer);
  frame.qp = @(_h265BitstreamParser.GetLastSliceQp().value_or(-1));

  BOOL res = callback(frame, codecSpecificInfo);
  if (!res) {
    RTC_LOG(LS_ERROR) << "Encode callback failed";
    return;
  }
  _bitrateAdjuster->Update(frame.buffer.length);
}

- (nullable RTC_OBJC_TYPE(RTCVideoEncoderQpThresholds) *)scalingSettings {
  return [[RTC_OBJC_TYPE(RTCVideoEncoderQpThresholds) alloc]
      initWithThresholdsLow:kLowH265QpThreshold
                       high:kHighH265QpThreshold];
}

@end
