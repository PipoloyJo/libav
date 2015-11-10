/*
 * AVFoundation input device
 * Copyright (c) 2015 Luca Barbato
 *                    Alexandre Lision
 *
 * This file is part of Libav.
 *
 * Libav is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * Libav is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with Libav; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import <AVFoundation/AVFoundation.h>
#include <pthread.h>

#include "libavformat/avformat.h"
#include "libavutil/log.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libavformat/internal.h"
#include "libavutil/time.h"
#include "libavutil/mathematics.h"

#include "avdevice.h"

struct AVPixelFormatMap {
    enum AVPixelFormat pix_fmt;
    OSType core_video_fmt;
};

static const struct AVPixelFormatMap pixel_format_map[] = {
    { AV_PIX_FMT_MONOBLACK,    kCVPixelFormatType_1Monochrome },
    { AV_PIX_FMT_RGB555BE,     kCVPixelFormatType_16BE555 },
    { AV_PIX_FMT_RGB555LE,     kCVPixelFormatType_16LE555 },
    { AV_PIX_FMT_RGB565BE,     kCVPixelFormatType_16BE565 },
    { AV_PIX_FMT_RGB565LE,     kCVPixelFormatType_16LE565 },
    { AV_PIX_FMT_RGB24,        kCVPixelFormatType_24RGB },
    { AV_PIX_FMT_BGR24,        kCVPixelFormatType_24BGR },
    { AV_PIX_FMT_ARGB,         kCVPixelFormatType_32ARGB },
    { AV_PIX_FMT_BGRA,         kCVPixelFormatType_32BGRA },
    { AV_PIX_FMT_ABGR,         kCVPixelFormatType_32ABGR },
    { AV_PIX_FMT_RGBA,         kCVPixelFormatType_32RGBA },
    { AV_PIX_FMT_BGR48BE,      kCVPixelFormatType_48RGB },
    { AV_PIX_FMT_UYVY422,      kCVPixelFormatType_422YpCbCr8 },
    { AV_PIX_FMT_YUVA444P,     kCVPixelFormatType_4444YpCbCrA8R },
    { AV_PIX_FMT_YUVA444P16LE, kCVPixelFormatType_4444AYpCbCr16 },
    { AV_PIX_FMT_YUV444P,      kCVPixelFormatType_444YpCbCr8 },
    { AV_PIX_FMT_YUV422P16,    kCVPixelFormatType_422YpCbCr16 },
    { AV_PIX_FMT_YUV422P10,    kCVPixelFormatType_422YpCbCr10 },
    { AV_PIX_FMT_YUV444P10,    kCVPixelFormatType_444YpCbCr10 },
    { AV_PIX_FMT_YUV420P,      kCVPixelFormatType_420YpCbCr8Planar },
    { AV_PIX_FMT_NV12,         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange },
    { AV_PIX_FMT_YUYV422,      kCVPixelFormatType_422YpCbCr8_yuvs },
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 1080
    { AV_PIX_FMT_GRAY8,        kCVPixelFormatType_OneComponent8 },
#endif
    { AV_PIX_FMT_NONE, 0 }
};

static enum AVPixelFormat core_video_to_pix_fmt(OSType core_video_fmt)
{
    int i;
    for (i = 0; pixel_format_map[i].pix_fmt != AV_PIX_FMT_NONE; i++) {
         if (core_video_fmt == pixel_format_map[i].core_video_fmt)
             return pixel_format_map[i].pix_fmt;
    }
    return AV_PIX_FMT_NONE;
}

static OSType pix_fmt_to_core_video(enum AVPixelFormat pix_fmt)
{
    int i;
    for (i = 0; pixel_format_map[i].pix_fmt != AV_PIX_FMT_NONE; i++) {
         if (pix_fmt == pixel_format_map[i].pix_fmt)
             return pixel_format_map[i].core_video_fmt;
    }
    return 0;
}

typedef struct AVFoundationCaptureContext {
    AVClass *class;
    /* AVOptions */
    int list_devices;
    enum AVPixelFormat pixel_format;

    int video_stream_index;

    int64_t first_pts;
    int frames_captured;
    pthread_mutex_t frame_lock;
    pthread_cond_t frame_wait_cond;

    /* ARC-compatible pointers to ObjC objects */
    CFTypeRef session;                  /* AVCaptureSession */
    CFTypeRef video_output;
    CFTypeRef video_delegate;
    CVImageBufferRef current_frame;
} AVFoundationCaptureContext;

#define AUDIO_DEVICES 1
#define VIDEO_DEVICES 2
#define ALL_DEVICES   AUDIO_DEVICES|VIDEO_DEVICES

