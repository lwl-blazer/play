//
//  VideoDecoder.m
//  Player
//
//  Created by luowailin on 2021/1/6.
//

#import "VideoDecoder.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

#import <libavutil/pixdesc.h>
#import <libavutil/frame.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>

@implementation BuriedPoint

@end

@implementation Frame

@end

@implementation AudioFrame

@end

@implementation VideoFrame

@end


#pragma mark -- VideoDecoder

@interface VideoDecoder () {
    //重连的次数
   int _connectionRetry;
   //打开是否成功
   BOOL _isOpenInputSuccess;
   //每次解码最后时间
   int _readLastestFrameTime;
   //超时时间 AVFormatContext回调的超时时间设置
   int _subscribeTimeOutTimeInSecs;
   //是否执行中断
   BOOL _interrupted;
   //是否已经关闭文件
   BOOL _isSubscribe;
   //解码失败 av_read_frame()是否返回错误
   BOOL _isEOF;
   
   //文件相关
   AVFormatContext *_formatContext;
   
   //音频相关
   AVCodecContext *_audioCodecCtx;
   AVFrame *_audioFrame;
   SwrContext *_swrContext;
   void *_swrBuffer;
   NSUInteger _swrBufferSize;
   NSInteger _audioStreamIndex;
   NSArray *_audioStreams;
   CGFloat _audioTimeBase;
   
   //视频相关
   AVCodecContext *_videoCodecCtx;
   AVFrame *_videoFrame;
   struct SwsContext *_swsContext;
   NSInteger _videoStreamIndex;
   NSArray *_videoStreams;
   CGFloat _fps;
   CGFloat _videoTimeBase;
   
   //用于计算平均解码的时间
   long long decodeVideoFrameWasteTimeMills; //视频解码总时长
   int _totalVideoFrameCount; //多少帧
   

   CGFloat _decodePosition;
   
   BuriedPoint *_buriedPoint;
}
@end

@implementation VideoDecoder

static int interrupt_callback(void *ctx) {
    if (!ctx) {
        return 0;
    }
    
    __unsafe_unretained VideoDecoder *p = (__bridge VideoDecoder *)(ctx);
    const BOOL r = [p detectInterrupted];
    if (r) {
        NSLog(@"DEBUG:INTERRUPT_CALLBACK");
    }
    return r;
}

static NSArray *collectStreams(AVFormatContext *formatCtx,
                               enum AVMediaType codecType) {
    NSMutableArray *ma = [NSMutableArray array];
    for (NSInteger i = 0; i < formatCtx->nb_streams; ++i) {
        if (codecType == formatCtx->streams[i]->codecpar->codec_type) {
            [ma addObject:[NSNumber numberWithInteger:i]];
        }
    }
    return [ma copy];
}

static void avStreamFPSTimeBase(AVStream *st,
                                AVCodecContext *codecContext,
                                CGFloat defaultTimeBase,
                                CGFloat *pFPS,
                                CGFloat *pTimeBase) {
    CGFloat timebase;
    if (st->time_base.den && st->time_base.num) {
        timebase = av_q2d(st->time_base);
    } else if (codecContext->time_base.den && codecContext->time_base.num) {
        timebase = av_q2d(codecContext->time_base);
    } else {
        timebase = defaultTimeBase;
    }
    
    if (codecContext->ticks_per_frame != 1) {
        NSLog(@"WARNING: st.codec.ticks_per_frame=%d", codecContext->ticks_per_frame);
    }

    if (pFPS != NULL) {
        CGFloat fps;
        if (st->avg_frame_rate.den && st->avg_frame_rate.num) {
            fps = av_q2d(st->avg_frame_rate);
        } else if (st->r_frame_rate.den && st->r_frame_rate.num) {
            fps = av_q2d(st->r_frame_rate);
        } else {
            fps = 1.0 / timebase;
        }
        *pFPS = fps;
    }
    
    if (pTimeBase) {
        *pTimeBase = timebase;
    }
}


