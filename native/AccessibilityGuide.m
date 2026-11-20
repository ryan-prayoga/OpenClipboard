#import "AccessibilityGuide.h"
#import "Native.h"
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const SettingsBundleID = @"com.apple.systempreferences";
static NSString *const AccessibilityURL = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

BOOL OCAccessibilityReady(void) {
    return AXIsProcessTrusted();
}

static NSRect SystemSettingsFrame(void) {
    pid_t pid = [NSRunningApplication runningApplicationsWithBundleIdentifier:SettingsBundleID].firstObject.processIdentifier;
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!pid || !primary) return NSZeroRect;

    // Window Server coordinates provide placement even before the app has Accessibility access.
    NSArray<NSDictionary *> *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != pid ||
            [window[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
        NSDictionary *geometry = window[(__bridge NSString *)kCGWindowBounds];
        CGRect bounds;
        if (!geometry || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)geometry, &bounds) ||
            CGRectGetWidth(bounds) < 300 || CGRectGetHeight(bounds) < 250) continue;
        return NSMakeRect(CGRectGetMinX(bounds), NSMaxY(primary.frame) - CGRectGetMaxY(bounds),
                          CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    }
    return NSZeroRect;
}

static NSPoint GuideOrigin(NSRect room, NSRect settings, NSSize size) {
    CGFloat top = NSMaxY(room) - size.height;
    if (NSIsEmptyRect(settings)) return NSMakePoint(NSMinX(room), top);

    const CGFloat gap = 12;
    CGFloat alongside = MAX(NSMinY(room), MIN(top, NSMaxY(settings) - size.height));
    CGFloat right = NSMaxX(settings) + gap;
    if (right + size.width <= NSMaxX(room)) return NSMakePoint(right, alongside);
    CGFloat left = NSMinX(settings) - gap - size.width;
    if (left >= NSMinX(room)) return NSMakePoint(left, alongside);

    CGFloat centered = MAX(NSMinX(room), MIN(NSMaxX(room) - size.width, NSMidX(settings) - size.width / 2));
    CGFloat above = NSMaxY(settings) + gap;
    if (above <= top) return NSMakePoint(centered, above);
    CGFloat below = NSMinY(settings) - gap - size.height;
    if (below >= NSMinY(room)) return NSMakePoint(centered, below);

    // Keep the guide over the sidebar when Settings fills the display.
    return NSMakePoint(NSMinX(room), top);
}

static NSImage *GuideSymbol(NSString *name, CGFloat size) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightSemibold]];
}

@interface OCAppDragIcon : NSView <NSDraggingSource>
@property(nonatomic, readonly) BOOL canDrag;
@property(nonatomic, readonly, getter=isInteracting) BOOL interacting;
- (instancetype)initWithFrame:(NSRect)frame bundleURL:(NSURL *)bundleURL;
- (void)playHint;
- (void)stopHint;
@end

@implementation OCAppDragIcon {
    NSURL *_bundleURL;
    NSImage *_dragImage;
    NSImageView *_artwork;
    NSEvent *_press;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(NSRect)frame bundleURL:(NSURL *)bundleURL {
    if (!(self = [super initWithFrame:frame])) return nil;
    _bundleURL = bundleURL;
    _dragImage = bundleURL ? [NSWorkspace.sharedWorkspace iconForFile:bundleURL.path] : NSApp.applicationIconImage;

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    BOOL hasBundleIcon = info[@"CFBundleIconFile"] != nil || info[@"CFBundleIconName"] != nil;
    _artwork = [NSImageView imageViewWithImage:hasBundleIcon ? _dragImage : GuideSymbol(@"clipboard.fill", 28)];
    _artwork.frame = NSInsetRect(self.bounds, 10, 10);
    _artwork.contentTintColor = NSColor.controlAccentColor;
    _artwork.wantsLayer = YES;
    [_artwork setAccessibilityElement:NO];
    [self addSubview:_artwork];

    if (bundleURL) {
        NSImageView *arrow = [NSImageView imageViewWithImage:GuideSymbol(@"arrow.up.right.circle.fill", 17)];
        arrow.frame = NSMakeRect(NSWidth(frame) - 21, 4, 17, 17);
        arrow.contentTintColor = NSColor.controlAccentColor;
        [arrow setAccessibilityElement:NO];
        [self addSubview:arrow];
        self.toolTip = @"Seret OpenClipboard.app ke daftar izin";
    }
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityImageRole];
    [self setAccessibilityLabel:@"Ikon OpenClipboard"];
    [self setAccessibilityHelp:self.toolTip];
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:17 yRadius:17];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.09] setFill];
    [tile fill];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.21] setStroke];
    [tile stroke];
}

