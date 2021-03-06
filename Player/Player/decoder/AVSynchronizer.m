//
//  AVSynchronizer.m
//  Player
//
//  Created by luowailin on 2021/2/5.
//

#import "AVSynchronizer.h"
#import "VideoDecoder.h"
#import <pthread.h>

#define LOCAL_MIN_BUFFERED_DURATION 0.5
#define LOCAL_MAX_BUFFERED_DURATION 1.0
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0
#define LOCAL_AV_SYNC_MAX_TIME_DIFF 0.05
#define FIRST_BUFFER_DURATION 0.5

NSString *const kMIN_BUFFERED_DURATION = @"Min_Buffered_Duration";
NSString *const kMAX_BUFFERED_DURATION = @"Max_Buffered_Duration";

@interface AVSynchronizer () {
    pthread_mutex_t decoderFirstBufferLock;
    pthread_cond_t decoderFirstBufferCondition;
    pthread_t decoderFirstBufferThread;
    
    pthread_mutex_t videoDecoderLock;
    pthread_cond_t videoDecoderCondition;
    pthread_t videoDecoderThread;
}

@property(nonatomic, strong) VideoDecoder *decoder;

@property(nonatomic, strong) NSMutableArray *videoFrames;
@property(nonatomic, strong) NSMutableArray *audioFrames;

@property(nonatomic, copy) NSData *currentAudioFrame;
@property(nonatomic, assign) NSUInteger currentAudioFramePos;
@property(nonatomic, assign) CGFloat audioPosition;

@property(nonatomic, strong) VideoFrame *currentVideoFrame;

@property(nonatomic, assign) CGFloat minBufferedDuration;
@property(nonatomic, assign) CGFloat maxBufferedDuration;

@property(nonatomic, assign) BOOL completion;
@property(nonatomic, assign) BOOL buffered;
@property(nonatomic, assign) CGFloat bufferedDuration;

@property(nonatomic, assign) NSTimeInterval bufferedBeginTime;
@property(nonatomic, assign) NSTimeInterval bufferedTotalTime;

@property(nonatomic, assign) int decodeVideoErrorState;

@property(nonatomic, assign) CGFloat syncMaxTimeDiff;

@property(nonatomic, assign) NSTimeInterval decodeVideoErrorBeginTime;
@property(nonatomic, assign) NSTimeInterval decodeVideoErrorTotalTime;

@property(nonatomic, assign) BOOL isDestroyed;
@property(nonatomic, assign) BOOL isDecodingFirstBuffer;
@property(nonatomic, assign) BOOL isOnDecoding;
@property(nonatomic, assign) BOOL isInitializeDecodeThread;

@property(nonatomic, assign) BOOL isFirstScreen;
@property(nonatomic, assign) BOOL usingHWCodec;

@end

@implementation AVSynchronizer

static BOOL isNetworkPath(NSString *path) {
    NSRange r = [path rangeOfString:@":"];
    if (r.location == NSNotFound) {
        return NO;
    }
    
    NSString *scheme = [path substringToIndex:r.length];
    if ([scheme isEqualToString:@"file"]) {
        return NO;
    }
    return YES;
}


#pragma mark -- public method

- (instancetype)initWithPlayerStateDelegate:(id<PlayerStateDelegate>)playerStateDelegate{
    self = [super init];
    if (self) {
        _playerStateDelegate = playerStateDelegate;
    }
    return self;
}

- (OpenState)openFile:(NSString *)path
         usingHWCodec:(BOOL)usingHWCodec
                error:(NSError *__autoreleasing  _Nullable *)perror{
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    parameters[FPS_PROBE_SIZE_CONFIGURED] = @(true);
    parameters[PROBE_SIZE] = @(50 * 1024);
    NSArray *durations = @[@(1250000),
                           @(1750000),
                           @(200000)];
    parameters[MAX_ANALYZE_DURATION_ARRAY] = durations;
    return [self openFile:path
             usingHWCodec:usingHWCodec
               parameters:parameters.copy
                    error:perror];
}

