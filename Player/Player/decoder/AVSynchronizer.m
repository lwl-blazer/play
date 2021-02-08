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
    
}

- (void)decodeFirstBuffer {
    
}

@end
