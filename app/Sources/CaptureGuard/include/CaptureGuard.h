#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

NSError * _Nullable PraatvolInstallMicrophoneTap(
    AVAudioInputNode *input, AVAudioFormat *expectedFormat, AVAudioNodeTapBlock callback);
NSError * _Nullable PraatvolStartMicrophoneEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