- (BOOL)canDrag { return _bundleURL != nil; }
- (BOOL)isInteracting { return _press != nil || _dragging; }
- (NSView *)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return _bundleURL != nil; }
- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent *)event { return _bundleURL != nil; }
- (BOOL)mouseDownCanMoveWindow { return _bundleURL == nil; }

- (void)resetCursorRects {
    if (_bundleURL) [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}

- (void)mouseDown:(NSEvent *)event {
    if (!_bundleURL) return;
    [NSApp preventWindowOrdering];
    [self stopHint];
    _press = event;
}

- (void)mouseUp:(NSEvent *)event {
    _press = nil;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_press) return;
    NSPoint press = _press.locationInWindow;
    NSPoint point = event.locationInWindow;
    if (hypot(point.x - press.x, point.y - press.y) < 4) return;

    // NSURL writes public.file-url to the drag pasteboard, including paths with spaces.
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:_bundleURL];
    NSPoint origin = [self convertPoint:point fromView:nil];
    [item setDraggingFrame:NSMakeRect(origin.x - 22, origin.y - 22, 44, 44) contents:_dragImage];
    _press = nil;
    _dragging = YES;
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextOutsideApplication ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)point {
    // Let Settings receive the drop even if the guide overlaps part of the list.
    self.window.ignoresMouseEvents = YES;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    self.window.ignoresMouseEvents = NO;
    _dragging = NO;
}

- (void)playHint {
    if (!_bundleURL || self.isInteracting || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @1;
    pulse.toValue = @1.08;
    pulse.duration = 0.45;
    pulse.autoreverses = YES;
    pulse.repeatCount = 2;
    pulse.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.77 :0 :0.175 :1];
    [_artwork.layer addAnimation:pulse forKey:@"dragHint"];
}

- (void)stopHint {
    [_artwork.layer removeAnimationForKey:@"dragHint"];
}
@end

@interface OCAccessibilityPanel : NSPanel
@end

@implementation OCAccessibilityPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface OCAccessibilityGuide () <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSView *prompt;
@property(nonatomic, strong) NSView *success;
@property(nonatomic, strong) OCAppDragIcon *dragIcon;
@property(nonatomic, strong) NSTextField *instructions;
@property(nonatomic, strong) NSTimer *permissionTimer;
@property(nonatomic, strong) NSTimer *dismissTimer;
@property(nonatomic) NSUInteger placementAttempts;
@end

