#import <AppKit/AppKit.h>

BOOL OCAccessibilityReady(void);

@interface OCAccessibilityGuide : NSObject
@property(nonatomic, copy) dispatch_block_t permissionChanged;
- (void)showFromScreen:(NSScreen *)screen;
@end