#define OFFSET(x) offsetof(AVFoundationCaptureContext, x)
#define DEC AV_OPT_FLAG_DECODING_PARAM
static const AVOption options[] = {
    { "list_devices", "List available devices and exit", OFFSET(list_devices),  AV_OPT_TYPE_INT,    {.i64 = 0 },             0, INT_MAX, DEC, "list_devices" },
    { "all",          "Show all the supported devices",  OFFSET(list_devices),  AV_OPT_TYPE_CONST,  {.i64 = ALL_DEVICES },   0, INT_MAX, DEC, "list_devices" },
    { "audio",        "Show only the audio devices",     OFFSET(list_devices),  AV_OPT_TYPE_CONST,  {.i64 = AUDIO_DEVICES }, 0, INT_MAX, DEC, "list_devices" },
    { "video",        "Show only the video devices",     OFFSET(list_devices),  AV_OPT_TYPE_CONST,  {.i64 = VIDEO_DEVICES }, 0, INT_MAX, DEC, "list_devices" },
    { NULL },
};


static void list_capture_devices_by_type(AVFormatContext *s, NSString *type)
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:type];

    av_log(s, AV_LOG_INFO, "Type: %s\n", [type UTF8String]);
    for (AVCaptureDevice *device in devices) {

        av_log(s, AV_LOG_INFO, "uniqueID: %s\nname: %s\nformat:\n",
               [[device uniqueID] UTF8String],
               [[device localizedName] UTF8String]);

        for (AVCaptureDeviceFormat *format in device.formats)
            av_log(s, AV_LOG_INFO, "\t%s\n",
                   [[NSString stringWithFormat:@"%@", format] UTF8String]);
    }
}

static int avfoundation_list_capture_devices(AVFormatContext *s)
{
    AVFoundationCaptureContext *ctx = s->priv_data;

    if (ctx->list_devices & AUDIO_DEVICES)
        list_capture_devices_by_type(s, AVMediaTypeAudio);

    if (ctx->list_devices & VIDEO_DEVICES)
        list_capture_devices_by_type(s, AVMediaTypeVideo);

    return AVERROR_EXIT;
}

static void lock_frames(AVFoundationCaptureContext* ctx)
{
    pthread_mutex_lock(&ctx->frame_lock);
}

static void unlock_frames(AVFoundationCaptureContext* ctx)
{
    pthread_mutex_unlock(&ctx->frame_lock);
}

@interface VideoCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    AVFoundationCaptureContext* _context;
}

- (id)initWithContext:(AVFoundationCaptureContext*)context;

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)videoFrame
         fromConnection:(AVCaptureConnection *)connection;

@end

@implementation VideoCapture

- (id)initWithContext:(AVFoundationCaptureContext*)context
{
    if (self = [super init]) {
        _context = context;
    }
    return self;
}

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)videoFrame
         fromConnection:(AVCaptureConnection *)connection
{
    lock_frames(_context);

    if (_context->current_frame != nil) {
        CFRelease(_context->current_frame);
    }

    _context->current_frame = CFRetain(CMSampleBufferGetImageBuffer(videoFrame));

    pthread_cond_signal(&_context->frame_wait_cond);

    unlock_frames(_context);

    ++_context->frames_captured;
}

@end


