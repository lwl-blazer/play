//
//  ViewController.m
//  Player
//
//  Created by luowailin on 2021/1/4.
//

#import "ViewController.h"
#import "PlayerController.h"

NSString *const MIN_BUFFERED_DURATION = @"Min Buffered Duration";
NSString *const MAX_BUFFERED_DURATION = @"Max Buffered Duration";

@interface ViewController ()<PlayerStateDelegate>

@property(nonatomic, strong) PlayerController *playerController;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *pathString = [[NSBundle mainBundle] pathForResource:@"music2" ofType:@"flv"];
    NSLog(@"%@", pathString);
    self.playerController = [PlayerController viewControllerWithContentPath:pathString
                                                               usingHWCodec:NO
                                                        playerStateDelegate:self
                                                                 parameters:[NSDictionary dictionaryWithObjectsAndKeys:@(2.0), MIN_BUFFERED_DURATION,
                                                                             @(4.0), MAX_BUFFERED_DURATION, nil]];
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

- (IBAction)restart:(id)sender {
    [self.playerController restart];
}

@end
