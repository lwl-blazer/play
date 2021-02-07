//
//  PlayerController.h
//  Player
//
//  Created by luowailin on 2021/2/5.
//

#import <Foundation/Foundation.h>
#import "AVSynchronizer.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlayerController : NSObject

+ (instancetype)viewControllerWithContentPath:(NSString *)path
usingHWCodec:(BOOL)usingHWCodec
playerStateDelegate:(id<PlayerStateDelegate>)playerStateDelegate
                                   parameters:(NSDictionary *)parameters;

- (NSInteger)getVideoDuration;
- (NSInteger)getVideoFrameWidth;
- (NSInteger)getVideoFrameHeight;

/** 配置 */
- (void)setup;
/**播放*/
- (void)play;
/**暂停*/
- (void)pause;
/**停止*/
- (void)stop;
/**继续播放*/
- (void)restart;

@end

NS_ASSUME_NONNULL_END