- (OpenState)openFile:(NSString *)path
         usingHWCodec:(BOOL)usingHWCodec
           parameters:(NSDictionary *)parameters
                error:(NSError *__autoreleasing  _Nullable *)perror{
    
    self.usingHWCodec = usingHWCodec;
    [self createDecoderInstance];
    
    self.currentVideoFrame = NULL;
    self.currentAudioFramePos = 0;
    
    self.bufferedBeginTime = 0;
    self.bufferedTotalTime = 0;
    
    self.decodeVideoErrorBeginTime = 0;
    self.decodeVideoErrorTotalTime = 0;
    self.isFirstScreen = YES;
    
    self.minBufferedDuration = [parameters[kMIN_BUFFERED_DURATION] floatValue];
    self.maxBufferedDuration = [parameters[kMAX_BUFFERED_DURATION] floatValue];
    
    BOOL isNetwork = isNetworkPath(path);
    if (ABS(self.minBufferedDuration - 0.0f) < CGFLOAT_MIN) {
        if (isNetwork) {
            self.minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
        } else {
            self.minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
        }
    }
    
    if (ABS(self.maxBufferedDuration - 0.0f) < CGFLOAT_MIN) {
        if (isNetwork) {
            self.maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
        } else {
            self.maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }
    }
    
    if (self.minBufferedDuration > self.maxBufferedDuration) {
        float temp = self.minBufferedDuration;
        self.minBufferedDuration = self.maxBufferedDuration;
        self.maxBufferedDuration = temp;
    }
    
    self.syncMaxTimeDiff = LOCAL_AV_SYNC_MAX_TIME_DIFF;
    
    BOOL openCode = [self.decoder openFile:path
                                 parameter:parameters
                                     error:perror];
    if (!openCode || ![self.decoder isSubscribed] || self.isDestroyed) {
        [self closeDecoder];
        return [self.decoder isSubscribed] ? OPEN_FAILED : CLIENT_CANCEL;
    }
    
    NSUInteger videoWidth = [self.decoder frameWidth];
    NSUInteger videoHeight = [self.decoder frameHeight];
    if (videoWidth <= 0 || videoHeight <= 0) {
        return [self.decoder isSubscribed] ? OPEN_FAILED : CLIENT_CANCEL;
    }
    
    self.audioFrames = [NSMutableArray array];
    self.videoFrames = [NSMutableArray array];
    
    [self startDecoderThread];
    [self startDecoderFirstBufferThread];
    
    return OPEN_SUCCESS;
}

- (void)audioCallbackFillData:(SInt16 *)outData
                    numFrames:(UInt32)numFrames
                  numChannels:(UInt32)numChannels{
    //是否需要解码， 失败，完成的状态处理
    [self checkPlayState];
    
    if (self.buffered) {
        memset(outData, 0, numFrames * numChannels * sizeof(SInt16));
        return;
    }
    
    // 填充数据
    @autoreleasepool {
        // numFrames 总共需要多少帧
        while (numFrames > 0) {
            if (!self.currentAudioFrame) { // 音频数据为空 从队列中取音频数据
                @synchronized (self.audioFrames) {
                    NSUInteger count = self.audioFrames.count;
                    if (count > 0) {
                        AudioFrame *frame = self.audioFrames[0];
                        self.bufferedDuration -= frame.duration;
                        [self.audioFrames removeObjectAtIndex:0];
                        
                        self.audioPosition = frame.position;
                        self.currentAudioFramePos = 0;
                        self.currentAudioFrame = frame.samples;
                    }
                }
            }
            
            if (self.currentAudioFrame) { // 填充音频数据
                const void *bytes = (Byte *)self.currentAudioFrame.bytes + self.currentAudioFramePos;
                
                //当前音频帧剩下多少长数据
                const NSUInteger bytesLeft = (self.currentAudioFrame.length - self.currentAudioFramePos);
                
                //每帧数据的大小
                const NSUInteger frameSizeOf = numChannels *sizeof(SInt16);
                
                // 最小拷贝的数据长度(numFrames * frameSizeOf 最小需要的数据量)
                const NSUInteger bytesToCopy = MIN(numFrames * frameSizeOf, bytesLeft);
                
                // 拷贝的帧数
                const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;
                
                //拷贝数据
                memcpy(outData, bytes, bytesToCopy);
                
                // 减掉已经拷贝的帧数
                numFrames -= framesToCopy;
                
                /**注意点:
                 * 拷贝数据的长度是bytesToCopy 但是outData移位的长度是 framesToCopy * numChannels，因为outdata是SInt16(2个字节) 而bytes是Byte(SInt8 1个字节)类型
                 */
                //注意点，
                outData += framesToCopy * numChannels;
//                outData += bytesToCopy / sizeof(SInt16);
                
                //如果数据还没有拷贝完，移位
                if (bytesToCopy < bytesLeft) {
                    self.currentAudioFramePos += bytesToCopy;
                } else { // 已经拷贝完，赋nil
                    self.currentAudioFrame = nil;
                }
            } else {
                // 填充静音数据
                memset(outData, 0, numFrames * numChannels * sizeof(SInt16));
                break;
            }
        }
    }
}