#pragma mark -- public method
- (BOOL)openFile:(NSString *)path
       parameter:(NSDictionary *)parameters
           error:(NSError * _Nullable __autoreleasing *)perror{
    BOOL ret = YES;
    if (path == nil) {
        return NO;
    }
    
    _connectionRetry = 0;
    _totalVideoFrameCount = 0;
    _subscribeTimeOutTimeInSecs = SUBSCRIBE_VIDEO_DATA_TIME_OUT;
    
    _interrupted = NO;
    _isOpenInputSuccess = NO;
    _isSubscribe = YES;
    
    _buriedPoint = [[BuriedPoint alloc] init];
    _buriedPoint.bufferStatusRecords = [[NSMutableArray alloc] init];
    _readLastestFrameTime = [[NSDate date] timeIntervalSince1970];
    
    avformat_network_init();
    _buriedPoint.beginOpen = [[NSDate date] timeIntervalSince1970] * 1000;
    
    int openInputErrCode = [self openInput:path parameter:parameters];
    if (openInputErrCode > 0) {
        _buriedPoint.successOpen = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen)/1000.0;
        _buriedPoint.failOpen = 0.0f;
        _buriedPoint.failOpenType = 1;
        
        if (_formatContext->duration != AV_NOPTS_VALUE) {
            int64_t duration = _formatContext->duration + 5000;
            _buriedPoint.second = (int)duration / AV_TIME_BASE;
        }
        
        BOOL openVideoStatus = [self openVideoStream];
        BOOL openAudioStatus = [self openAudioStream];
        if (!openVideoStatus || !openAudioStatus) {
            [self closeFile];
            ret = NO;
        }
    } else {
        _buriedPoint.failOpen = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0;
        _buriedPoint.successOpen = 0.0f;
        _buriedPoint.failOpenType = openInputErrCode;
        ret = NO;
    }
    
    _buriedPoint.retryTimes = _connectionRetry;
    if (ret) {
        NSInteger videoWidth = [self frameWidth];
        NSInteger videoHeight = [self frameHeight];
        int retryTimes = 5;
        while ((videoWidth <= 0 || videoHeight <= 0) && retryTimes > 0) {
            NSLog(@"because of videowidth and videoHeight is Zero we will retry...");
            usleep(500 * 1000);
            _connectionRetry = 0;
            ret = [self openFile:path
                       parameter:parameters
                           error:perror];
            if (!ret) {
                break;
            }
            retryTimes --;
            videoWidth = [self frameWidth];
            videoHeight = [self frameHeight];
        }
    }
    _isOpenInputSuccess = ret;
    return YES;
}

