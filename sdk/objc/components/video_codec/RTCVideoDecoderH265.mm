/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCVideoDecoderH265.h"

#import "RTCH265ProfileLevelId.h"

#import <VideoToolbox/VideoToolbox.h>

#include <span>

#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"
#import "helpers.h"
#import "helpers/scoped_cftyperef.h"

#if defined(WEBRTC_IOS)
#import "helpers/UIDevice+RTCDevice.h"
#endif

#include "api/video_codecs/h265_profile_tier_level.h"
#include "media/base/media_constants.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"
#include "sdk/objc/components/video_codec/nalu_rewriter.h"

// Struct that we pass to the decoder per frame to decode. We receive it again
// in the decoder callback.
struct RTCH265FrameDecodeParams {
  RTCH265FrameDecodeParams(RTCVideoDecoderCallback cb, int64_t ts)
      : callback(cb), timestamp(ts) {}
  RTCVideoDecoderCallback callback;
  int64_t timestamp;
};

@interface RTC_OBJC_TYPE (RTCVideoDecoderH265)
() - (void)setError : (OSStatus)error;
@end

// This is the callback function that VideoToolbox calls when decode is
// complete.
void h265DecompressionOutputCallback(void *decoderRef,
                                     void *params,
                                     OSStatus status,
                                     VTDecodeInfoFlags infoFlags,
                                     CVImageBufferRef imageBuffer,
                                     CMTime timestamp,
                                     CMTime duration) {
  std::unique_ptr<RTCH265FrameDecodeParams> decodeParams(
      reinterpret_cast<RTCH265FrameDecodeParams *>(params));
  if (status != noErr) {
    RTC_OBJC_TYPE(RTCVideoDecoderH265) *decoder =
        (__bridge RTC_OBJC_TYPE(RTCVideoDecoderH265) *)decoderRef;
    [decoder setError:status];
    RTC_LOG(LS_ERROR) << "Failed to decode frame. Status: " << status;
    return;
  }
  // TODO(tkchin): Handle CVO properly.
  RTC_OBJC_TYPE(RTCCVPixelBuffer) *frameBuffer =
      [[RTC_OBJC_TYPE(RTCCVPixelBuffer) alloc] initWithPixelBuffer:imageBuffer];
  RTC_OBJC_TYPE(
      RTCVideoFrame) *decodedFrame = [[RTC_OBJC_TYPE(RTCVideoFrame) alloc]
      initWithBuffer:frameBuffer
            rotation:RTCVideoRotation_0
         timeStampNs:CMTimeGetSeconds(timestamp) * webrtc::kNumNanosecsPerSec];
  decodedFrame.timeStamp = decodeParams->timestamp;
  decodeParams->callback(decodedFrame);
}

// Decoder.
@implementation RTC_OBJC_TYPE (RTCVideoDecoderH265) {
  CMVideoFormatDescriptionRef _videoFormat;
  CMMemoryPoolRef _memoryPool;
  VTDecompressionSessionRef _decompressionSession;
  RTCVideoDecoderCallback _callback;
  OSStatus _error;
}

