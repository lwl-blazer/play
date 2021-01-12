//
//  BLAudioSession.h
//  AUPlay
//
//  Created by luowailin on 2020/1/19.
//  Copyright © 2020 luowailin. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const NSTimeInterval AUSAudioSessionLatency_Background;
extern const NSTimeInterval AUSAudioSessionLatency_Default;
extern const NSTimeInterval AUSAudioSessionLatency_LowLatency;

@interface BLAudioSession : NSObject

+ (BLAudioSession *)sharedInstance;

@property(nonatomic, strong) AVAudioSession *audioSession;
@property(nonatomic, assign) Float64 preferredSampleRate;
@property(nonatomic, assign, readonly) Float64 currentSampleRate;

@property(nonatomic, assign) NSTimeInterval preferredLatency;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, strong) NSString *category;
@property(nonatomic, assign) AVAudioSessionCategoryOptions categoryOptions;

- (void)addRouteChangeListener;

@end

NS_ASSUME_NONNULL_END