- (void)closeFile{
    NSLog(@"Enter close file...");
    if (_buriedPoint.failOpenType == 1) {
        _buriedPoint.duration = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
    }
    [self interrupt];
    [self closeAudioStream];
    [self closeVideoStream];
    
    _videoStreams = nil;
    _audioStreams = nil;
    
    if (_formatContext) {
        _formatContext->interrupt_callback.opaque = NULL;
        _formatContext->interrupt_callback.callback = NULL;
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    
    float decodeFrameAVGTimeMills = (double)decodeVideoFrameWasteTimeMills / (float)_totalVideoFrameCount;
    NSLog(@"Decoder decoder totalVideoFramecount is %d decodeFrameAVGTimeMills is %.3f", _totalVideoFrameCount, decodeFrameAVGTimeMills);
}

- (NSUInteger)frameWidth{
    return _videoCodecCtx ? _videoCodecCtx->width : 0;
}

- (NSUInteger)frameHeight{
    return _videoCodecCtx ? _videoCodecCtx->height : 0;
}

#pragma mark -- private method
- (int)openInput:(NSString *)path
       parameter:(NSDictionary *)parameters{
    
    AVFormatContext *formatContext = avformat_alloc_context();
    
    AVIOInterruptCB int_cb = {interrupt_callback, (__bridge void *)(self)};
    formatContext->interrupt_callback = int_cb;
    
    int openInputErrCode = 0;
    openInputErrCode = [self openFormatInput:&formatContext
                                        path:path
                                   parameter:parameters];
    if (openInputErrCode != 0) {
        NSLog(@"Video decoder open input file failed... videoSourceURI is %@ openInputErr is %s", path, av_err2str(openInputErrCode));
        if (formatContext) {
            avformat_free_context(formatContext);
        }
        return openInputErrCode;
    }
    
    [self initAnalyzeDurationAndProbesize:formatContext
                                parameter:parameters];
    int findStreamErrCode = 0;
    double startFindStreamTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
    findStreamErrCode = avformat_find_stream_info(formatContext, NULL);
    if (findStreamErrCode < 0) {
        avformat_close_input(&formatContext);
        avformat_free_context(formatContext);
        NSLog(@"Video decoder find stream info failed... find stream ErrCode is %s", av_err2str(findStreamErrCode));
        return findStreamErrCode;
    }
    int wasteTimeWills = CFAbsoluteTimeGetCurrent() * 1000 - startFindStreamTimeMills;
    NSLog(@"Find stream info waste TimeMills is %d", wasteTimeWills);
    
    if (formatContext->streams[0]->codecpar->codec_id == AV_CODEC_ID_NONE) {
        avformat_close_input(&formatContext);
        avformat_free_context(formatContext);
        NSLog(@"Video decoder First Stream Codec ID is UnKnown...");
        if ([self isNeedRetry]) {
            return [self openInput:path parameter:parameters];
        } else {
            return -1;
        }
    }
    
    _formatContext = formatContext;
    return 1;
}

- (BOOL)detectInterrupted {
    if ([[NSDate date] timeIntervalSince1970] - _readLastestFrameTime > _subscribeTimeOutTimeInSecs) {
        return YES;
    }
    return _interrupted;
}

- (int)openFormatInput:(AVFormatContext **)formatContext
                  path:(NSString *)path
             parameter:(NSDictionary *)parameter{
    const char *videoSourceURL = [path cStringUsingEncoding:NSUTF8StringEncoding];
    AVDictionary *options = NULL;
    NSString *rtmpTcurl = parameter[RTM_TCURL_KEY];
    if ([rtmpTcurl length] > 0) {
        const char *rtmp_tcurl = [rtmpTcurl cStringUsingEncoding:NSUTF8StringEncoding];
        av_dict_set(&options,
                    "rtm_tcurl",
                    rtmp_tcurl,
                    0);
    }
    return avformat_open_input(formatContext,
                               videoSourceURL,
                               NULL,
                               &options);
}

- (void)initAnalyzeDurationAndProbesize:(AVFormatContext *)formatCtx
                              parameter:(NSDictionary *)parameter {
    float probeSize = [parameter[PROBE_SIZE] floatValue];
    
    formatCtx->probesize = probeSize ? probeSize : 50 * 1024;
    NSArray *durations = parameter[MAX_ANALYZE_DURATION_ARRAY];
    if (durations && durations.count > _connectionRetry)  {
        formatCtx->max_analyze_duration = [durations[_connectionRetry] floatValue];
    } else {
        float multiplier = 0.5 + (double)pow(2.0, (double)_connectionRetry) * 0.25;
        formatCtx->max_analyze_duration = multiplier * AV_TIME_BASE;
    }
    
    BOOL fpsProbeSizeConfiged = [parameter[FPS_PROBE_SIZE_CONFIGURED] boolValue];
    if (fpsProbeSizeConfiged) {
        formatCtx->fps_probe_size = 3;
    }
}

- (BOOL)isNeedRetry {
    _connectionRetry ++;
    return _connectionRetry <= NET_WORK_STREAM_RETRY_TIME;
}

- (BOOL)openVideoStream{
    _videoStreamIndex = -1;
    _videoStreams = collectStreams(_formatContext, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        const NSUInteger iStream = n.integerValue;
        AVCodecContext *codecCtx = avcodec_alloc_context3(NULL);
        avcodec_parameters_to_context(codecCtx, _formatContext->streams[iStream]->codecpar);
        AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
        if (!codec) {
            NSLog(@"Find Video Decoder Failed codec_id %d CODEC_ID_H264 is %d", codecCtx->codec_id, AV_CODEC_ID_H264);
            return NO;
        }
        
        int openCodecErrCode = 0;
        openCodecErrCode = avcodec_open2(codecCtx, codec, NULL);
        if (openCodecErrCode < 0) {
            NSLog(@"open video codec failed openCodecErr is %s", av_err2str(openCodecErrCode));
            avcodec_free_context(&codecCtx);
            return NO;
        }
        
        _videoFrame = av_frame_alloc();
        if (!_videoFrame) {
            NSLog(@"Alloc video frame failed...");
            avcodec_free_context(&codecCtx);
            return NO;
        }
        
        _videoStreamIndex = iStream;
        _videoCodecCtx = codecCtx;
        
        AVStream *st = _formatContext->streams[_videoStreamIndex];
        avStreamFPSTimeBase(st,
                            codecCtx,
                            0.04,
                            &_fps,
                            &_videoTimeBase);
        break;
    }
    return YES;
}

- (BOOL)openAudioStream{
    _audioStreamIndex = -1;
    _audioStreams = collectStreams(_formatContext, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        const NSUInteger iStream = [n integerValue];
        AVCodecContext *codecCtx = avcodec_alloc_context3(NULL);
        avcodec_parameters_to_context(codecCtx, _formatContext->streams[iStream]->codecpar);
        AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
        if (!codec) {
            NSLog(@"Find Audio Decoder Failed codec_id %d CODEC_ID_AAC is %d", codecCtx->codec_id, AV_CODEC_ID_AAC);
            return NO;
        }
        
        int openCodecErrCode = 0;
        openCodecErrCode = avcodec_open2(codecCtx, codec, NULL);
        if (openCodecErrCode < 0) {
            NSLog(@"Open Audio Codec Failed openCodecErr is %s", av_err2str(openCodecErrCode));
            avcodec_free_context(&codecCtx);
            return NO;
        }
        
        SwrContext *swrContext = NULL;
        if (![self audioCodecIsSupported:codecCtx]) {
            NSLog(@"because of audio Codec is Not Supported so we will init swresampler...");
            swrContext = swr_alloc_set_opts(NULL,
                                            av_get_default_channel_layout(codecCtx->channels),
                                            AV_SAMPLE_FMT_S16,
                                            codecCtx->sample_rate,
                                            av_get_default_channel_layout(codecCtx->channels),
                                            codecCtx->sample_fmt,
                                            codecCtx->sample_rate,
                                            0,
                                            NULL);
            
            if (!swrContext || swr_init(swrContext)) {
                if (swrContext) {
                    swr_free(&swrContext);
                }
                NSLog(@"init resampler failed...");
                avcodec_free_context(&codecCtx);
                return NO;
            }
            
            _audioFrame = av_frame_alloc();
            if (!_audioFrame) {
                NSLog(@"Alloc Audio Frame Failed...");
                if (swrContext) {
                    swr_free(&swrContext);
                }
                avcodec_free_context(&codecCtx);
                return NO;
            }
            
            _audioStreamIndex = iStream;
            _audioCodecCtx = codecCtx;
            _swrContext = swrContext;
            
            AVStream *st = _formatContext->streams[_audioStreamIndex];
            avStreamFPSTimeBase(st,
                                codecCtx,
                                0.25,
                                NULL,
                                &_audioTimeBase);
        }
    }
    return YES;
}

- (BOOL)audioCodecIsSupported:(AVCodecContext *)codecCtx {
    if (codecCtx->sample_fmt == AV_SAMPLE_FMT_S16) {
        return YES;
    }
    return NO;
}

- (void)closeAudioStream{
    _audioStreamIndex = -1;
    if (_swrBuffer) {
        free(_swrBuffer);
        _swrBuffer = NULL;
        _swrBufferSize = 0;
    }
    
    if (_swrContext) {
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    
    if (_audioFrame) {
        av_free(_audioFrame);
        _audioFrame = NULL;
    }
    
    if (_audioCodecCtx) {
        avcodec_free_context(&_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
}

- (void)closeVideoStream{
    _videoStreamIndex = -1;
    [self closeScaler];
    if (_videoFrame) {
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
    
    if (_videoCodecCtx) {
        avcodec_free_context(&_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
}

- (void)closeScaler{
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
}

@end
