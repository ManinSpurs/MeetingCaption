#import "AudioCaptureBridge.h"

@implementation MCAudioTap
+ (BOOL)installInputTap:(AVAudioNode *)input
                format:(AVAudioFormat *)format
                 block:(AVAudioNodeTapBlock)block
                 error:(NSError **)error {
    // Catch inside ObjC: foreign exceptions must not unwind through Swift async frames.
    @try {
        [input installTapOnBus:0 bufferSize:2048 format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"MeetingCaption.AudioCapture" code:1 userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"마이크 입력을 시작하지 못했습니다.",
                @"ExceptionName": exception.name
            }];
        }
        return NO;
    }
}
@end
