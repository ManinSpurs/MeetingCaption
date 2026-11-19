#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCAudioTap : NSObject
+ (BOOL)installInputTap:(AVAudioNode *)input
                format:(AVAudioFormat *)format
                 block:(AVAudioNodeTapBlock)block
                 error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
