#import "VirtualDisplayBridge.h"

// Private CoreGraphics ABI; keep it isolated so an OS change cannot break Remote mode.
@interface NSObject (PBDisplayABI)
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
- (void)setName:(NSString *)name;
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setMaxPixelsWide:(unsigned int)value;
- (void)setMaxPixelsHigh:(unsigned int)value;
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setSizeInMillimeters:(CGSize)value;
- (void)setRedPrimary:(CGPoint)value;
- (void)setGreenPrimary:(CGPoint)value;
- (void)setBluePrimary:(CGPoint)value;
- (void)setWhitePoint:(CGPoint)value;
- (void)setModes:(NSArray *)modes;
- (void)setHiDPI:(unsigned int)value;
@end

@implementation PBVirtualDisplay {
    id _display;
}
+ (instancetype)makeWithError:(NSError **)error {
    return [[self alloc] initWithError:error];
}
+ (BOOL)isAvailable {
    for (NSString *name in @[@"CGVirtualDisplay", @"CGVirtualDisplayDescriptor",
                             @"CGVirtualDisplayMode", @"CGVirtualDisplaySettings"]) {
        if (!NSClassFromString(name)) return NO;
    }
    return YES;
}
- (instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        if (![PBVirtualDisplay isAvailable]) {
            @throw [NSException exceptionWithName:@"Unavailable" reason:@"API layar virtual tidak tersedia." userInfo:nil];
        }
        id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        [descriptor setName:@"PadBridge iPad"];
        [descriptor setQueue:dispatch_get_main_queue()];
        [descriptor setMaxPixelsWide:1600];
        [descriptor setMaxPixelsHigh:1200];
        [descriptor setSizeInMillimeters:CGSizeMake(240, 180)];
        [descriptor setVendorID:0x5062];
        [descriptor setProductID:1];
        [descriptor setSerialNum:1];
        [descriptor setRedPrimary:CGPointMake(0.64, 0.33)];
        [descriptor setGreenPrimary:CGPointMake(0.30, 0.60)];
        [descriptor setBluePrimary:CGPointMake(0.15, 0.06)];
        [descriptor setWhitePoint:CGPointMake(0.3127, 0.3290)];
        _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1600 height:1200 refreshRate:60];
        id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        [settings setHiDPI:0];
        [settings setModes:@[mode]];
        if (!_display || ![_display applySettings:settings] || ![_display displayID]) {
            @throw [NSException exceptionWithName:@"CreationFailed" reason:@"macOS menolak pembuatan layar virtual." userInfo:nil];
        }
        // macOS may choose 800×600 even when the advertised mode is 1600×1200.
        CFArrayRef modes = CGDisplayCopyAllDisplayModes([_display displayID], NULL);
        BOOL configured = NO;
        if (modes) {
            for (CFIndex index = 0; index < CFArrayGetCount(modes); index++) {
                CGDisplayModeRef candidate = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index);
                if (CGDisplayModeGetWidth(candidate) == 1600 && CGDisplayModeGetHeight(candidate) == 1200) {
                    configured = CGDisplaySetDisplayMode([_display displayID], candidate, NULL) == kCGErrorSuccess;
                    break;
                }
            }
            CFRelease(modes);
        }
        if (!configured) {
            @throw [NSException exceptionWithName:@"ModeFailed" reason:@"Mode layar virtual 1600×1200 tidak bisa dipilih." userInfo:nil];
        }
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"PadBridge.VirtualDisplay" code:1
                                          userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Layar virtual gagal."}];
        return nil;
    }
    return self;
}
- (CGDirectDisplayID)displayID { return [_display displayID]; }
@end
