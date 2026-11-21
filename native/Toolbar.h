#import <AppKit/AppKit.h>

extern const CGFloat OCToolbarHeight;

// Text field that handles ⌘X/C/V/A/Z itself, so editing works in sheets and panels
// of an app without a main menu.
@interface OCEditableTextField : NSTextField
@end

NSView *OCToolbarSurface(NSRect frame, NSView *parent);
NSPopUpButton *OCGlassPopup(NSRect frame, NSView *parent);
NSButton *OCToolbarIcon(NSRect frame, NSView *parent, NSString *symbol, NSString *label, id target, SEL action);
