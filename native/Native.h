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

BOOL OCSend(NSDictionary *command);
void OCConfirmClearHistory(NSWindow *window, BOOL all, dispatch_block_t confirm);
BOOL OCGetCaret(pid_t pid, NSRect *result);
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