static int setup_stream(AVFormatContext *s, AVCaptureDevice *device)
{
    av_log(s, AV_LOG_INFO, "Setting up stream for device %s\n", [[device uniqueID] UTF8String]);

    AVFoundationCaptureContext *ctx = s->priv_data;
    NSError *__autoreleasing error = nil;
    AVCaptureDeviceInput *input;
    AVCaptureSession *session = (__bridge AVCaptureSession*)ctx->session;
    input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                  error:&error];
    // add the input devices
    if (!input) {
        av_log(s, AV_LOG_ERROR, "%s\n",
               [[error localizedDescription] UTF8String]);
        return AVERROR_UNKNOWN;
    }

    if ([session canAddInput:input]) {
        [session addInput:input];
    } else {
        av_log(s, AV_LOG_ERROR, "can't add video input to capture session\n");
        return AVERROR(EINVAL);
    }

    // add the output devices
    if ([device hasMediaType:AVMediaTypeVideo]) {
        AVCaptureVideoDataOutput* out = [[AVCaptureVideoDataOutput alloc] init];
        NSNumber *core_video_fmt = nil;
        enum AVPixelFormat pixel_format;
        if (!out) {
            av_log(s, AV_LOG_ERROR, "Failed to init AV video output\n");
            return AVERROR(EINVAL);
        }

        [out setAlwaysDiscardsLateVideoFrames:YES];

        // Map the first supported pixel format
        av_log(s, AV_LOG_VERBOSE, "Supported pixel formats:\n");
        for (NSNumber *cv_pixel_format in [out availableVideoCVPixelFormatTypes]) {
            OSType cv_fmt = [cv_pixel_format intValue];
            enum AVPixelFormat pix_fmt = core_video_to_pix_fmt(cv_fmt);
            if (pix_fmt != AV_PIX_FMT_NONE) {
                av_log(s, AV_LOG_VERBOSE, "  %s: %d\n",
                       av_get_pix_fmt_name(pix_fmt),
                       cv_fmt);
                core_video_fmt = cv_pixel_format;
                pixel_format   = pix_fmt;
            }
        }

        // fail if there is no appropriate pixel format
        if (!core_video_fmt) {
            return AVERROR(EINVAL);
        } else {
            av_log(s, AV_LOG_INFO, "Using %s.\n",
                   av_get_pix_fmt_name(pixel_format));
        }
        ctx->pixel_format          = pixel_format;
        NSDictionary *capture_dict = [NSDictionary dictionaryWithObject:core_video_fmt
                                                                 forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        [out setVideoSettings:capture_dict];

        VideoCapture *delegate = [[VideoCapture alloc] initWithContext:ctx];

        dispatch_queue_t queue = dispatch_queue_create("avf_queue", NULL);
        [out setSampleBufferDelegate:delegate queue:queue];

        if ([session canAddOutput:out]) {
            [session addOutput:out];
            ctx->video_output   = (__bridge_retained CFTypeRef) out;
            ctx->video_delegate = (__bridge_retained CFTypeRef) delegate;
        } else {
            av_log(s, AV_LOG_ERROR, "can't add video output to capture session\n");
            return AVERROR(EINVAL);
        }
    }

    return 0;
}

static int get_video_config(AVFormatContext *s)
{
    AVFoundationCaptureContext *ctx = (AVFoundationCaptureContext*)s->priv_data;
    CVImageBufferRef image_buffer;
    CGSize image_buffer_size;
    AVStream* stream = avformat_new_stream(s, NULL);

    if (!stream) {
        av_log(s, AV_LOG_ERROR, "Failed to create AVStream\n");
        return AVERROR(EINVAL);
    }

    // Take stream info from the first frame.
    while (ctx->frames_captured < 1) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
    }

    lock_frames(ctx);

    ctx->video_stream_index = stream->index;

    avpriv_set_pts_info(stream, 64, 1, 1000000);

    image_buffer = ctx->current_frame;
    image_buffer_size = CVImageBufferGetEncodedSize(image_buffer);

    av_log(s, AV_LOG_ERROR, "Update stream info...\n");
    stream->codec->codec_id   = AV_CODEC_ID_RAWVIDEO;
    stream->codec->codec_type = AVMEDIA_TYPE_VIDEO;
    stream->codec->width      = (int)image_buffer_size.width;
    stream->codec->height     = (int)image_buffer_size.height;
    stream->codec->pix_fmt    = ctx->pixel_format;

    CFRelease(ctx->current_frame);
    ctx->current_frame = nil;

    unlock_frames(ctx);

    return 0;
}

static void destroy_context(AVFoundationCaptureContext* ctx)
{
    AVCaptureSession *session = (__bridge AVCaptureSession*)ctx->session;
    [session stopRunning];

    ctx->session = NULL;

    pthread_mutex_destroy(&ctx->frame_lock);
    pthread_cond_destroy(&ctx->frame_wait_cond);

    if (ctx->current_frame) {
        CFRelease(ctx->current_frame);
    }
}

static int setup_default_stream(AVFormatContext *s)
{
    AVCaptureDevice *device;
    for (NSString *type in @[AVMediaTypeVideo]) {
        device = [AVCaptureDevice defaultDeviceWithMediaType:type];
        if (device) {
            av_log(s, AV_LOG_INFO, "Using default device %s\n",
                 [[device uniqueID] UTF8String]);
            return setup_stream(s, device);
        }
    }
    return AVERROR(EINVAL);
}

/**
 * Try to open device given in filename
 * Two supported formats: "device_unique_id" or "[device_unique_id]"
 */