// 音视频同步
static int count = 0;
static int invalidGetCount = 0;
float lastPostion = -1.0;
- (VideoFrame *)getCorrectVideoFrame{
    VideoFrame *frame = NULL;
    @synchronized (self.videoFrames) {
        while (self.videoFrames.count > 0) {
            frame = self.videoFrames[0];
            //音频position 和 视频的position 的差值 是否在syncMaxTimeDiff的范围内
            const CGFloat delta = self.audioPosition - frame.position;
            if (delta < (0 - self.syncMaxTimeDiff)) { // 如果frame.position 大于 audioPosition 那delta 为负数 且小于-self.syncMaxTimeDiff
                frame = NULL;
                break; // 说明视频帧太快，界面显示原有视频帧，不能删除队列中的视频帧 所以需要break
            }
            
            [self.videoFrames removeObjectAtIndex:0]; // 清除
            if (delta > self.syncMaxTimeDiff) { //视频太慢
                frame = NULL;
                continue;
            } else { // 刚刚好
                break;
            }
        }
    }
    
    if (frame) {
        if (self.isFirstScreen) { // 首屏
            [self.decoder triggerFirstScreen]; // 首屏完成时间
            self.isFirstScreen = NO;
        }
        
        // 赋值
        if (self.currentVideoFrame != NULL) {
            self.currentVideoFrame = NULL;
        }
        self.currentVideoFrame = frame;
    }
    
    if (fabs(self.currentVideoFrame.position - lastPostion) > 0.01f) {
        lastPostion = self.currentVideoFrame.position;
        count ++;
        return self.currentVideoFrame;
    } else {
        invalidGetCount ++;
        return NULL;
    }
}

- (void)closeFile{
    if (self.decoder) {
        [self.decoder interrupt];
    }
    
    [self destoryDecodeFirstBufferThread];
    [self destoryDecodeThread];
    
    if ([self.decoder isOpenInputSuccess]) {
        [self closeDecoder];
    }
    
    @synchronized (self.videoFrames) {
        [self.videoFrames removeAllObjects];
    }
    
    @synchronized (self.audioFrames) {
        [self.audioFrames removeAllObjects];
        self.currentAudioFrame = nil;
    }
}

- (void)interrupt{
    if (self.decoder) {
        [self.decoder interrupt];
    }
}

- (NSInteger)getVideoTotalDuration {
    BuriedPoint *point = [self.decoder getBuriedPoint];
    return point.second;
}

- (NSInteger)getVideoFrameWidth{
    if (self.decoder) {
        return [self.decoder frameWidth];
    }
    return 0;
}

- (NSInteger)getVideoFrameHeight {
    if (self.decoder) {
        return [self.decoder frameHeight];
    }
    return 0;
}

- (NSInteger)getAudioChannels{
    if (self.decoder) {
        return [self.decoder channels];
    }
    return -1;
}

- (NSInteger)getAudioSampleRate{
    if (self.decoder) {
        return [self.decoder sampleRate];
    }
    return -1;
}

- (BOOL)usingHWCodec{
    return _usingHWCodec;
}

- (BOOL)isPlayCompleted{
    return self.completion;
}

- (BOOL)isOpenInputSuccess{
    if (self.decoder) {
        return [self.decoder isOpenInputSuccess];
    }
    return NO;
}

#pragma mark -- private method
- (void)createDecoderInstance {
    if (self.usingHWCodec) {
        
    } else {
        self.decoder = [[VideoDecoder alloc] init];
    }
}

- (void)closeDecoder {
    if (self.decoder) {
        [self.decoder closeFile];
        if (_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(buriedPointCallback:)]) {
            [_playerStateDelegate buriedPointCallback:[self.decoder getBuriedPoint]];
        }
        self.decoder = nil;
    }
}

static void *runDecoderThread(void *ptr) {
    AVSynchronizer *synchronizer = (__bridge AVSynchronizer *)(ptr);
    [synchronizer run];
    return NULL;
}

static void *decoderFirstBufferRunLoop(void *ptr) {
    AVSynchronizer *synchronizer = (__bridge AVSynchronizer *)(ptr);
    [synchronizer decodeFirstBuffer];
    return NULL;
}

