//
//  AudioOutput.h
//  Player
//
//  Created by luowailin on 2021/1/12.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol FillDataDelegate <NSObject>

- (NSInteger)fillAudioData:(SInt16 *)sampleBuffer
                 numFrames:(NSInteger)frameNum
               numChannels:(NSInteger)channels;

@end


@interface AudioOutput : NSObject

@property(nonatomic, assign) Float64 sampleRate;
@property(nonatomic, assign) Float64 channels;

- (instancetype)initWithChannels:(NSInteger)channels
                      sampleRate:(NSInteger)sampleRate
                  bytesPerSample:(NSInteger)bytePerSample
                fillDataDelegate:(id<FillDataDelegate>)delegate;
- (BOOL)play;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
