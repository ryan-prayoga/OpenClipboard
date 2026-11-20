#import <AppKit/AppKit.h>

extern const CGFloat OCToolbarHeight;

NSView *OCToolbarSurface(NSRect frame, NSView *parent);
NSPopUpButton *OCGlassPopup(NSRect frame, NSView *parent);
NSButton *OCToolbarIcon(NSRect frame, NSView *parent, NSString *symbol, NSString *label, id target, SEL action);
