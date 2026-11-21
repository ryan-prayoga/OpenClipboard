#import "Toolbar.h"
#import "Native.h"

@implementation OCEditableTextField
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder == self.currentEditor && OCPerformEditShortcut(event, self.currentEditor)) return YES;
    return [super performKeyEquivalent:event];
}
@end

const CGFloat OCToolbarHeight = 36;
static const CGFloat OCToolbarRadius = 11;

@interface OCToolbarCapsule : NSView
@end

@implementation OCToolbarCapsule
- (void)drawRect:(NSRect)dirtyRect {
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSRect frame = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:OCToolbarRadius yRadius:OCToolbarRadius];
    NSColor *fill = [NSColor.whiteColor colorWithAlphaComponent:dark ? 0.085 : 0.40];
    BOOL contrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    NSColor *outline = [(dark ? NSColor.whiteColor : NSColor.blackColor)
        colorWithAlphaComponent:contrast ? 0.6 : dark ? 0.19 : 0.15];
    [fill setFill];
    [shape fill];
    [outline setStroke];
    shape.lineWidth = 1;
    [shape stroke];
}
@end

NSView *OCToolbarSurface(NSRect frame, NSView *parent) {
    OCToolbarCapsule *surface = [[OCToolbarCapsule alloc] initWithFrame:frame];
    [parent addSubview:surface];
    return surface;
}

NSPopUpButton *OCGlassPopup(NSRect frame, NSView *parent) {
    NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:frame];
    glass.cornerRadius = OCToolbarRadius;
    glass.effectIsInteractive = YES;
    NSView *content = [[NSView alloc] initWithFrame:glass.bounds];
    glass.contentView = content;
    [parent addSubview:glass];

    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSInsetRect(content.bounds,10,0) pullsDown:NO];
    button.controlSize = NSControlSizeLarge;
    button.bordered = NO;
    [content addSubview:button];
    return button;
}

NSButton *OCToolbarIcon(NSRect frame, NSView *parent, NSString *symbol, NSString *label, id target, SEL action) {
    NSView *surface = OCToolbarSurface(frame, parent);
    NSImage *icon = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightSemibold];
    NSButton *button = [NSButton buttonWithImage:[icon imageWithSymbolConfiguration:config] target:target action:action];
    button.frame = surface.bounds;
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.contentTintColor = NSColor.labelColor;
    button.toolTip = label;
    [button setAccessibilityLabel:label];
    [surface addSubview:button];
    return button;
}
