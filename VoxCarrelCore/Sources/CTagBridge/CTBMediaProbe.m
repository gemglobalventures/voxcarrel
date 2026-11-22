#import "CTagBridge.h"
#import <AVFoundation/AVFoundation.h>

@implementation CTBMediaProbe

+ (double)preciseDurationAtPath:(NSString *)path {
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                                options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        // Reading the property loads it, and waits until it is loaded.
        CMTime duration = asset.duration;
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"duration" error:&error] != AVKeyValueStatusLoaded) return -1;
        if (!CMTIME_IS_NUMERIC(duration)) return -1;
        double seconds = CMTimeGetSeconds(duration);
        return isfinite(seconds) ? seconds : -1;
    } @catch (NSException *exception) {
        return -1;
    }
}

@end