- (void)startDecoderThread {
    self.isOnDecoding = YES;
    self.isDestroyed = NO;
    
    pthread_mutex_init(&videoDecoderLock, NULL);
    pthread_cond_init(&videoDecoderCondition, NULL);
    self.isInitializeDecodeThread = YES;
    
    //线程
    pthread_create(&videoDecoderThread,
                   NULL,
                   runDecoderThread,
                   (__bridge  void *)(self));
}

- (void)startDecoderFirstBufferThread {
    pthread_mutex_init(&decoderFirstBufferLock, NULL);
    pthread_cond_init(&decoderFirstBufferCondition, NULL);
    self.isDecodingFirstBuffer = YES;
    
    pthread_create(&decoderFirstBufferThread,
                   NULL,
                   decoderFirstBufferRunLoop,
                   (__bridge void *)(self));
}

- (void)run {
    // 只要isOnDecoding不为false 就会一直运行
    while (self.isOnDecoding) {
        pthread_mutex_lock(&videoDecoderLock);
        pthread_cond_wait(&videoDecoderCondition, &videoDecoderLock);
        pthread_mutex_unlock(&videoDecoderLock);
        [self decodeFrames];
    }
}

- (void)decodeFrames {
    const CGFloat duration = 0.0;
    BOOL good = YES;
    while (good) {
        good = NO;
        @autoreleasepool {
            if (self.decoder && (self.decoder.validAudio || self.decoder.validVideo)) {
                NSArray *frames = [self.decoder decodeFrames:duration
                                       decodeVideoErrorState:&_decodeVideoErrorState]; // 每次只解一帧数据，因为duration为0.0 为什么用NSArray因为音频有可能有多个音频帧
                if (frames.count) {
                    good = [self addFrames:frames
                                  duration:self.maxBufferedDuration];
                }
            }
        }
    }
}

- (void)decodeFirstBuffer {
    double startDecodeFirstBufferTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
    [self decoderFrameWithDuration:FIRST_BUFFER_DURATION];
    int wasteTimeMills = CFAbsoluteTimeGetCurrent() * 1000 - startDecodeFirstBufferTimeMills;
    NSLog(@"Decode First Buffer waste TimeMills is %d", wasteTimeMills);
    
    pthread_mutex_lock(&decoderFirstBufferLock);
    pthread_cond_signal(&decoderFirstBufferCondition);
    pthread_mutex_unlock(&decoderFirstBufferLock);
    
    self.isDecodingFirstBuffer = false;
}

- (void)decoderFrameWithDuration:(CGFloat)duration{
    BOOL good = YES;
    while (good) {
        good = NO;
        @autoreleasepool {
            if (self.decoder && (self.decoder.validVideo || self.decoder.validAudio)) {
                int tmpDecodeVideoErrorState;
                NSArray *frames = [self.decoder decodeFrames:0.0f decodeVideoErrorState:&tmpDecodeVideoErrorState];
                if (frames.count) {
                    good = [self addFrames:frames duration:duration];
                }
            }
        }
    }
}

- (BOOL)addFrames:(NSArray *)frames
         duration:(CGFloat)duration {
    if (self.decoder.validVideo) {
        @synchronized (self.videoFrames) {
            for (Frame *frame in frames) {
                if (frame.type == VideoFrameType || frame.type == iOSCVVideoFrameType) {
                    [self.videoFrames addObject:frame];
                }
            }
        }
    }
    
    if (self.decoder.validAudio) {
        @synchronized (self.audioFrames) {
            for (Frame *frame in frames) {
                if (frame.type == AudioFrameType) {
                    [self.audioFrames addObject:frame];
                    self.bufferedDuration += frame.duration;
                }
            }
        }
    }
    
    return self.bufferedDuration < duration;
}

