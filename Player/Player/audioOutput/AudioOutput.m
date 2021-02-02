//
//  AudioOutput.m
//  Player
//
//  Created by luowailin on 2021/1/12.
//

#import "AudioOutput.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import "BLAudioSession.h"

static const AudioUnitElement inputElement = 1;

static OSStatus InputRenderCallback(void *inRefCon,
                                    AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp,
                                    UInt32 inBusNumber,
                                    UInt32 inNumberFrames,
                                    AudioBufferList *ioData);

static void CheckStatus(OSStatus status,
                        NSString *message,
                        BOOL fatal) {
    if (status != noErr) {
        char fourCC[16];
        *(UInt32 *)fourCC = CFSwapInt32HostToBig(status);
        fourCC[4] = '\0';
        
        if (isprint(fourCC[0]) && isprint(fourCC[1]) && isprint(fourCC[2]) && isprint(fourCC[3])) {
            NSLog(@"%@:%s", message, fourCC);
        } else {
            NSLog(@"%@:%d", message, (int)status);
        }
        
        if (fatal) {
            exit(-1);
        }
    }
}

@interface AudioOutput (){
    SInt16 *_outData;
}
@property(nonatomic, assign) AUGraph auGraph;
@property(nonatomic, assign) AUNode ioNode;
@property(nonatomic, assign) AudioUnit ioUnit;

@property(nonatomic, assign) AUNode convertNode;
@property(nonatomic, assign) AudioUnit convertUnit;

@property(nonatomic, weak, readwrite) id<FillDataDelegate>fillAudioDataDelegate;

@end


@implementation AudioOutput

- (instancetype)initWithChannels:(NSInteger)channels
                      sampleRate:(NSInteger)sampleRate
                  bytesPerSample:(NSInteger)bytePerSample
                fillDataDelegate:(id<FillDataDelegate>)delegate{
    self = [super init];
    if (self) {
        [[BLAudioSession sharedInstance] setCategory:AVAudioSessionCategorySoloAmbient];
        [[BLAudioSession sharedInstance] setPreferredSampleRate:sampleRate];
        [[BLAudioSession sharedInstance] setActive:YES];
        [[BLAudioSession sharedInstance] addRouteChangeListener];
        
        [self addAudioSessionInterruptedObserver];
        
        _outData = (SInt16 *)calloc(8192, sizeof(SInt16));
        _fillAudioDataDelegate = delegate;
        _sampleRate = sampleRate;
        _channels = channels;
        [self createAudioUnitGraph];
    }
    return self;
}

- (BOOL)play{
    OSStatus status = AUGraphStart(_auGraph);
    CheckStatus(status, @"not start graph", YES);
    return YES;
}

- (void)stop{
    OSStatus status = AUGraphStop(_auGraph);
    CheckStatus(status, @"not stop graph", YES);
}

#pragma mark -- private method

- (void)createAudioUnitGraph {
    OSStatus status = noErr;
    
    status = NewAUGraph(&_auGraph);
    CheckStatus(status, @"new augraph faile", YES);
    
    [self addAudioUnitNodes];
    
    status = AUGraphOpen(_auGraph);
    CheckStatus(status, @"open augraph faile", YES);
    
    [self getUnitsFromNodes];
    
    [self setAudioUnitProperties];
    
    [self makeNodeConnections];
    
    CAShow(_auGraph);
    status = AUGraphInitialize(_auGraph);
    CheckStatus(status, @"initialize augraph faile", YES);
}

- (void)addAudioUnitNodes{
    OSStatus status = noErr;
    
    AudioComponentDescription ioDescription;
    bzero(&ioDescription, sizeof(ioDescription));
    ioDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    ioDescription.componentType = kAudioUnitType_Output;
    ioDescription.componentSubType = kAudioUnitSubType_RemoteIO;
    status = AUGraphAddNode(_auGraph, &ioDescription, &_ioNode);
    CheckStatus(status, @"add io node faile", YES);
    
    AudioComponentDescription convertDescription;
    bzero(&convertDescription, sizeof(convertDescription));
    convertDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    convertDescription.componentType = kAudioUnitType_FormatConverter;
    convertDescription.componentSubType = kAudioUnitSubType_AUConverter;
    
    status = AUGraphAddNode(_auGraph, &convertDescription, &_convertNode);
    CheckStatus(status, @"add convert node faile", YES);
}

- (void)getUnitsFromNodes{
    OSStatus status = noErr;
    status = AUGraphNodeInfo(_auGraph,
                             _ioNode,
                             NULL,
                             &_ioUnit);
    CheckStatus(status, @"node info ionode faile", YES);
    
    status = AUGraphNodeInfo(_auGraph,
                             _convertNode,
                             NULL,
                             &_convertUnit);
    CheckStatus(status, @"node info convert node faile", YES);
}

- (void)setAudioUnitProperties{
    OSStatus status = noErr;
    AudioStreamBasicDescription streamFormat = [self nonInterleavedPCMFormatWithChannels:_channels];
    status = AudioUnitSetProperty(_ioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  inputElement,
                                  &streamFormat,
                                  sizeof(streamFormat));
    CheckStatus(status, @"set property streamFormat faile", YES);
    
    AudioStreamBasicDescription _clientFormat16int;
    bzero(&_clientFormat16int, sizeof(_clientFormat16int));
    UInt32 bytesPerSample = sizeof(SInt16);
    _clientFormat16int.mFormatID = kAudioFormatLinearPCM;
    _clientFormat16int.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    _clientFormat16int.mBytesPerPacket = bytesPerSample * _channels;
    _clientFormat16int.mFramesPerPacket = 1;
    _clientFormat16int.mBytesPerFrame = bytesPerSample * _channels;
    _clientFormat16int.mChannelsPerFrame = _channels;
    _clientFormat16int.mBitsPerChannel = 8 * bytesPerSample;
    _clientFormat16int.mSampleRate = _sampleRate;
    
    status = AudioUnitSetProperty(_convertUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  0,
                                  &streamFormat,
                                  sizeof(streamFormat));
    CheckStatus(status, @"set property streamformat convert output faile", YES);
    
    status = AudioUnitSetProperty(_convertUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &_clientFormat16int,
                                  sizeof(_clientFormat16int));
    CheckStatus(status, @"set property streamformat convert input faile", YES);
}

- (AudioStreamBasicDescription)nonInterleavedPCMFormatWithChannels:(UInt32)channels{
    UInt32 bytesPerSample = sizeof(Float32);
    
    AudioStreamBasicDescription asbd;
    bzero(&asbd, sizeof(asbd));
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBytesPerPacket = bytesPerSample;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = bytesPerSample;
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = 8 * bytesPerSample;
    asbd.mSampleRate = _sampleRate;
    return asbd;
}

- (void)makeNodeConnections{
    
}

- (void)addAudioSessionInterruptedObserver{
    [self removeAudioSessionInterruptedObserver];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onNotificationAudioInterrupted:)
                                                 name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
}

- (void)removeAudioSessionInterruptedObserver {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioSessionInterruptionNotification
                                                  object:nil];
}

- (void)onNotificationAudioInterrupted:(NSNotification *)sender{
    AVAudioSessionInterruptionType type = [[[sender userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    switch (type) {
        case AVAudioSessionInterruptionTypeBegan:
            [self stop];
            break;
        case  AVAudioSessionInterruptionTypeEnded:
            [self play];
            break;
        default:
            break;
    }
}

@end
