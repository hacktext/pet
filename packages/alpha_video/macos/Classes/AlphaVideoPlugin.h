#import <FlutterMacOS/FlutterMacOS.h>

// macOS side of the aipet.alpha_video/methods channel; same protocol as the
// Windows plugin (abiVersion / open / play / pause / currentFrame / dispose /
// prepare).
@interface AlphaVideoPlugin : NSObject <FlutterPlugin>
@end