@implementation OCAccessibilityGuide
- (void)buildPanel {
    NSRect bounds = NSMakeRect(0, 0, 356, 146);
    self.panel = [[OCAccessibilityPanel alloc] initWithContentRect:bounds
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = @"Panduan Accessibility";
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.movableByWindowBackground = YES;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
        NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:bounds];
    glass.material = NSVisualEffectMaterialPopover;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = 24;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    self.panel.contentView = glass;

    self.prompt = [[NSView alloc] initWithFrame:bounds];
    [glass addSubview:self.prompt];

    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    if (!bundleURL.isFileURL || [bundleURL.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) {
        bundleURL = nil;
    }
    self.dragIcon = [[OCAppDragIcon alloc] initWithFrame:NSMakeRect(19, 43, 66, 66) bundleURL:bundleURL];
    [self.prompt addSubview:self.dragIcon];

    NSTextField *title = OCLabel(@"Aktifkan Accessibility", 17, NSFontWeightSemibold);
    title.frame = NSMakeRect(100, 104, 221, 23);
    [self.prompt addSubview:title];

    self.instructions = [NSTextField wrappingLabelWithString:@""];
    self.instructions.font = [NSFont systemFontOfSize:13];
    self.instructions.textColor = NSColor.secondaryLabelColor;
    self.instructions.frame = NSMakeRect(100, 49, 230, 49);
    [self.prompt addSubview:self.instructions];

    NSButton *open = [NSButton buttonWithTitle:@"Buka Pengaturan Sistem" image:GuideSymbol(@"arrow.up.right", 10)
                                        target:self action:@selector(openSettings:)];
    open.frame = NSMakeRect(94, 17, 165, 24);
    open.imagePosition = NSImageTrailing;
    open.alignment = NSTextAlignmentLeft;
    open.bezelStyle = NSBezelStyleInline;
    [self.prompt addSubview:open];

    NSButton *close = [NSButton buttonWithImage:GuideSymbol(@"xmark", 11)
                                        target:self action:@selector(closeGuide:)];
    close.frame = NSMakeRect(318, 106, 25, 25);
    close.bordered = NO;
    close.contentTintColor = NSColor.secondaryLabelColor;
    close.keyEquivalent = @"\e";
    close.toolTip = @"Tutup panduan";
    [close setAccessibilityLabel:close.toolTip];
    [self.prompt addSubview:close];

    self.success = [[NSView alloc] initWithFrame:bounds];
    self.success.wantsLayer = YES;
    self.success.hidden = YES;
    [glass addSubview:self.success];

    NSImageView *check = [NSImageView imageViewWithImage:GuideSymbol(@"checkmark.circle.fill", 39)];
    check.frame = NSMakeRect(29, 51, 47, 47);
    check.contentTintColor = NSColor.systemGreenColor;
    [check setAccessibilityElement:NO];
    [self.success addSubview:check];

    NSTextField *approved = OCLabel(@"Accessibility aktif", 17, NSFontWeightSemibold);
    approved.frame = NSMakeRect(100, 77, 236, 23);
    [self.success addSubview:approved];

    NSTextField *caption = OCLabel(@"OpenClipboard sudah diberi akses.", 13, NSFontWeightRegular);
    caption.textColor = NSColor.secondaryLabelColor;
    caption.frame = NSMakeRect(100, 50, 236, 20);
    [self.success addSubview:caption];
}

- (void)placeOnScreen:(NSScreen *)preferred nearSettings:(NSRect)settings {
    NSScreen *screen = preferred ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat largestOverlap = 0;
    for (NSScreen *candidate in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(settings, candidate.frame);
        CGFloat area = NSWidth(overlap) * NSHeight(overlap);
        if (area <= largestOverlap) continue;
        largestOverlap = area;
        screen = candidate;
    }
    if (!screen) return;
    NSRect room = NSInsetRect(screen.visibleFrame, 12, 12);
    [self.panel setFrameOrigin:GuideOrigin(room, settings, self.panel.frame.size)];
}

- (void)showFromScreen:(NSScreen *)screen {
    if (OCAccessibilityReady()) {
        if (self.permissionTimer) [self showSuccess];
        return;
    }
    if (!self.panel) [self buildPanel];
    if (self.dismissTimer) [self closeGuide:nil];

    self.prompt.hidden = NO;
    self.success.hidden = YES;
    [self openSettings:nil];
    NSRect settings = SystemSettingsFrame();
    [self placeOnScreen:screen nearSettings:settings];
    self.placementAttempts = NSIsEmptyRect(settings) ? 8 : 0;
    [self.panel orderFrontRegardless];
    [self.dragIcon playHint];

    if (self.permissionTimer) return;
    __weak OCAccessibilityGuide *weakSelf = self;
    self.permissionTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf checkPermission];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.permissionTimer forMode:NSRunLoopCommonModes];
}

- (void)checkPermission {
    if (OCAccessibilityReady()) {
        [self showSuccess];
        return;
    }
    if (!self.placementAttempts || self.dragIcon.isInteracting) return;
    self.placementAttempts--;
    NSRect settings = SystemSettingsFrame();
    if (NSIsEmptyRect(settings)) return;
    self.placementAttempts = 0;
    [self placeOnScreen:self.panel.screen nearSettings:settings];
}

- (void)showSuccess {
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
    [self.dragIcon stopHint];
    self.prompt.hidden = YES;
    self.success.hidden = NO;

    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.35;
    fade.duration = 0.2;
    fade.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
    [self.success.layer addAnimation:fade forKey:@"confirmPermission"];
    if (!reduceMotion) {
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        scale.fromValue = @0.96;
        scale.duration = fade.duration;
        scale.timingFunction = fade.timingFunction;
        [self.success.layer addAnimation:scale forKey:@"settle"];
    }

    NSAccessibilityPostNotificationWithUserInfo(self.success, NSAccessibilityAnnouncementRequestedNotification, @{
        NSAccessibilityAnnouncementKey: @"Accessibility aktif",
        NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
    });
    if (self.permissionChanged) self.permissionChanged();

    __weak OCAccessibilityGuide *weakSelf = self;
    self.dismissTimer = [NSTimer timerWithTimeInterval:1.0 repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf closeGuide:nil];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.dismissTimer forMode:NSRunLoopCommonModes];
}

- (void)openSettings:(id)sender {
    if ([NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:AccessibilityURL]]) {
        self.instructions.stringValue = self.dragIcon.canDrag
            ? @"Seret ikon ke daftar izin, lalu nyalakan OpenClipboard. Jika perlu, klik tombol +."
            : @"Klik tombol +, pilih OpenClipboard.app, lalu nyalakan sakelarnya.";
    } else {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]];
        self.instructions.stringValue = @"Pilih Device Control and Data Access di Privasi & Keamanan.";
    }
    if (sender) self.placementAttempts = 8;
}

- (void)closeGuide:(id)sender {
    [self.panel close];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    self.placementAttempts = 0;
    [self.dragIcon stopHint];
}
@end
