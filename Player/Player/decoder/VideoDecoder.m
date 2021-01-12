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
        timebase = av_q2d(st->time_base); // 根据AVStream中的time_base 计算出秒
    } else if (codecContext->time_base.den && codecContext->time_base.num) {
        timebase = av_q2d(codecContext->time_base);  // 根据AVCodecContext中的time_base 计算出秒
    } else {
        timebase = defaultTimeBase;   //默认
    }
    
    //
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

static NSData *copyFrameData(UInt8 *src,
                             int linesize,
                             int width,
                             int height) {
    width = MIN(linesize, width);
    NSMutableData *md = [NSMutableData dataWithLength:width * height];
    Byte *dst = md.mutableBytes;
    for (NSUInteger i = 0; i < height; ++i) {
        memcpy(dst, src, width);
        dst += width;
        src += linesize;
    }
    return md.copy;
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
        //打开每个流的解码器
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

- (NSArray *)decodeFrames:(CGFloat)minDuration
    decodeVideoErrorState:(int *)decodeVideoErrorState{
    if (_videoStreamIndex == -1 && _audioStreamIndex == -1) {
        return NULL;
    }
    
    NSMutableArray *result = [NSMutableArray array];
    AVPacket packet;
    CGFloat decodeDuration = 0;
    BOOL finished = NO;
    while (!finished) {
        if (av_read_frame(_formatContext, &packet) < 0) {
            _isEOF = YES;
            break;
        }
        
        int pktSize = packet.size;
        int pktStreamIndex = packet.stream_index;
        if (pktStreamIndex == _videoStreamIndex) { //视频帧
            double startDecodeTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
            VideoFrame *frame = [self decodeVideo:packet
                                       packetSize:pktSize
                            decodeVideoErrorState:decodeVideoErrorState];
            int wasteTimeMills = CFAbsoluteTimeGetCurrent() * 1000 - startDecodeTimeMills;
            decodeVideoFrameWasteTimeMills += wasteTimeMills;
            if (frame) {
                _totalVideoFrameCount ++;
                [result addObject:frame];
                
                decodeDuration += frame.duration;
                if (decodeDuration > minDuration) {
                    finished = YES;
                }
            }
        } else if (pktStreamIndex == _audioStreamIndex) { // 音频帧
            int len = avcodec_send_packet(_audioCodecCtx, &packet);
            if (len < 0) {
                NSLog(@"decode audio error, skip packet");
            } else {
                // 对于音频帧,一个AVPacket有可能包含多个音频帧
                while (avcodec_receive_frame(_audioCodecCtx,
                                             _audioFrame) == 0) {
                    AudioFrame *frame = [self handleAudioFrame];
                    if (frame) {
                        [result addObject:frame];
                        if (_videoStreamIndex == -1) {
                            _decodePosition = frame.position;
                            decodeDuration += frame.duration;
                            if (decodeDuration > minDuration) {
                                finished = YES;
                            }
                        }
                    }
                }
            }
        } else {
            NSLog(@"We Can Not Process Stream Except Audio And Video Stream...");
        }
        av_packet_unref(&packet);
    }
    
    _readLastestFrameTime = [[NSDate date] timeIntervalSince1970];
    return result.copy;
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

- (NSUInteger)channels{
    return _audioCodecCtx ? _audioCodecCtx->channels : 0;
}

- (CGFloat)sampleRate{
    return _audioCodecCtx ? _audioCodecCtx->sample_rate : 0.0f;
}

- (BuriedPoint *)getBuriedPoint{
    return _buriedPoint;
}

- (void)addBufferStatusRecord:(NSString *)statusFlag{
    if ([@"F" isEqualToString:statusFlag] && [[_buriedPoint.bufferStatusRecords lastObject] hasPrefix:@"F_"]) {
        return;
    }
    
    float timeInterval = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
    [_buriedPoint.bufferStatusRecords addObject:[NSString stringWithFormat:@"%@_%.3f", statusFlag, timeInterval]];
}

- (void)triggerFirstScreen{
    if (_buriedPoint.failOpenType == 1) {
        _buriedPoint.firstScreenTimeMills = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
    }
}

- (void)interrupt{
    _subscribeTimeOutTimeInSecs = -1;
    _interrupted = YES;
    _isSubscribe = NO;
}

- (BOOL)isSubscribed{
    return _isSubscribe;
}

- (BOOL)validAudio{
    return _audioStreamIndex != -1;
}

- (BOOL)validVideo{
    return _videoStreamIndex != -1;
}

- (BOOL)isOpenInputSuccess{
    return _isOpenInputSuccess;
}

- (BOOL)isEOF{
    return _isEOF;
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

// 设置avformat_find_stream_info的参数
- (void)initAnalyzeDurationAndProbesize:(AVFormatContext *)formatCtx
                              parameter:(NSDictionary *)parameter {
    /**
     * avformat_find_stream_info 该方法的作用：就是把所有的stream的MetaData信息填充好。
     * avformat_find_stream_info函数是可以设置参数,有几个参数可以控制读取数据的长度，一个是probe size 一个是max_analyze_duration 还有fps_probe_size 这三个参数共同控制解码数据的长度
     * probesize 和 max_analyze_duration 常设置成 50 * 1024 和 75000
     */
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
    // 找到1个AVStream就退出循环
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
        //计算 AVStream的timeBase(秒)和fps
        avStreamFPSTimeBase(st,
                            codecCtx,
                            0.04,
                            &_fps,
                            &_videoTimeBase);
        break;
    }
    return YES;
}

//对于音频格式的转换 FFmpeg提供了一个libswresample库
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
        if (![self audioCodecIsSupported:codecCtx]) {  // 是否重采样
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

- (VideoFrame *)decodeVideo:(AVPacket)packet
                 packetSize:(int)pktSize
      decodeVideoErrorState:(int *)decodeVideoErrorState {
    VideoFrame *frame = nil;
    int len = avcodec_send_packet(_videoCodecCtx,
                                  &packet);
    if (len < 0) {
        NSLog(@"decode video error, skip packet %s", av_err2str(len));
        *decodeVideoErrorState = 1;
        return frame;
    }
    
    while (avcodec_receive_frame(_videoCodecCtx, _videoFrame) >= 0) {
        frame = [self handleVideoFrame];
    }
    return frame;
}

- (AudioFrame *)handleAudioFrame{
    if (!_audioFrame->data[0]) {
        return nil;
    }
    
    const NSUInteger numChannels = _audioCodecCtx->channels;
    NSInteger numFrames;
    void *audioData;
    if (_swrContext) {
        const NSUInteger ratio = 2;
        //av_samples_get_buffer_size() 计算编解码每一帧输入给编解码器需要多少个字节
        const int bufSize = av_samples_get_buffer_size(NULL,
                                                       (int)numChannels,
                                                       (int)_audioFrame->nb_samples * ratio,
                                                       AV_SAMPLE_FMT_S16,
                                                       1);
        if (!_swrBuffer || _swrBufferSize < bufSize) {
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        
        Byte *outbuf[2] = {_swrBuffer, 0};
        // 重采样用swr_convert进行格式转换
        numFrames = swr_convert(_swrContext,
                                outbuf,
                                (int)(_audioFrame->nb_samples * ratio),
                                (const uint8_t **)_audioFrame->data,
                                _audioFrame->nb_samples);
        if (numFrames < 0) {
            NSLog(@"Faile resample audio");
            return nil;
        }
        audioData = _swrBuffer;
    } else {
        if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_S16) {
            NSLog(@"Audio format is invalid");
            return nil;
        }
        audioData = _audioFrame->data[0];
        numFrames = _audioFrame->nb_samples;
    }
    
    const NSUInteger numElements = numFrames * numChannels;
    NSMutableData *pcmData = [NSMutableData dataWithLength:numElements * sizeof(SInt16)];
    memcpy(pcmData.mutableBytes,
           audioData,
           numElements * sizeof(SInt16));
    
    
    AudioFrame *frame = [[AudioFrame alloc] init];
    frame.position = _audioFrame->best_effort_timestamp * _audioTimeBase;
    frame.duration = _audioFrame->pkt_duration * _audioTimeBase;
    frame.samples = pcmData;
    frame.type = AudioFrameType;
    return frame;
}

//对于视频帧的格式转换，FFmpeg提供了一个libswscale的库 
- (VideoFrame *)handleVideoFrame{
    if (!_videoFrame->data[0]) {
        return nil;
    }
    
    VideoFrame *frame = [[VideoFrame alloc] init];
    if (_videoCodecCtx->pix_fmt == AV_PIX_FMT_YUV420P || _videoCodecCtx->pix_fmt == AV_PIX_FMT_YUVJ420P) { //YUV420P
        frame.luma = copyFrameData(_videoFrame->data[0],
                                   _videoFrame->linesize[0],
                                   _videoCodecCtx->width,
                                   _videoCodecCtx->height);
        
        frame.chromaB = copyFrameData(_videoFrame->data[1],
                                      _videoFrame->linesize[1],
                                      _videoFrame->width/2,
                                      _videoFrame->height/2);
        
        frame.chromaR = copyFrameData(_videoFrame->data[2],
                                      _videoFrame->linesize[2],
                                      _videoFrame->width/2,
                                      _videoFrame->height/2);
    } else { // 转换成yuv420p
        if (!_swsContext && ![self setupScaler]) {
            NSLog(@"Faile setup video scaler");
            return nil;
        }
        uint8_t *const data[AV_NUM_DATA_POINTERS];
        int linesize[AV_NUM_DATA_POINTERS];
        sws_scale(_swsContext,
                  (const uint8_t **)_videoFrame->data,
                  _videoFrame->linesize,
                  0,
                  _videoCodecCtx->height,
                  data,
                  linesize);
        frame.luma = copyFrameData(data[0],
                                   linesize[0],
                                   _videoCodecCtx->width,
                                   _videoCodecCtx->height);
        frame.chromaB = copyFrameData(data[1],
                                      linesize[1],
                                      _videoCodecCtx->width / 2,
                                      _videoCodecCtx->height / 2);
        frame.chromaR = copyFrameData(data[2],
                                      linesize[2],
                                      _videoCodecCtx->width / 2,
                                      _videoCodecCtx->height / 2);
    }
    
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    frame.linesize = _videoFrame->linesize[0];
    frame.type = VideoFrameType;
    
    //时间
    frame.position = _videoFrame->best_effort_timestamp * _videoTimeBase;   // 视频通过best_effort_timestamp 而不是pts 获取当前一个画面的播放时间
    const int64_t frameDuration = _videoFrame->pkt_duration;  //pkt_duration 持续时间   以time_base为单位
    if (frameDuration) {
        frame.duration = frameDuration * _videoTimeBase;
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase * 0.5;  // repeat_pict 延迟
    } else {
        frame.duration = 1.0 / _fps;
    }
    return frame;
}

- (BOOL)setupScaler{
    [self closeScaler];
    int w = 812;
    int h = 375;
    /**
     * libswscale
     * 是一个主要用于处理图片像素数据的类库。可以完成图片像素格式的转换，图片的拉伸，图像的滤波
     * 主要的函数:
     * sws_getContext() / sws_getCachedContext()   初始化一个SwsContext  区别sws_getContext 可以用于多路码流转换，为每个不同的码流都指定一个不同的转换上下文，而 sws_getCachedContext 只能用于一路码流转换
     * sws_scale()   处理图像数据
     * sws_freeContext()   释放
     */
    _swsContext = sws_getCachedContext(_swsContext,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       _videoCodecCtx->pix_fmt,
                                       w,
                                       h,
                                       AV_PIX_FMT_YUV420P,
                                       SWS_FAST_BILINEAR,
                                       NULL,
                                       NULL,
                                       NULL);
    return _swsContext != NULL;
}

@end