+ (BOOL)isSupported {
  return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
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

- (instancetype)init {
  self = [super init];
  if (self) {
    _memoryPool = CMMemoryPoolCreate(nil);
  }
  return self;
}

- (void)dealloc {
  CMMemoryPoolInvalidate(_memoryPool);
  CFRelease(_memoryPool);
  [self destroyDecompressionSession];
  [self setVideoFormat:nullptr];
}

- (NSInteger)startDecodeWithNumberOfCores:(int)numberOfCores {
  return WEBRTC_VIDEO_CODEC_OK;
}

// TODO(bugs.webrtc.org/15444): Remove obsolete missingFrames param.
- (NSInteger)decode:(RTC_OBJC_TYPE(RTCEncodedImage) *)inputImage
        missingFrames:(BOOL)missingFrames
    codecSpecificInfo:(nullable id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)info
         renderTimeMs:(int64_t)renderTimeMs {
  RTC_DCHECK(inputImage.buffer);

  if (_error != noErr) {
    RTC_LOG(LS_WARNING) << "Last frame decode failed.";
    _error = noErr;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }

  webrtc::ScopedCFTypeRef<CMVideoFormatDescriptionRef> inputFormat =
      webrtc::ScopedCF(
          webrtc::CreateH265VideoFormatDescription(std::span<const uint8_t>(
              (uint8_t *)inputImage.buffer.bytes, inputImage.buffer.length)));
  if (inputFormat) {
    // Check if the video format has changed, and reinitialize decoder if
    // needed. Also retry here if an earlier attempt to create the session
    // failed.
    if (!CMFormatDescriptionEqual(inputFormat.get(), _videoFormat) ||
        !_decompressionSession) {
      [self setVideoFormat:inputFormat.get()];
      int resetDecompressionSessionError = [self resetDecompressionSession];
      if (resetDecompressionSessionError != WEBRTC_VIDEO_CODEC_OK) {
        return resetDecompressionSessionError;
      }
    }
  }
  if (!_videoFormat || !_decompressionSession) {
    // We received a frame but we don't have format information so we can't
    // decode it.
    // This can happen after backgrounding. We need to wait for the next
    // vps/sps/pps before we can resume so we request a keyframe by returning
    // an error.
    RTC_LOG(LS_WARNING)
        << "Missing video format. Frame with vps/sps/pps required.";
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  CMSampleBufferRef sampleBuffer = nullptr;
  if (!webrtc::H265AnnexBBufferToCMSampleBuffer(
          std::span<const uint8_t>((uint8_t *)inputImage.buffer.bytes,
                                   inputImage.buffer.length),
          _videoFormat,
          &sampleBuffer,
          _memoryPool)) {
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  RTC_DCHECK(sampleBuffer);
  VTDecodeFrameFlags decodeFlags =
      kVTDecodeFrame_EnableAsynchronousDecompression;
  std::unique_ptr<RTCH265FrameDecodeParams> frameDecodeParams;
  frameDecodeParams.reset(
      new RTCH265FrameDecodeParams(_callback, inputImage.timeStamp));
  OSStatus status =
      VTDecompressionSessionDecodeFrame(_decompressionSession,
                                        sampleBuffer,
                                        decodeFlags,
                                        frameDecodeParams.release(),
                                        nullptr);
#if defined(WEBRTC_IOS)
  // Re-initialize the decoder if we have an invalid session while the app is
  // active or decoder malfunctions and retry the decode request.
  if ((status == kVTInvalidSessionErr ||
       status == kVTVideoDecoderMalfunctionErr) &&
      [self resetDecompressionSession] == WEBRTC_VIDEO_CODEC_OK) {
    RTC_LOG(LS_INFO) << "Failed to decode frame with code: " << status
                     << " retrying decode after decompression session reset";
    frameDecodeParams.reset(
        new RTCH265FrameDecodeParams(_callback, inputImage.timeStamp));
    status = VTDecompressionSessionDecodeFrame(_decompressionSession,
                                               sampleBuffer,
                                               decodeFlags,
                                               frameDecodeParams.release(),
                                               nullptr);
  }
#endif
  CFRelease(sampleBuffer);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to decode frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoDecoderCallback)callback {
  _callback = callback;
}

- (void)setError:(OSStatus)error {
  _error = error;
}

- (NSInteger)releaseDecoder {
  // Need to invalidate the session so that callbacks no longer occur and it
  // is safe to null out the callback.
  [self destroyDecompressionSession];
  [self setVideoFormat:nullptr];
  _callback = nullptr;
  return WEBRTC_VIDEO_CODEC_OK;
}

#pragma mark - Private

- (int)resetDecompressionSession {
  [self destroyDecompressionSession];

  // Need to wait for the first VPS/SPS/PPS to initialize decoder.
  if (!_videoFormat) {
    return WEBRTC_VIDEO_CODEC_OK;
  }

  // Set keys for OpenGL and IOSurface compatibilty, which makes the encoder
  // create pixel buffers with GPU backed memory. The intent here is to pass
  // the pixel buffers directly so we avoid a texture upload later during
  // rendering. This currently is moot because we are converting back to an
  // I420 frame after decode, but eventually we will be able to plumb
  // CVPixelBuffers directly to the renderer.
  // TODO(tkchin): Maybe only set OpenGL/IOSurface keys if we know that that
  // we can pass CVPixelBuffers as native handles in decoder output.
  NSDictionary *attributes = @{
#if defined(WEBRTC_IOS) && (TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR)
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @(YES),
#elif defined(WEBRTC_IOS)
    (NSString *)kCVPixelBufferOpenGLESCompatibilityKey : @(YES),
#elif defined(WEBRTC_MAC) && !defined(WEBRTC_ARCH_ARM64)
    (NSString *)kCVPixelBufferOpenGLCompatibilityKey : @(YES),
#endif
#if !(TARGET_OS_SIMULATOR)
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
#endif
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
  };

  VTDecompressionOutputCallbackRecord record = {
      h265DecompressionOutputCallback,
      (__bridge void *)self,
  };
  // H265 must only ever be decoded in hardware.
  NSDictionary *decoderSpecification = nil;
#if defined(WEBRTC_MAC) && !defined(WEBRTC_IOS)
  decoderSpecification = @{
    (NSString *)
    kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @(YES),
  };
#endif
  OSStatus status =
      VTDecompressionSessionCreate(nullptr,
                                   _videoFormat,
                                   (__bridge CFDictionaryRef)
                                       decoderSpecification,
                                   (__bridge CFDictionaryRef)attributes,
                                   &record,
                                   &_decompressionSession);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create decompression session: " << status;
    [self destroyDecompressionSession];
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  if (![self isUsingHardwareDecoder]) {
    RTC_LOG(LS_ERROR) << "Decompression session is not hardware accelerated.";
    [self destroyDecompressionSession];
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  [self configureDecompressionSession];

  return WEBRTC_VIDEO_CODEC_OK;
}

- (BOOL)isUsingHardwareDecoder {
  RTC_DCHECK(_decompressionSession);
  CFBooleanRef hwacclEnabled = nullptr;
  OSStatus status = VTSessionCopyProperty(
      _decompressionSession,
      kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
      nullptr,
      &hwacclEnabled);
  if (status != noErr || !hwacclEnabled) {
    // The session doesn't report how it decodes. Fall back to whether the
    // device can decode H265 in hardware at all.
    return [[self class] isSupported];
  }
  BOOL isHardware = CFBooleanGetValue(hwacclEnabled);
  CFRelease(hwacclEnabled);
  return isHardware;
}

- (void)configureDecompressionSession {
  RTC_DCHECK(_decompressionSession);
#if defined(WEBRTC_IOS)
  VTSessionSetProperty(_decompressionSession,
                       kVTDecompressionPropertyKey_RealTime,
                       kCFBooleanTrue);
#endif
}

- (void)destroyDecompressionSession {
  if (_decompressionSession) {
#if defined(WEBRTC_IOS)
    VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
#endif
    VTDecompressionSessionInvalidate(_decompressionSession);
    CFRelease(_decompressionSession);
    _decompressionSession = nullptr;
  }
}

- (void)setVideoFormat:(CMVideoFormatDescriptionRef)videoFormat {
  if (_videoFormat == videoFormat) {
    return;
  }
  if (_videoFormat) {
    CFRelease(_videoFormat);
  }
  _videoFormat = videoFormat;
  if (_videoFormat) {
    CFRetain(_videoFormat);
  }
}

- (NSString *)implementationName {
  return @"VideoToolbox";
}

@end
