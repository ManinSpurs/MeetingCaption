#import "AudioCaptureTestSupport.h"

@interface MCThrowingTapNode : AVAudioMixerNode
@end
@implementation MCThrowingTapNode
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize
                format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Input HW format is invalid" userInfo:nil];
}
@end
AVAudioNode *MCMakeThrowingTapNode(void) { return [MCThrowingTapNode new]; }
