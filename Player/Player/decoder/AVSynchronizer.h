//
//  AVSynchronizer.h
//  Player
//
//  Created by luowailin on 2021/2/5.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define TIMEOUT_DECODE_ERROR 20
#define TIMEOUT_BUFFER 100

typedef enum : NSInteger {
    OPEN_SUCCESS,
    OPEN_FAILED,
    CLIENT_CANCEL
} OpenState;


@class BuriedPoint, VideoFrame;
@protocol PlayerStateDelegate <NSObject>

@optional
- (void)openSucced;
- (void)connectFailed;
- (void)hideLoading;
- (void)showLoading;
- (void)onCompletion;
- (void)buriedPointCallback:(BuriedPoint *)buriedPoint;
- (void)restart;
- (void)playDuration:(double)duration;

@end


@interface AVSynchronizer : NSObject

@property(nonatomic, weak) id<PlayerStateDelegate>playerStateDelegate;

- (instancetype)initWithPlayerStateDelegate:(id<PlayerStateDelegate>)playerStateDelegate;

- (OpenState)openFile:(NSString *)path
         usingHWCodec:(BOOL)usingHWCodec
           parameters:(NSDictionary *)parameters
                error:(NSError **)perror;


- (OpenState)openFile:(NSString *)path
         usingHWCodec:(BOOL)usingHWCodec
                error:(NSError **)perror;


- (VideoFrame *)getCorrectVideoFrame;

- (void)audioCallbackFillData:(SInt16 *)outData
                    numFrames:(UInt32)numFrames
                  numChannels:(UInt32)numChannels;

- (void)closeFile;

- (void)interrupt;

- (NSInteger)getVideoTotalDuration;
- (NSInteger)getVideoFrameWidth;
- (NSInteger)getVideoFrameHeight;
- (NSInteger)getAudioChannels;
- (NSInteger)getAudioSampleRate;

- (BOOL)usingHWCodec;
- (BOOL)isPlayCompleted;
- (BOOL)isOpenInputSuccess;

@end

NS_ASSUME_NONNULL_END
