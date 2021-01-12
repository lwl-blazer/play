//
//  AVAudioSession+RouteUtils.h
//  AUPlay
//
//  Created by luowailin on 2020/1/19.
//  Copyright © 2020 luowailin. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AVAudioSession (RouteUtils)

- (BOOL)usingBlueTooth;
- (BOOL)usingWireMicrophone;
- (BOOL)shouldShowEarphoneAlert;

@end

NS_ASSUME_NONNULL_END
