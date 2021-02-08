//
//  ViewController.m
//  Player
//
//  Created by luowailin on 2021/1/4.
//

#import "ViewController.h"
#import "PlayerController.h"

@interface ViewController ()<PlayerStateDelegate>

@property(nonatomic, strong) PlayerController *playerController;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.playerController = [PlayerController viewControllerWithContentPath:@""
                                                               usingHWCodec:NO
                                                        playerStateDelegate:self
                                                                 parameters:@{}];
    [self.playerController setup];
}

- (IBAction)playerAction:(UIButton *)sender {
    sender.selected = !sender.selected;
    
    if (sender.selected) {
        [self.playerController play];
    } else {
        [self.playerController pause];
    }
}


@end
