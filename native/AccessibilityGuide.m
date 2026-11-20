#import "AccessibilityGuide.h"
#import "Native.h"
#import "OpenClipboardPermissions-Swift.h"
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const AccessibilityURL = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

BOOL OCAccessibilityReady(void) {
    return AXIsProcessTrusted();
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
@property(nonatomic) NSRect settingsFrame;
@end

@implementation OCAccessibilityGuide
- (void)buildPanel {
    NSRect bounds = NSMakeRect(0, 0, 362, 198);
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

    NSTextField *title = OCLabel(@"Aktifkan Accessibility", 20, NSFontWeightSemibold);
    title.frame = NSMakeRect(18, 151, 290, 28);
    [self.prompt addSubview:title];

    NSTextField *purpose = OCLabel(@"Untuk menempelkan klip langsung ke aplikasi lain.", 12, NSFontWeightRegular);
    purpose.textColor = NSColor.secondaryLabelColor;
    purpose.frame = NSMakeRect(18, 130, 326, 18);
    [self.prompt addSubview:purpose];

    NSButton *close = [NSButton buttonWithImage:GuideSymbol(@"xmark.circle.fill", 17)
                                        target:self action:@selector(closeGuide:)];
    close.frame = NSMakeRect(312, 148, 34, 34);
    close.bordered = NO;
    close.contentTintColor = NSColor.secondaryLabelColor;
    close.keyEquivalent = @"\e";
    close.toolTip = @"Tutup panduan";
    [close setAccessibilityLabel:close.toolTip];
    [self.prompt addSubview:close];

    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    if (!bundleURL.isFileURL || [bundleURL.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) {
        bundleURL = nil;
    }
    self.dragIcon = [[OCAppDragIcon alloc] initWithFrame:NSMakeRect(18, 62, 326, 58) bundleURL:bundleURL];
    [self.prompt addSubview:self.dragIcon];

    self.instructions = [NSTextField wrappingLabelWithString:@""];
    self.instructions.font = [NSFont systemFontOfSize:11];
    self.instructions.textColor = NSColor.secondaryLabelColor;
    self.instructions.frame = NSMakeRect(19, 13, 192, 34);
    [self updateInstructionsForSettingsLink:YES];
    [self.prompt addSubview:self.instructions];

    NSButton *open = [NSButton buttonWithTitle:@"Buka Pengaturan" image:GuideSymbol(@"arrow.up.right", 9)
                                        target:self action:@selector(openSettings:)];
    open.frame = NSMakeRect(213, 15, 132, 30);
    open.imagePosition = NSImageTrailing;
    open.bezelStyle = NSBezelStyleRounded;
    open.controlSize = NSControlSizeSmall;
    open.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [open setAccessibilityLabel:@"Buka Pengaturan Sistem"];
    [self.prompt addSubview:open];

    self.success = [[NSView alloc] initWithFrame:bounds];
    self.success.wantsLayer = YES;
    self.success.hidden = YES;
    [glass addSubview:self.success];

    NSImageView *check = [NSImageView imageViewWithImage:GuideSymbol(@"checkmark.circle.fill", 42)];
    check.frame = NSMakeRect(158, 102, 46, 46);
    check.contentTintColor = NSColor.systemGreenColor;
    [check setAccessibilityElement:NO];
    [self.success addSubview:check];

    NSTextField *approved = OCLabel(@"Accessibility aktif", 21, NSFontWeightSemibold);
    approved.frame = NSMakeRect(18, 65, 326, 28);
    approved.alignment = NSTextAlignmentCenter;
    [self.success addSubview:approved];

    NSTextField *caption = OCLabel(@"Klip bisa langsung ditempel ke aplikasi lain.", 13, NSFontWeightRegular);
    caption.textColor = NSColor.secondaryLabelColor;
    caption.frame = NSMakeRect(18, 44, 326, 19);
    caption.alignment = NSTextAlignmentCenter;
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
    self.settingsFrame = [OCSystemSettingsWindowTracker windowFrame];
    [self placeOnScreen:screen nearSettings:self.settingsFrame];
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
    if (self.dragIcon.isInteracting) return;
    NSRect settings = [OCSystemSettingsWindowTracker windowFrame];
    if (NSEqualRects(settings, self.settingsFrame)) return;
    self.settingsFrame = settings;
    if (!NSIsEmptyRect(settings)) [self placeOnScreen:self.panel.screen nearSettings:settings];
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

- (void)updateInstructionsForSettingsLink:(BOOL)opened {
    if (!opened) {
        self.instructions.stringValue = @"Buka Accessibility atau Device\nControl and Data Access.";
        return;
    }
    self.instructions.stringValue = self.dragIcon.canDrag
        ? @"Atau tambahkan lewat tombol +.\nLalu nyalakan sakelarnya."
        : @"Klik +, pilih OpenClipboard.app,\nlalu nyalakan sakelarnya.";
}

- (void)openSettings:(id)sender {
    BOOL opened = [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:AccessibilityURL]];
    if (!opened) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]];
    }
    [self updateInstructionsForSettingsLink:opened];
}

- (void)closeGuide:(id)sender {
    [self.panel close];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    [self.dragIcon stopHint];
}
@end
