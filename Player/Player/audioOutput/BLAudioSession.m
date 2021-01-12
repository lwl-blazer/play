//
//  BLAudioSession.m
//  AUPlay
//
//  Created by luowailin on 2020/1/19.
//  Copyright © 2020 luowailin. All rights reserved.
//

#import "BLAudioSession.h"
#import "AVAudioSession+RouteUtils.h"

const NSTimeInterval AUSAudioSessionLatency_Background = 0.0929;
const NSTimeInterval AUSAudioSessionLatency_Default = 0.0232;
const NSTimeInterval AUSAudioSessionLatency_LowLatency = 0.0058;

@implementation BLAudioSession

+ (BLAudioSession *)sharedInstance{
    static BLAudioSession *instance = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BLAudioSession alloc] init];
    });
    return instance;
}

- (instancetype)init{
    self = [super init];
    if (self) {
        self.preferredSampleRate = _currentSampleRate = 44100.0;
        _currentSampleRate = 44100.0;
        self.audioSession = [AVAudioSession sharedInstance];
    }
    return self;
}

- (void)setCategory:(NSString *)category{
    _category = category;
    NSError *error = nil;
    if (![self.audioSession setCategory:category error:&error]) {
        NSLog(@"Could note set category on audio session: %@", error.localizedDescription);
    }
}

- (void)setCategoryOptions:(AVAudioSessionCategoryOptions)categoryOptions{
    if (self.category != nil) {
        NSError *error = nil;
        if (![self.audioSession setCategory:self.category withOptions:categoryOptions error:&error]) {
            NSLog(@"Could note set category options on audio session: %@", error.localizedDescription);
        }
    }
}


- (void)setActive:(BOOL)active{
    _active = active;
    
    NSError *error = nil;
    if (![self.audioSession setPreferredSampleRate:self.preferredSampleRate
                                             error:&error]) {
        NSLog(@"Error when setting sample rate on audio session:%@", error.localizedDescription);
    }
    
    if (![self.audioSession setActive:_active
                                error:&error]) {
        NSLog(@"Error when setting active state of audio session:%@", error.localizedDescription);
    }
    
    _currentSampleRate = [self.audioSession sampleRate];
}

- (void)setPreferredLatency:(NSTimeInterval)preferredLatency{
    _preferredLatency = preferredLatency;
    
    NSError *error = nil;
    if (![self.audioSession setPreferredIOBufferDuration:_preferredLatency
                                                   error:&error]) {
        NSLog(@"Error when setting preferred I/O buffer duration");
    }
}

- (void)addRouteChangeListener{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onNotificationAudioRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    [self adjustOnRouteChange];
}


- (void)onNotificationAudioRouteChange:(NSNotification *)sender{
    NSLog(@"%@", sender.userInfo);
    AVAudioSessionRouteChangeReason reason = [[sender.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:{
            NSLog(@"新设备可用");
            AVAudioSession *session = [AVAudioSession sharedInstance];
            for (AVAudioSessionPortDescription *desc in session.currentRoute.outputs) {
                NSLog(@"portType:%@---%@", desc.portType, desc.portName);
            }
            
        }
            break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:{
            NSLog(@"旧设备不可用");
            AVAudioSessionRouteDescription *previous = [sender.userInfo objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
            for (AVAudioSessionPortDescription *desc in previous.outputs) {
                NSLog(@"portType:%@---%@", desc.portType, desc.portName);
            }
        }
            break;
        default:
            NSLog(@"其它");
            break;
    }

    [self adjustOnRouteChange];
}

- (void)adjustOnRouteChange{

}

@end
