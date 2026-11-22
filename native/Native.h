#import <AppKit/AppKit.h>
#import "Bridge.h"

@class OCPicker;
@class OCRecorder;

static inline NSTextField *OCLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

// Accessory apps can lack a working main menu while a panel is key, so text editing
// shortcuts are routed to the first responder directly.
static inline BOOL OCPerformEditShortcut(NSEvent *event, NSResponder *target) {
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand |
        NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    SEL action = NULL;
    if (flags == NSEventModifierFlagCommand) {
        if ([key isEqualToString:@"x"]) action = @selector(cut:);
        else if ([key isEqualToString:@"c"]) action = @selector(copy:);
        else if ([key isEqualToString:@"v"]) action = @selector(paste:);
        else if ([key isEqualToString:@"a"]) action = @selector(selectAll:);
        else if ([key isEqualToString:@"z"]) action = NSSelectorFromString(@"undo:");
    } else if (flags == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"z"]) {
        action = NSSelectorFromString(@"redo:");
    }
    if (!action || !target || ![target respondsToSelector:action]) return NO;
    return [NSApp sendAction:action to:target from:nil];
}

extern NSString *const OCLiquidGlassPreference;

BOOL OCSend(NSDictionary *command);
void OCConfirmClearHistory(NSWindow *window, BOOL all, dispatch_block_t confirm);
BOOL OCGetCaret(pid_t pid, NSRect *result);
NSArray<NSPasteboardItem *> *OCPasteboardItems(NSArray<NSDictionary *> *parts);
BOOL OCWriteClipboard(NSArray<NSDictionary *> *parts, BOOL sensitive, NSInteger *version);
BOOL OCPostPaste(pid_t destination, NSInteger version);

@interface OCRecorder : NSObject
@property(nonatomic, copy, readonly) NSString *status;
@property(nonatomic, copy, readonly) NSString *policy;
@property(nonatomic, copy) void (^statusChanged)(void);
- (void)startTimer;
- (void)retry;
- (void)resetBaseline;
- (void)storageFull:(BOOL)full;
@end

@interface OCPicker : NSObject
@property(nonatomic, copy) dispatch_block_t openSettings;
@property(nonatomic, copy) dispatch_block_t openAccessibilityGuide;
@property(nonatomic, copy) dispatch_block_t quit;
@property(nonatomic, copy) NSString *recordingStatus;
@property(nonatomic, copy) NSString *shortcutLabel;
- (void)showAtBottom:(BOOL)bottom started:(NSTimeInterval)started;
- (void)dismissRestoringFocus:(BOOL)restore;
- (void)receiveEvent:(NSDictionary *)event;
- (void)receivePayload:(NSArray<NSDictionary *> *)parts ticket:(uint64_t)ticket
                    id:(int64_t)clip sensitive:(BOOL)sensitive;
- (void)receiveThumbnail:(NSData *)image ticket:(uint64_t)ticket id:(int64_t)clip;
@property(nonatomic, copy) dispatch_block_t didWriteClipboard;
@end