static AVCaptureDevice* create_device(AVFormatContext *s)
{
    NSString* filename;
    NSError* __autoreleasing error = nil;
    NSRegularExpression *exp;
    NSArray* matches;
    AVCaptureDevice* device;

    filename = [NSString stringWithFormat:@"%s", s->filename];

    if ((device = [AVCaptureDevice deviceWithUniqueID:filename])) {
        av_log(s, AV_LOG_INFO, "Device with name %s found\n",[filename UTF8String]);
        return device;
    }

    // Remove '[]' from the device name
    NSString *pat = @"(?<=\\[).*?(?=\\])";
    exp = [NSRegularExpression regularExpressionWithPattern:pat
                                                    options:0
                                                      error:&error];
    if (!exp) {
        av_log(s, AV_LOG_ERROR, "%s\n",
               [[error localizedDescription] UTF8String]);
        return NULL;
    }

    av_log(s, AV_LOG_INFO, "device name: %s\n",[filename UTF8String]);

    matches = [exp matchesInString:filename options:0
                             range:NSMakeRange(0, [filename length])];

    if (matches.count > 0) {
        for (NSTextCheckingResult *match in matches) {
            NSRange range = [match rangeAtIndex:0];
            NSString *uniqueID = [filename substringWithRange:NSMakeRange(range.location, range.length)];
            av_log(s, AV_LOG_INFO, "opening device with ID: %s\n", [uniqueID UTF8String]);
            if (!(device = [AVCaptureDevice deviceWithUniqueID:uniqueID])) {
                av_log(s, AV_LOG_ERROR, "Device with name %s not found",[filename UTF8String]);
                return NULL;
            }
            return device;
        }
    }
    return NULL;
}

static int setup_streams(AVFormatContext *s)
{
    AVFoundationCaptureContext *ctx = s->priv_data;
    int ret;
    AVCaptureDevice *device;

    pthread_mutex_init(&ctx->frame_lock, NULL);
    pthread_cond_init(&ctx->frame_wait_cond, NULL);

    ctx->session = (__bridge_retained CFTypeRef)[[AVCaptureSession alloc] init];

    if (!strncmp(s->filename, "default", 7)) {
        ret = setup_default_stream(s);
    } else {
        device = create_device(s);
        if (device) {
            ret = setup_stream(s, device);
        } else {
            av_log(s, AV_LOG_ERROR, "No matches for %s\n", s->filename);
            ret = setup_default_stream(s);
        }
    }

    if (ret < 0) {
        av_log(s, AV_LOG_ERROR, "No device could be added");
        return ret;
    }

    av_log(s, AV_LOG_INFO, "Starting session!\n");
    [(__bridge AVCaptureSession*)ctx->session startRunning];

    av_log(s, AV_LOG_INFO, "Checking video config\n");
    if (get_video_config(s)) {
        destroy_context(ctx);
        return AVERROR(EIO);
    }

    return 0;
}

static int avfoundation_read_header(AVFormatContext *s)
{
    AVFoundationCaptureContext *ctx = s->priv_data;
    ctx->first_pts = av_gettime();
    if (ctx->list_devices)
        return avfoundation_list_capture_devices(s);

    return setup_streams(s);
}

static int avfoundation_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    AVFoundationCaptureContext* ctx = (AVFoundationCaptureContext*)s->priv_data;

    do {
        lock_frames(ctx);

        if (ctx->current_frame != nil) {
            if (av_new_packet(pkt, (int)CVPixelBufferGetDataSize(ctx->current_frame)) < 0) {
                return AVERROR(EIO);
            }

            pkt->pts = pkt->dts = av_rescale_q(av_gettime() - ctx->first_pts,
                                               AV_TIME_BASE_Q,
                                               (AVRational){1, 1000000});
            pkt->stream_index  = ctx->video_stream_index;
            pkt->flags        |= AV_PKT_FLAG_KEY;

            CVPixelBufferLockBaseAddress(ctx->current_frame, 0);

            void* data = CVPixelBufferGetBaseAddress(ctx->current_frame);
            memcpy(pkt->data, data, pkt->size);

            CVPixelBufferUnlockBaseAddress(ctx->current_frame, 0);
            CFRelease(ctx->current_frame);
            ctx->current_frame = nil;
        } else {
            pkt->data = NULL;
            pthread_cond_wait(&ctx->frame_wait_cond, &ctx->frame_lock);
        }

        unlock_frames(ctx);
    } while (!pkt->data);

    return 0;
}

static int avfoundation_read_close(AVFormatContext *s)
{
    av_log(s, AV_LOG_INFO, "Closing session...\n");
    AVFoundationCaptureContext *ctx = s->priv_data;
    destroy_context(ctx);
    return 0;
}

static const AVClass avfoundation_class = {
    .class_name = "AVFoundation AVCaptureDevice indev",
    .item_name  = av_default_item_name,
    .option     = options,
    .version    = LIBAVUTIL_VERSION_INT,
};

AVInputFormat ff_avfoundation_demuxer = {
    .name           = "avfoundation",
    .long_name      = NULL_IF_CONFIG_SMALL("AVFoundation AVCaptureDevice grab"),
    .priv_data_size = sizeof(AVFoundationCaptureContext),
    .read_header    = avfoundation_read_header,
    .read_packet    = avfoundation_read_packet,
    .read_close     = avfoundation_read_close,
    .flags          = AVFMT_NOFILE,
    .priv_class     = &avfoundation_class,
};
