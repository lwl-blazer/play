//
//  VideoDecoder.h
//  Player
//
//  Created by luowailin on 2021/1/6.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum: NSUInteger {
    AudioFrameType,
    VideoFrameType,
    iOSCVVideoFrameType
}FrameType;

@interface BuriedPoint : NSObject

//开始试图去打开一个直播流的绝对时间
@property(readwrite, nonatomic, assign) long long beginOpen;

//成功打开流花费时间
@property(readwrite, nonatomic, assign) float successOpen;

//首屏时间
@property(readwrite, nonatomic, assign) float firstScreenTimeMills;

//流打开失败花费时间
@property(readwrite, nonatomic, assign) float failOpen;

//流打开失败类型
@property(readwrite, nonatomic, assign) float failOpenType;

//打开流重试次数
@property(readwrite, nonatomic, assign) int retryTimes;

//拉流时长
@property(readwrite, nonatomic, assign) float duration;

//拉流状态
@property(readwrite, nonatomic, strong) NSMutableArray *bufferStatusRecords;

//视频总时长
@property(readwrite, nonatomic, assign) int second;

@end

@interface Frame : NSObject

@property(nonatomic, readwrite, assign) FrameType type;
@property(nonatomic, readwrite, assign) CGFloat position;
@property(nonatomic, readwrite, assign) CGFloat duration;

@end

@interface AudioFrame : Frame

@property(nonatomic, readwrite, strong) NSData *samples;

@end

@interface VideoFrame: Frame

@property(nonatomic, readwrite, assign) NSUInteger width;
@property(nonatomic, readwrite, assign) NSUInteger height;
@property(nonatomic, readwrite, assign) NSUInteger linesize;

@property(nonatomic, readwrite, strong) NSData *luma;
@property(nonatomic, readwrite, strong) NSData *chromaB;
@property(nonatomic, readwrite, strong) NSData *chromaR;
@property(nonatomic, readwrite, strong) id imageBuffer;

@end

#ifndef SUBSCRIBE_VIDEO_DATA_TIME_OUT
#define SUBSCRIBE_VIDEO_DATA_TIME_OUT 20
#endif

#ifndef NET_WORK_STREAM_RETRY_TIME
#define NET_WORK_STREAM_RETRY_TIME 3
#endif

#ifndef RTM_TCURL_KEY
#define RTM_TCURL_KEY @"RTMP_TCURL_KEY"
#endif


#ifndef FPS_PROBE_SIZE_CONFIGURED
#define FPS_PROBE_SIZE_CONFIGURED @"FPS_PROBE_SIZE_CONFIGURED"
#endif

#ifndef PROBE_SIZE
#define PROBE_SIZE @"PROBE_SIZE"
#endif

#ifndef MAX_ANALYZE_DURATION_ARRAY
#define MAX_ANALYZE_DURATION_ARRAY @"MAX_ANALYZE_DURATION_ARRAY"
#endif

@interface VideoDecoder : NSObject

//打开解码器
- (BOOL)openFile:(NSString *)path
       parameter:(NSDictionary *)parameters
           error:(NSError * _Nullable __autoreleasing *)perror;

//解码
- (NSArray *)decodeFrames:(CGFloat)minDuration
    decodeVideoErrorState:(int *)decodeVideoErrorState;

- (BuriedPoint *)getBuriedPoint;

- (void)addBufferStatusRecord:(NSString *)statusFlag;
- (void)triggerFirstScreen;
- (void)closeFile;
- (void)interrupt;


- (NSUInteger)frameWidth;
- (NSUInteger)frameHeight;
- (NSUInteger)channels;
- (CGFloat)sampleRate;

- (BOOL)isSubscribed;
- (BOOL)validVideo;
- (BOOL)validAudio;
//是否成功打开文件
- (BOOL)isOpenInputSuccess;
//解码此帧失败
- (BOOL)isEOF;

@end

NS_ASSUME_NONNULL_END
