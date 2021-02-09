//
//  PlayerController.m
//  Player
//
//  Created by luowailin on 2021/2/5.
//

#import "PlayerController.h"
#import "VideoDecoder.h"
#import "AudioOutput.h"
#import "AVSynchronizer.h"

@interface PlayerController ()<FillDataDelegate>

@property(nonatomic, assign) BOOL usingHWCodec;
@property(nonatomic, assign) BOOL isPlaying;

@property(nonatomic, copy) NSString *videoFilePath;
@property(nonatomic, copy) NSDictionary *parameters;
@property(nonatomic, weak) id<PlayerStateDelegate>playerStateDelegate;

@property(nonatomic, strong) EAGLSharegroup *shareGroup;
@property(nonatomic, strong) AVSynchronizer *synchronizer;
@property(nonatomic, strong) AudioOutput *audioOutput;

@end


@implementation PlayerController

+ (instancetype)viewControllerWithContentPath:(NSString *)path
                                 usingHWCodec:(BOOL)usingHWCodec
                          playerStateDelegate:(id<PlayerStateDelegate>)playerStateDelegate
                                    parameters:(NSDictionary *)parameters{
    return [[PlayerController alloc] initWithContentPath:path
                                            usingHWCodec:usingHWCodec
                                            playerStateDelegate:playerStateDelegate
                                            parameters:parameters
                                            outputEAGLContextShareGroup:nil];
}

- (void)setup{
    self.synchronizer = [[AVSynchronizer alloc] initWithPlayerStateDelegate:self.playerStateDelegate];
    __weak typeof(PlayerController *) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        __strong typeof(PlayerController *) strongSelf = weakSelf;
        NSError *error = nil;
        OpenState state = OPEN_FAILED;
        if (strongSelf.parameters.count > 0) {
            state = [strongSelf.synchronizer openFile:strongSelf.videoFilePath
                                         usingHWCodec:strongSelf.usingHWCodec
                                           parameters:strongSelf.parameters
                                                error:&error];
        } else {
            state = [strongSelf.synchronizer openFile:strongSelf.videoFilePath
                                         usingHWCodec:strongSelf.usingHWCodec
                                                error:&error];
        }
        strongSelf.usingHWCodec = [self.synchronizer usingHWCodec];
        if (state == OPEN_SUCCESS) {
            NSInteger audioChannels = [strongSelf->_synchronizer getAudioChannels];
            NSInteger audioSampleRate = [strongSelf->_synchronizer getAudioSampleRate];
            NSInteger bytesPerSample = 2;
            strongSelf.audioOutput = [[AudioOutput alloc] initWithChannels:audioChannels
                                                                sampleRate:audioSampleRate
                                                                bytesPerSample:bytesPerSample
                                                          fillDataDelegate:strongSelf];
            [strongSelf.audioOutput play];
            strongSelf.isPlaying = YES;
            if (strongSelf.playerStateDelegate && [strongSelf.playerStateDelegate respondsToSelector:@selector(openSucced)]) {
                [strongSelf.playerStateDelegate openSucced];
            }
        } else if (state == OPEN_FAILED) {
            if (strongSelf.playerStateDelegate && [strongSelf.playerStateDelegate respondsToSelector:@selector(connectFailed)]) {
                [strongSelf.playerStateDelegate connectFailed];
            }
        }
    });
}


- (NSInteger)getVideoFrameWidth{
    return [self.synchronizer getVideoFrameWidth];
}

- (NSInteger)getVideoFrameHeight {
    return [self.synchronizer getVideoFrameHeight];
}

- (NSInteger)getVideoDuration{
    return [self.synchronizer getVideoTotalDuration];
}

- (void)play{
    if (self.isPlaying) {
        return;
    }
    
    if (self.audioOutput) {
        [self.audioOutput play];
        self.isPlaying = YES;
    }
}

- (void)pause {
    if (!self.isPlaying) {
        return;
    }
    
    if (self.audioOutput) {
        [self.audioOutput stop];
        self.isPlaying = NO;
    }
}

- (void)stop{
    if (self.audioOutput) {
        [self.audioOutput stop];
        self.audioOutput = nil;
    }
    
    if (self.synchronizer) {
        if ([self.synchronizer isOpenInputSuccess]) {
            [self.synchronizer closeFile];
            self.synchronizer = nil;
        } else {
            [self.synchronizer interrupt];
        }
    }
}

- (void)restart{
    [self stop];
    [self setup];
}

#pragma mark -- FillDataDelegate
- (NSInteger)fillAudioData:(SInt16 *)sampleBuffer
                 numFrames:(NSInteger)frameNum
               numChannels:(NSInteger)channels{
    if (self.synchronizer && ![self.synchronizer isPlayCompleted]) {
        [self.synchronizer audioCallbackFillData:sampleBuffer
                                       numFrames:(UInt32)frameNum
                                     numChannels:(UInt32)channels];
        
       [self.synchronizer getCorrectVideoFrame];
    } else {
        memset(sampleBuffer, 0, frameNum * channels * sizeof(SInt16));
    }
    return 1;
}


#pragma mark -- private method
- (instancetype)initWithContentPath:(NSString *)path
                       usingHWCodec:(BOOL)usingHWCodec
                playerStateDelegate:(id<PlayerStateDelegate>)playerStateDelegate
                         parameters:(NSDictionary *)parameters
        outputEAGLContextShareGroup:(EAGLSharegroup *)sharegroup {
    self = [super init];
    if (self) {
        self.usingHWCodec = usingHWCodec;
        self.parameters = parameters;
        self.videoFilePath = path;
        self.playerStateDelegate = playerStateDelegate;
        self.shareGroup = sharegroup;
    }
    return self;
}

@end
