//
//  AVAudioSession+RouteUtils.m
//  AUPlay
//
//  Created by luowailin on 2020/1/19.
//  Copyright © 2020 luowailin. All rights reserved.
//

#import "AVAudioSession+RouteUtils.h"

@implementation AVAudioSession (RouteUtils)

- (BOOL)usingBlueTooth{
    NSArray *inputs = self.currentRoute.inputs;
    NSArray *blueToolInputRoutes = @[AVAudioSessionPortBluetoothHFP, AVAudioSessionPortBluetoothA2DP];
    for (AVAudioSessionPortDescription *description in inputs) {
        if ([blueToolInputRoutes containsObject:description.portType]) {
            return YES;
        }
    }
    
    NSArray *outputs = self.currentRoute.outputs;
    NSArray *blueToothOutputRoutes = @[AVAudioSessionPortBluetoothHFP, AVAudioSessionPortBluetoothLE, AVAudioSessionPortBluetoothA2DP];
    for (AVAudioSessionPortDescription *desc in outputs) {
        if ([blueToothOutputRoutes containsObject:desc.portType]) {
            return YES;
        }
    }
    
    return NO;
}

- (BOOL)usingWireMicrophone{
    NSArray *inputs = self.currentRoute.inputs;
    NSArray *headSetInputRoutes = @[AVAudioSessionPortHeadsetMic];
    for (AVAudioSessionPortDescription *description in inputs) {
        if ([headSetInputRoutes containsObject:description.portType]) {
            return YES;
        }
    }
    
    NSArray *outputs = self.currentRoute.outputs;
    NSArray *headSetOutputRoutes = @[AVAudioSessionPortHeadphones, AVAudioSessionPortUSBAudio];
    for (AVAudioSessionPortDescription *desc in outputs) {
        if ([headSetOutputRoutes containsObject:desc.portType]) {
            return YES;
        }
    }
    
    return NO;
}

- (BOOL)shouldShowEarphoneAlert{
    NSArray *outputs = self.currentRoute.outputs;
    NSArray *headSetOutputRoutes = @[AVAudioSessionPortBuiltInReceiver, AVAudioSessionPortBuiltInSpeaker];
    for (AVAudioSessionPortDescription *desc in outputs) {
        if ([headSetOutputRoutes containsObject:desc.portType]) {
            return YES;
        }
    }
    
    return NO;
}

@end
