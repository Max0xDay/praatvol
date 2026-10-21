#import "CaptureGuard.h"
#import <math.h>

static NSError *CaptureFailure(NSInteger code) {
    return [NSError errorWithDomain:@"com.praatvol.capture" code:code userInfo:@{
        NSLocalizedDescriptionKey: @"The microphone format changed or capture could not start."
    }];
}

NSError *PraatvolInstallMicrophoneTap(
    AVAudioInputNode *input, AVAudioFormat *expectedFormat, AVAudioNodeTapBlock callback) {
    @try {
        AVAudioFormat *hardware = [input inputFormatForBus:0];
        AVAudioFormat *output = [input outputFormatForBus:0];
        if (!isfinite(hardware.sampleRate) || hardware.sampleRate <= 0 || hardware.channelCount == 0) {
            return CaptureFailure(1);
        }
        if (![hardware isEqual:output] || ![output isEqual:expectedFormat]) {
            return CaptureFailure(2);
        }
        // Use the node's format, rather than asking AVFoundation to set a cached format.
        [input installTapOnBus:0 bufferSize:4096 format:nil block:callback];
        return nil;
    } @catch (NSException *exception) {
        // Do not expose exception descriptions: only a fixed, content-free error crosses into Swift.
        return CaptureFailure(3);
    }
}

NSError *PraatvolStartMicrophoneEngine(AVAudioEngine *engine) {
    @try {
        [engine prepare];
        NSError *error = nil;
        if ([engine startAndReturnError:&error]) {
            return nil;
        }
        return error ?: CaptureFailure(4);
    } @catch (NSException *exception) {
        return CaptureFailure(5);
    }
}