- (void)checkPlayState {
    if (self.decoder == NULL) {
        return;
    }
    
    if (1 == self.decodeVideoErrorState) { // 解码失败
        self.decodeVideoErrorState = 0;
        if (self.minBufferedDuration > 0 && !self.buffered) {
            self.buffered = YES;
            self.decodeVideoErrorBeginTime = [[NSDate date] timeIntervalSince1970];
        }
        
        self.decodeVideoErrorTotalTime = [[NSDate date] timeIntervalSince1970] - self.decodeVideoErrorBeginTime;
        if (self.decodeVideoErrorTotalTime > TIMEOUT_DECODE_ERROR) {
            self.decodeVideoErrorTotalTime = 0.0;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongify = weakSelf;
                if (strongify.playerStateDelegate && [strongify.playerStateDelegate respondsToSelector:@selector(restart)]) {
                    [strongify.playerStateDelegate restart];
                }
            });
        }
        return;
    }
    
    const NSUInteger leftVideoFrames = self.decoder.validVideo ? self.videoFrames.count : 0;
    const NSUInteger leftAudioFrames = self.decoder.validAudio ? self.audioFrames.count : 0;
    
    if (leftVideoFrames == 0 || leftAudioFrames == 0) { //没有视频和音频帧
        [self.decoder addBufferStatusRecord:@"E"];
        if (self.minBufferedDuration > 0 && !self.buffered) { // 加载中...
            self.buffered = YES;
            self.bufferedBeginTime = [[NSDate date] timeIntervalSince1970];
            if (self.playerStateDelegate && [self.playerStateDelegate respondsToSelector:@selector(showLoading)]) {
                [self.playerStateDelegate showLoading];
            }
        }
        
        if ([self.decoder isEOF]) { //已经解码完
            if (self.playerStateDelegate && [self.playerStateDelegate respondsToSelector:@selector(onCompletion)]) {
                self.completion = YES;
                [self.playerStateDelegate onCompletion];
            }
        }
    }
    
    if (self.buffered) { // 没有数据
        self.bufferedTotalTime = [[NSDate date] timeIntervalSince1970] - self.bufferedBeginTime;
        if (self.bufferedTotalTime > TIMEOUT_BUFFER) { // 超时
            self.bufferedTotalTime = 0;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongify = weakSelf;
                if (strongify.playerStateDelegate && [strongify.playerStateDelegate respondsToSelector:@selector(restart)]) {
                    [strongify.playerStateDelegate restart];
                }
            });
            return;
        }
    }
    
    if (!self.isDecodingFirstBuffer && (0 == leftVideoFrames || 0 == leftAudioFrames || !(self.bufferedDuration > self.minBufferedDuration))) {
        [self signalDecoderThread];
    } else if (self.bufferedDuration >= self.maxBufferedDuration) {
        [self.decoder addBufferStatusRecord:@"F"];
    }
}

- (void)signalDecoderThread {
    if (self.decoder == NULL || self.isDestroyed) {
        return;
    }
    
    if (!self.isDestroyed) {
        pthread_mutex_lock(&videoDecoderLock);
        pthread_cond_signal(&videoDecoderCondition);
        pthread_mutex_unlock(&videoDecoderLock);
    }
}

- (void)destoryDecodeFirstBufferThread {
    if (self.isDecodingFirstBuffer) {
        double startWaitDecodeFirstBufferTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
        pthread_mutex_lock(&decoderFirstBufferLock);
        pthread_cond_wait(&decoderFirstBufferCondition, &decoderFirstBufferLock);
        pthread_mutex_unlock(&decoderFirstBufferLock);
        
        pthread_cond_destroy(&decoderFirstBufferCondition);
        pthread_mutex_destroy(&decoderFirstBufferLock);
        
        int wasteTimeMills = CFAbsoluteTimeGetCurrent() * 1000 - startWaitDecodeFirstBufferTimeMills;
        NSLog(@" Wait Decode First Buffer waste TimeMills is %d", wasteTimeMills);
    }
}

// 销毁解码线程
- (void)destoryDecodeThread {
    /**
     * 销毁解码线程的注意事项:
     * 1. 先将isOnDecoding设置为NO，就不循环了
     * 2. 还需要额外发送一次signal指令，让解码线程有机会结束，如果不发送signal指令，那么解码线程就有可能一直wait在这里，成为一个僵尸线程
     *
     */
    self.isDestroyed = YES;
    self.isOnDecoding = NO;
    if (!self.isInitializeDecodeThread) {
        return;
    }
    
    void *status;
    pthread_mutex_lock(&videoDecoderLock);
    pthread_cond_signal(&videoDecoderCondition);
    pthread_mutex_unlock(&videoDecoderLock);
    
    // pthread_join(pthread_t thread, void *retval)  以阻塞的方式等待thread指定线程的结束
    pthread_join(videoDecoderThread, &status);
    pthread_mutex_destroy(&videoDecoderLock);
    pthread_cond_destroy(&videoDecoderCondition);
}

@end
