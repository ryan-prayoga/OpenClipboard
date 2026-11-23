#import "Native.h"
#import "AccessibilityGuide.h"
#import "Results.h"
#import "Tabs.h"
#import "Toolbar.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat CompactPanelInset = 14;
static const CGFloat BottomPanelInset = 20;
static const CGFloat BottomScreenInset = 17;
static const CGFloat ResultsTopGap = 10;
static const CGFloat FooterHeight = 25;
static const NSTimeInterval FeedbackFadeDuration = 0.15;
static const CGFloat BottomPanelEntranceDistance = 12;
static const CGFloat BottomPanelExitDistance = 8;
static const NSTimeInterval BottomPanelEntranceDuration = 0.25;
static const NSTimeInterval BottomPanelExitDuration = 0.15;

static void AnimatePanel(NSPanel *panel, NSRect frame, CGFloat opacity,
                         NSTimeInterval duration, void (^completion)(void)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22 :1 :0.36 :1];
        [panel.animator setFrame:frame display:YES];
        panel.animator.alphaValue = opacity;
    } completionHandler:completion];
}

static void FadeInFeedback(NSView *view) {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    view.wantsLayer = YES;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.35;
    fade.toValue = @1;
    fade.duration = FeedbackFadeDuration;
    fade.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
    [view.layer addAnimation:fade forKey:@"appear"];
}

static CGFloat PanelChromeHeight(BOOL bottom) {
    return (bottom ? BottomPanelInset+15 : CompactPanelInset+11) + OCToolbarHeight + ResultsTopGap;
}
static const CGFloat SearchFieldInset = 33;
static const CGFloat SearchTextInset = 2;

static CGFloat Clamp(CGFloat value, CGFloat low, CGFloat high) {
    return MAX(low, MIN(value, high));
}

static double DayOf(NSDictionary *row) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[row[@"last_used"] doubleValue] / 1000.0];
    return [NSCalendar.currentCalendar startOfDayForDate:date].timeIntervalSince1970;
}

// Index of the first clip of the next or previous day. Rows are sorted by last use.
static NSInteger DayGroupIndex(NSArray<NSDictionary *> *rows, NSInteger index, BOOL forward) {
    NSInteger count = (NSInteger)rows.count;
    if (!count) return -1;
    index = Clamp(index, 0, count - 1);
    double day = DayOf(rows[(NSUInteger)index]);
    if (forward) {
        for (NSInteger i = index + 1; i < count; i++) if (DayOf(rows[(NSUInteger)i]) != day) return i;
        return count - 1;
    }
    NSInteger start = index;
    while (start > 0 && DayOf(rows[(NSUInteger)start - 1]) == day) start--;
    if (start < index) return start;
    if (start == 0) return 0;
    double previous = DayOf(rows[(NSUInteger)start - 1]);
    NSInteger first = start - 1;
    while (first > 0 && DayOf(rows[(NSUInteger)first - 1]) == previous) first--;
    return first;
}

static NSScreen *ScreenAt(NSPoint point) {
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(point, screen.frame)) return screen;
    }
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

@interface OCPanel : NSPanel
@property(nonatomic, strong) NSView *surfaceContent;
@end

@implementation OCPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ([super performKeyEquivalent:event]) return YES;
    return OCPerformEditShortcut(event, self.firstResponder);
}
@end

@interface OCHorizontalScrollView : NSScrollView
@end

@implementation OCHorizontalScrollView
- (void)scrollWheel:(NSEvent *)event {
    if (event.hasPreciseScrollingDeltas || event.scrollingDeltaX != 0 || event.scrollingDeltaY == 0) {
        [super scrollWheel:event];
        return;
    }

    NSClipView *clip = self.contentView;
    NSRect bounds = clip.bounds;
    bounds.origin.x -= event.scrollingDeltaY * self.horizontalLineScroll;
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [self reflectScrolledClipView:clip];
}
@end

static NSImage *GlassMask(NSSize size, CGFloat radius) {
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect destination) {
        [NSColor.blackColor setFill];
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:destination xRadius:radius yRadius:radius];
        [shape fill];
        return YES;
    }];
}

static NSPanel *MakePanel(NSRect rect, NSString *title) {
    OCPanel *panel = [[OCPanel alloc] initWithContentRect:rect
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
          backing:NSBackingStoreBuffered defer:NO];
    panel.title = title;
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.opaque = NO;
    panel.floatingPanel = YES;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.level = NSFloatingWindowLevel;
    panel.hasShadow = YES;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
    CGFloat radius = NSWidth(rect) > 600 ? 29 : 23;
    BOOL reduce = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    if (reduce) {
        NSView *background = [[NSView alloc] initWithFrame:NSMakeRect(0,0,NSWidth(rect),NSHeight(rect))];
        background.wantsLayer = YES;
        background.layer.cornerRadius = radius;
        background.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
        background.layer.masksToBounds = YES;
        panel.contentView = background;
        panel.surfaceContent = background;
    } else {
        NSRect bounds = NSMakeRect(0,0,NSWidth(rect),NSHeight(rect));
        NSView *root = [[NSView alloc] initWithFrame:bounds];

        NSView *content = [[NSView alloc] initWithFrame:bounds];
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSView *surface = content;
        if (@available(macOS 26.0, *)) {
            if ([NSUserDefaults.standardUserDefaults boolForKey:OCLiquidGlassPreference]) {
                NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:bounds];
                glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                glass.style = NSGlassEffectViewStyleClear;
                glass.cornerRadius = radius;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
                if (@available(macOS 27.0, *)) {
                    glass.effectIsInteractive = YES;
                }
#endif
                glass.contentView = content;
                surface = glass;
            }
        }

        // Inset the backdrop behind clear glass, which draws its own edges.
        CGFloat inset = surface == content ? 0 : 2;
        NSRect materialFrame = NSInsetRect(bounds,inset,inset);
        NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] initWithFrame:materialFrame];
        backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        backdrop.material = NSVisualEffectMaterialPopover;
        backdrop.state = NSVisualEffectStateActive;
        backdrop.maskImage = GlassMask(materialFrame.size, radius-inset);
        [root addSubview:backdrop];
        [root addSubview:surface];
        panel.contentView = root;
        panel.surfaceContent = content;
    }
    return panel;
}

static NSView *PanelContent(NSPanel *panel) {
    return ((OCPanel *)panel).surfaceContent;
}

static void SetCollectionColorDot(NSMenuItem *item, NSString *key, int64_t identifier) {
    NSColor *color = OCTabColor(key,identifier);
    item.image = [NSImage imageWithSize:NSMakeSize(10,10) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [color setFill];
        [[NSBezierPath bezierPathWithOvalInRect:rect] fill];
        return YES;
    }];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
    if (@available(macOS 27.0, *)) {
        item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
    }
#endif
}

static void ReportMetric(const char *metric, BOOL bottom, NSTimeInterval started) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        enabled = [defaults stringForKey:@"OCTestDataDirectory"].length && [defaults boolForKey:@"OCTestMetrics"];
    });
    if (enabled && started > 0) {
        fprintf(stderr, "OC_METRIC %s %s %.3f\n", metric, bottom ? "bottom" : "compact",
                (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    }
}

typedef NS_ENUM(NSInteger, OCPayloadMode) { OCIdle, OCPaste, OCPreview };

@interface OCToolbarSearchField : NSSearchField
@property(nonatomic, weak) NSButton *clearButton;
- (void)refreshClearButton;
@end

@implementation OCToolbarSearchField
- (void)setPlaceholderString:(NSString *)placeholderString {
    [super setPlaceholderString:placeholderString];
    [self setAccessibilityLabel:placeholderString];
}

- (void)setStringValue:(NSString *)stringValue {
    [super setStringValue:stringValue];
    [self refreshClearButton];
}

- (void)refreshClearButton {
    self.clearButton.hidden = self.stringValue.length == 0;
}
@end

@interface OCPicker () <NSSearchFieldDelegate, NSPopoverDelegate>
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSPanel *closingPanel;
@property(nonatomic) CGFloat basePanelHeight;
@property(nonatomic) CGFloat reservedFooterHeight;
@property(nonatomic) BOOL compactAboveAnchor;
@property(nonatomic) BOOL openingBottomPanel;
@property(nonatomic, strong) NSRunningApplication *origin;
@property(nonatomic, strong) NSSearchField *search;
@property(nonatomic, strong) NSButton *action;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSButton *undoButton;
@property(nonatomic) uint64_t undoTicket;
@property(nonatomic) BOOL undoPending;
@property(nonatomic) NSUInteger undoCount;
@property(nonatomic, strong) OCResults *results;
@property(nonatomic, strong) NSScrollView *scroll;
@property(nonatomic, strong) NSPopover *preview;
@property(nonatomic, strong) id keyMonitor;
@property(nonatomic, strong) id mouseMonitor;
@property(nonatomic, strong) id appMouseMonitor;
@property(nonatomic, strong) id resignObserver;
@property(nonatomic, strong) id workspaceObserver;
@property(nonatomic, strong) id scrollObserver;
@property(nonatomic, copy) NSArray<NSDictionary *> *collections;
@property(nonatomic, copy) NSArray<NSDictionary *> *clips;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *images;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *requested;
@property(nonatomic) BOOL bottom;
@property(nonatomic, strong) OCTabs *tabs;
@property(nonatomic) int64_t activeTab;
@property(nonatomic) BOOL revealTab;
@property(nonatomic) uint64_t catalogTicket;
@property(nonatomic) BOOL catalogPending;
@property(nonatomic) BOOL catalogFailed;
@property(nonatomic) NSTimeInterval searchStarted;
@property(nonatomic) uint64_t payloadTicket;
@property(nonatomic) uint64_t nextPayloadTicket;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *dragClips;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<NSPasteboardItem *> *> *dragItems;
@property(nonatomic) uint64_t panelToken;
@property(nonatomic) OCPayloadMode payloadMode;
@property(nonatomic, strong) NSPanel *toast;
@property(nonatomic) uint64_t toastTicket;
@property(nonatomic) uint64_t messageTicket;
@end

@implementation OCPicker
- (instancetype)init {
    self = [super init];
    if (self) {
        _collections = @[];
        _clips = @[];
        _images = [NSMutableDictionary dictionary];
        _requested = [NSMutableSet set];
    }
    return self;
}

- (void)setRecordingStatus:(NSString *)recordingStatus {
    _recordingStatus = [recordingStatus copy];
    if (self.panel.visible) [self setMessage:self.recordingStatus];
}

- (void)showAtBottom:(BOOL)bottom started:(NSTimeInterval)started {
    if (self.panel.visible) {
        [self dismissRestoringFocus:YES];
        return;
    }
    self.panelToken++;
    self.bottom = bottom;
    self.activeTab = 0;
    self.revealTab = NO;
    self.clips = @[];
    self.payloadMode = OCIdle;
    self.searchStarted = 0;
    self.catalogPending = NO;
    self.catalogFailed = NO;
    [self.images removeAllObjects];
    [self.requested removeAllObjects];

    self.origin = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSPoint pointer = NSEvent.mouseLocation;
    NSRect caret = NSZeroRect;
    BOOL hasCaret = !bottom && OCGetCaret(self.origin.processIdentifier,&caret);
    NSPoint anchor = hasCaret ? caret.origin : pointer;
    NSScreen *screen = ScreenAt(anchor);
    CGFloat screenInset = bottom ? BottomScreenInset : 12;
    NSRect room = NSInsetRect(screen.visibleFrame, screenInset, screenInset);
    CGFloat width = bottom ? NSWidth(room) : NSWidth(room) >= 520 ? 520 : MIN(432, NSWidth(room));
    self.reservedFooterHeight = self.recordingStatus.length || self.undoTicket ? FooterHeight : 0;
    self.openingBottomPanel = NO;
    CGFloat chrome = PanelChromeHeight(bottom) + self.reservedFooterHeight;
    CGFloat targetHeight = chrome + (bottom ? [OCResults cardViewportHeight]
        : [OCResults compactViewportHeightWithin:CGFLOAT_MAX]);
    CGFloat height = MIN(targetHeight, room.size.height);
    CGFloat x = NSMinX(room);
    CGFloat y = NSMinY(room);
    if (!bottom) {
        const CGFloat gap = 8;
        CGFloat textInset = hasCaret ? CompactPanelInset+SearchFieldInset+SearchTextInset : 0;
        x = Clamp(anchor.x-textInset,NSMinX(room),NSMaxX(room)-width);
        CGFloat below = anchor.y-gap-NSMinY(room);
        CGFloat upperEdge = (hasCaret ? NSMaxY(caret) : anchor.y)+gap;
        CGFloat above = NSMaxY(room)-upperEdge;
        BOOL placeBelow = below >= height || below >= above;
        self.compactAboveAnchor = !placeBelow;
        height = MIN(height,MAX(140,placeBelow ? below : above));
        height = chrome + [OCResults compactViewportHeightWithin:height-chrome];
        y = Clamp(placeBelow ? anchor.y-gap-height : upperEdge,NSMinY(room),NSMaxY(room)-height);
    }

    self.basePanelHeight = height - self.reservedFooterHeight;
    NSRect restingFrame = NSMakeRect(x,y,width,height);
    BOOL slideIn = bottom && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    NSRect startFrame = slideIn ? NSOffsetRect(restingFrame,0,-BottomPanelEntranceDistance) : restingFrame;
    CGFloat startOpacity = slideIn ? 0 : 1;
    NSPanel *closing = self.closingPanel;
    if (closing) {
        NSRect closingFrame = closing.frame;
        if (slideIn && closing.screen == screen && NSEqualSizes(closingFrame.size,restingFrame.size)) {
            startFrame = closingFrame;
            startOpacity = closing.alphaValue;
        }
        [closing orderOut:nil];
        self.closingPanel = nil;
    }
    NSPanel *panel = MakePanel(startFrame, OCText(@"Riwayat OpenClipboard", @"OpenClipboard History"));
    if (slideIn) {
        panel.animationBehavior = NSWindowAnimationBehaviorNone;
        panel.alphaValue = startOpacity;
    }
    self.panel = panel;
    [self buildMain:PanelContent(panel)];
    [self installMonitors];
    [panel makeKeyAndOrderFront:nil];
    if ([panel makeFirstResponder:self.results]) ReportMetric("open", self.bottom, started);
    if (slideIn) {
        self.openingBottomPanel = YES;
        __weak OCPicker *weakSelf = self;
        AnimatePanel(panel,restingFrame,1,BottomPanelEntranceDuration,^{
            OCPicker *picker = weakSelf;
            if (picker.panel != panel) return;
            picker.openingBottomPanel = NO;
            [picker updateStatusLayout];
        });
    }
    [self fetchCatalog];
}

- (void)buildMain:(NSView *)view {
    CGFloat w = view.bounds.size.width, h = view.bounds.size.height;
    CGFloat edge = self.bottom ? BottomPanelInset : CompactPanelInset;
    CGFloat control = OCToolbarHeight, gap = 8;
    CGFloat barY = h - edge - control;
    CGFloat buttonX = w - edge - control;
    CGFloat footerY = self.bottom ? 15 : 11;
    CGFloat resultsBottom = footerY + self.reservedFooterHeight;
    CGFloat resultsTop = barY - ResultsTopGap;
    CGFloat resultsHeight = MAX(35,resultsTop-resultsBottom);
    __weak OCPicker *weakSelf = self;

    self.action = OCToolbarIcon(NSMakeRect(buttonX,barY,control,control), view,
        @"ellipsis", OCText(@"Tindakan", @"Actions"), self, @selector(actions:));
    CGFloat railWidth = 0;
    if (self.bottom) {
        CGFloat searchWidth = MAX(120,MIN(260,(buttonX-gap-edge)*0.4));
        self.search = [self makeSearch:NSMakeRect(edge,barY,searchWidth,control) view:view];
        CGFloat tabsX = edge + searchWidth + gap;
        self.tabs = [[OCTabs alloc] initWithFrame:NSMakeRect(tabsX,barY,MAX(60,buttonX-gap-tabsX),control)
            orientation:OCTabsHorizontal];
    } else {
        self.search = [self makeSearch:NSMakeRect(edge,barY,buttonX-gap-edge,control) view:view];
        railWidth = w >= 500 ? 112 : 96;
        self.tabs = [[OCTabs alloc] initWithFrame:NSMakeRect(edge-2,resultsBottom,railWidth,resultsHeight)
            orientation:OCTabsVertical];
    }
    [view addSubview:self.tabs];
    self.tabs.collections = self.collections;
    self.tabs.selectedID = self.activeTab;
    self.tabs.onSelect = ^(int64_t identifier) { [weakSelf selectTab:identifier]; };
    self.tabs.onAdd = ^{ [weakSelf createCollection:nil]; };
    self.tabs.onClickEmpty = ^{
        OCPicker *picker = weakSelf;
        [picker.panel makeFirstResponder:picker.results];
    };
    self.tabs.onCommit = ^(int64_t identifier, NSString *name) {
        [weakSelf sendAction:identifier
            ? @{@"action":@"rename_collection",@"id":@(identifier),@"name":name}
            : @{@"action":@"create_collection",@"name":name}];
    };
    self.tabs.onEndEditing = ^{
        OCPicker *picker = weakSelf;
        [picker.panel makeFirstResponder:picker.results];
    };
    self.tabs.onContext = ^NSMenu *(int64_t identifier) {
        OCPicker *picker = weakSelf;
        NSDictionary *row = [picker collectionRowForID:identifier];
        return row ? [picker contextFor:row] : nil;
    };

    CGFloat scrollInset = railWidth ? railWidth + 6 : 0;
    self.scroll = [self makeScroll:NSMakeRect(edge-2+scrollInset,resultsBottom,w-2*(edge-2)-scrollInset,
        resultsHeight) inView:view horizontal:self.bottom];
    self.results = (OCResults *)self.scroll.documentView;

    self.status = OCLabel(self.recordingStatus ?: @"", 11, NSFontWeightMedium);
    self.status.textColor = NSColor.secondaryLabelColor;
    self.status.frame = NSMakeRect(edge+2,footerY,w-2*edge-2,16);
    [view addSubview:self.status];

    self.undoButton = [self makeUndoButtonIn:view right:w-edge y:footerY-4];
    self.undoButton.hidden = YES;
    self.status.hidden = YES;
    for (NSView *child in view.subviews) {
        if (child != self.status && child != self.undoButton) child.autoresizingMask = NSViewMinYMargin;
    }
    [self refreshUndoControls];
    [self setMessage:self.recordingStatus];
    self.results.picked = ^(NSInteger index, OCResultAction action) {
        [weakSelf pick:index in:weakSelf.results action:action];
    };
    self.results.contextMenu = ^NSMenu *(NSInteger index) {
        OCPicker *picker = weakSelf;
        return picker ? [picker contextFor:picker.results.rows[(NSUInteger)index]] : nil;
    };
    self.results.prepareDrag = ^(NSArray<NSDictionary *> *rows) {
        [weakSelf prepareDragForRows:rows];
    };
    self.scrollObserver = [self observeScroll:self.scroll];
}

- (NSSearchField *)makeSearch:(NSRect)rect view:(NSView *)view {
    NSView *surface = OCToolbarSurface(rect,view);
    NSImageSymbolConfiguration *symbols = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    NSImage *glyph = [[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil]
        imageWithSymbolConfiguration:symbols];
    NSImageView *icon = [NSImageView imageViewWithImage:glyph];
    icon.frame = NSMakeRect(11,11,14,14);
    icon.contentTintColor = NSColor.labelColor;
    [surface addSubview:icon];

    const CGFloat fieldHeight = 22;
    // Borderless NSSearchField draws its text above the middle of its frame.
    CGFloat fieldY = (NSHeight(rect)-fieldHeight)/2 - 3;
    OCToolbarSearchField *search = [[OCToolbarSearchField alloc] initWithFrame:
        NSMakeRect(SearchFieldInset,fieldY,MAX(10,NSWidth(rect)-61),fieldHeight)];
    search.autoresizingMask = NSViewWidthSizable;
    search.placeholderString = OCText(@"Cari klip", @"Search clips");
    search.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    search.bezeled = NO;
    search.bordered = NO;
    search.drawsBackground = NO;
    search.focusRingType = NSFocusRingTypeNone;
    search.delegate = self;
    NSSearchFieldCell *cell = (NSSearchFieldCell *)search.cell;
    cell.searchButtonCell = nil;
    cell.cancelButtonCell = nil;
    [surface addSubview:search];

    NSImage *clearGlyph = [[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:nil]
        imageWithSymbolConfiguration:symbols];
    NSButton *clear = [NSButton buttonWithImage:clearGlyph target:self action:@selector(clearSearch:)];
    clear.frame = NSMakeRect(NSWidth(rect)-27,7,21,22);
    clear.autoresizingMask = NSViewMinXMargin;
    clear.bordered = NO;
    clear.contentTintColor = NSColor.labelColor;
    [clear setAccessibilityLabel:OCText(@"Hapus pencarian", @"Clear search")];
    [surface addSubview:clear];
    search.clearButton = clear;
    [search refreshClearButton];
    return search;
}

- (void)clearSearch:(NSButton *)sender {
    NSSearchField *search = self.activeSearch;
    if (search.superview != sender.superview) return;
    [search.window makeFirstResponder:nil];
    search.stringValue = @"";
    [search.window makeFirstResponder:search];
    [self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
}

- (NSScrollView *)makeScroll:(NSRect)rect inView:(NSView *)view horizontal:(BOOL)horizontal {
    NSScrollView *scroll = horizontal ? [[OCHorizontalScrollView alloc] initWithFrame:rect]
                                     : [[NSScrollView alloc] initWithFrame:rect];
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = NO;
    scroll.hasHorizontalScroller = NO;
    OCResults *canvas = [[OCResults alloc] initWithFrame:NSMakeRect(0,0,NSWidth(rect),NSHeight(rect))];
    canvas.horizontal = horizontal;
    canvas.images = self.images;
    scroll.documentView = canvas;
    [view addSubview:scroll];
    return scroll;
}

- (OCResults *)activeResults { return self.results; }
- (NSSearchField *)activeSearch { return self.search; }
- (NSPanel *)activePanel { return self.panel; }

- (id)observeScroll:(NSScrollView *)scroll {
    scroll.contentView.postsBoundsChangedNotifications = YES;
    __weak OCPicker *weakSelf = self;
    return [NSNotificationCenter.defaultCenter addObserverForName:NSViewBoundsDidChangeNotification
        object:scroll.contentView queue:nil usingBlock:^(__unused NSNotification *note) { [weakSelf loadVisibleImages]; }];
}

- (void)installMonitors {
    __weak OCPicker *weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) { return [weakSelf handleKey:event]; }];
    NSEventMask click = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    self.mouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:click handler:^(__unused NSEvent *event) {
        [weakSelf dismissRestoringFocus:NO];
    }];
    self.appMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:click | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged
        handler:^NSEvent *(NSEvent *event) {
        OCPicker *picker = weakSelf;
        if (!picker) return event;
        if ([event.window.identifier isEqualToString:OCSettingsWindowIdentifier] && event.type != NSEventTypeLeftMouseUp) {
            [picker dismissRestoringFocus:NO];
            return event;
        }
        if (event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeLeftMouseUp) {
            OCResults *results = picker.results;
            if (![results hasPointerGesture]) return event;
            if (event.type == NSEventTypeLeftMouseDragged) {
                if (event.window == picker.panel) [results mouseDragged:event];
            } else {
                [picker clearPendingDrag];
                [results mouseUp:event.window == picker.panel ? event : nil];
            }
            return nil;
        }
        if (event.type != NSEventTypeLeftMouseDown) return event;
        OCResults *results = event.window == picker.panel ? picker.results : nil;
        if (![results containsPickerClick:event]) return event;
        [picker clearPendingDrag];
        [results mouseDown:event];
        return nil;
    }];
    self.resignObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification
        object:NSApp queue:nil usingBlock:^(__unused NSNotification *note) { [weakSelf dismissRestoringFocus:NO]; }];
    self.workspaceObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            OCPicker *picker = weakSelf;
            NSRunningApplication *active = note.userInfo[NSWorkspaceApplicationKey];
            if (picker && active.processIdentifier != picker.origin.processIdentifier &&
                active.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
                [picker dismissRestoringFocus:NO];
            }
        }];
}

- (void)dismissRestoringFocus:(BOOL)restore {
    [self dismissRestoringFocus:restore animate:YES];
}

- (void)dismissRestoringFocus:(BOOL)restore animate:(BOOL)animate {
    NSPanel *panel = self.panel;
    if (!panel) return;
    [self clearPendingDrag];
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
    if (self.mouseMonitor) [NSEvent removeMonitor:self.mouseMonitor];
    if (self.appMouseMonitor) [NSEvent removeMonitor:self.appMouseMonitor];
    if (self.resignObserver) [NSNotificationCenter.defaultCenter removeObserver:self.resignObserver];
    if (self.workspaceObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.workspaceObserver];
    if (self.scrollObserver) [NSNotificationCenter.defaultCenter removeObserver:self.scrollObserver];
    self.keyMonitor = nil;
    self.mouseMonitor = nil;
    self.appMouseMonitor = nil;
    self.resignObserver = nil;
    self.workspaceObserver = nil;
    self.scrollObserver = nil;
    self.preview.animates = NO;
    [self clearPreview];
    NSRunningApplication *origin = self.origin;
    self.tabs = nil;
    self.panel = nil;
    self.origin = nil;
    self.panelToken++;
    self.catalogTicket++;
    self.results = nil;
    self.scroll = nil;
    self.status = nil;
    self.undoButton = nil;
    [self.images removeAllObjects];
    [self.requested removeAllObjects];
    if (animate && self.bottom && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        // The closing window is visual only. A subsequent shortcut can open a new picker immediately.
        panel.ignoresMouseEvents = YES;
        self.closingPanel = panel;
        NSRect frame = panel.frame;
        NSScreen *screen = panel.screen ?: ScreenAt(frame.origin);
        CGFloat restingY = NSMinY(screen.visibleFrame) + BottomScreenInset;
        frame.origin.y = MIN(NSMinY(frame),restingY) - BottomPanelExitDistance;
        __weak OCPicker *weakSelf = self;
        AnimatePanel(panel,frame,0,BottomPanelExitDuration,^{
            [panel orderOut:nil];
            OCPicker *picker = weakSelf;
            if (picker.closingPanel == panel) picker.closingPanel = nil;
        });
    } else {
        [panel orderOut:nil];
    }
    if (restore && NSApp.isActive && origin && !origin.terminated &&
        origin.processIdentifier != NSProcessInfo.processInfo.processIdentifier &&
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != origin.processIdentifier) {
        if (@available(macOS 14.0, *)) {
            [NSApp yieldActivationToApplication:origin];
            [origin activateWithOptions:0];
        } else {
            [origin activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        }
    }
}

- (void)fetchCatalog {
    if (!self.panel) return;
    uint64_t ticket = ++self.catalogTicket;
    if (self.catalogFailed && !self.results.rows.count) {
        [self.results showEmptyTitle:nil detail:nil announce:NO];
        [self.results layoutRows];
    }
    self.catalogPending = YES;
    self.catalogFailed = NO;
    if (!OCSend(@{@"action":@"catalog", @"ticket":@(ticket),
        @"query":self.search.stringValue ?: @"", @"kind":@"", @"collection":@(self.activeTab)})) {
        [self catalogDidFail];
        return;
    }
    if (!self.results.rows.count) {
        __weak OCPicker *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            OCPicker *picker = weakSelf;
            if (picker.catalogTicket != ticket || !picker.catalogPending || picker.results.rows.count) return;
            [picker.results showEmptyTitle:OCText(@"Memuat klip…", @"Loading clips…") detail:nil announce:NO];
            [picker.results layoutRows];
        });
    }
}

- (void)catalogDidFail {
    self.catalogPending = NO;
    self.catalogFailed = YES;
    if (self.results.actionsSuspended) self.results.rows = @[];
    if (!self.results.rows.count) {
        [self.results showEmptyTitle:OCText(@"Riwayat gagal dimuat", @"Could not load history") detail:OCText(@"Tekan Enter untuk mencoba lagi.", @"Press Enter to retry.") announce:YES];
        [self.results layoutRows];
    } else {
        [self setWarning:OCText(@"Riwayat gagal diperbarui.", @"Could not refresh history.")];
    }
}

- (void)suspendResultActions {
    [self clearPendingDrag];
    self.results.actionsSuspended = YES;
    self.results.selected = -1;
    [self.results showEmptyTitle:nil detail:nil announce:NO];
    [self.results layoutRows];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.activeSearch) return;
    [(OCToolbarSearchField *)notification.object refreshClearButton];
    [self clearPreview];
    [self suspendResultActions];
    self.searchStarted = NSProcessInfo.processInfo.systemUptime;
    [self fetchCatalog];
}

- (void)receiveEvent:(NSDictionary *)event {
    NSString *kind = event[@"kind"];
    if ([kind isEqualToString:@"deleted"]) {
        self.undoTicket = [event[@"ticket"] unsignedLongLongValue];
        self.undoPending = NO;
        self.undoCount = [event[@"count"] unsignedIntegerValue];
        [self refreshUndoControls];
        [self setMessage:self.recordingStatus];
        return;
    }
    if ([kind isEqualToString:@"undo_expired"] || [kind isEqualToString:@"delete_undone"]) {
        if ([event[@"ticket"] unsignedLongLongValue] != self.undoTicket) return;
        self.undoTicket = 0;
        self.undoPending = NO;
        self.undoCount = 0;
        [self refreshUndoControls];
        [self setMessage:[kind isEqualToString:@"delete_undone"] ? OCText(@"Klip dipulihkan.", @"Clips restored.") : self.recordingStatus];
        return;
    }
    if ([kind isEqualToString:@"undo_failed"]) {
        if ([event[@"ticket"] unsignedLongLongValue] != self.undoTicket) return;
        self.undoPending = NO;
        [self refreshUndoControls];
        [self setWarning:[event[@"reason"] isEqualToString:@"undo_full"]
            ? OCText(@"Batas riwayat tercapai.", @"History limit reached.") : OCText(@"Klip belum dipulihkan.", @"Could not restore the clips.")];
        return;
    }
    if (!self.panel) return;
    if ([kind isEqualToString:@"changed"]) {
        [self fetchCatalog];
    } else if ([kind isEqualToString:@"created"]) {
        [self setMessage:OCText(@"Koleksi dibuat.", @"Collection created.")];
        if (event[@"id"]) [self selectTab:[event[@"id"] longLongValue]];
        else [self fetchCatalog];
    } else if ([kind isEqualToString:@"error"]) {
        NSString *reason = event[@"reason"];
        [self clearPendingDrag];
        self.payloadMode = OCIdle;
        NSString *description = @{@"full":OCText(@"Ruang penyimpanan tidak cukup.", @"There is not enough storage."),
            @"missing":OCText(@"Klip ini sudah tidak tersedia.", @"This clip is no longer available."), @"collection_name":OCText(@"Nama koleksi kosong, terlalu panjang, atau sudah dipakai.", @"The collection name is empty, too long, or already in use."),
            @"collection_missing":OCText(@"Koleksi sudah tidak tersedia.", @"This collection is no longer available.")}[reason];
        [self setWarning:description ?: OCText(@"Tindakan gagal. Coba lagi.", @"The action failed. Try again.")];
    } else if ([kind isEqualToString:@"catalog_failed"]) {
        if ([event[@"ticket"] unsignedLongLongValue] == self.catalogTicket) [self catalogDidFail];
    } else if ([kind isEqualToString:@"catalog"] && [event[@"ticket"] unsignedLongLongValue] == self.catalogTicket) {
        self.catalogPending = NO;
        self.catalogFailed = NO;
        self.results.actionsSuspended = NO;
        NSDictionary *catalog = event[@"catalog"];
        NSArray *nextCollections = catalog[@"collections"] ?: @[];
        self.collections = nextCollections;
        self.tabs.collections = nextCollections;
        if (self.activeTab && ![self collectionRowForID:self.activeTab]) {
            [self selectTab:0];
            return;
        }
        [self refreshTabState];
        if (self.revealTab) {
            self.revealTab = NO;
            [self.tabs scrollSelectedToVisible];
        }
        self.clips = catalog[@"clips"] ?: @[];
        OCResults *result = self.activeResults;
        BOOL query = self.activeSearch.stringValue.length > 0;
        NSString *title = query ? OCText(@"Tidak ada hasil", @"No results") : self.activeTab ? OCText(@"Koleksi masih kosong", @"This collection is empty") : OCText(@"Belum ada klip", @"No clips yet");
        NSString *detail = nil;
        if (!query && !self.activeTab) {
            detail = self.shortcutLabel.length
                ? [NSString stringWithFormat:OCText(@"Salin teks atau gambar, lalu tekan %@.", @"Copy text or an image, then press %@."),self.shortcutLabel]
                : OCText(@"Salin teks atau gambar untuk mulai mengisi riwayat.", @"Copy text or an image to start building your history.");
        }
        [self renderRows:self.clips in:result emptyTitle:title detail:detail announce:query];
        [self loadVisibleImages];
        ReportMetric("search", self.bottom, self.searchStarted);
        self.searchStarted = 0;
    }
}

- (void)renderRows:(NSArray<NSDictionary *> *)rows in:(OCResults *)result
        emptyTitle:(NSString *)title detail:(NSString *)detail announce:(BOOL)announce {
    NSNumber *previous = [self selectedIn:result][@"id"];
    BOOL selectedWasVisible = previous && NSIntersectsRect([result rowFrame:result.selected],result.visibleRect);
    [result replaceRowsPreservingSelection:rows];
    NSInteger index = result.selected;
    [result showEmptyTitle:title detail:detail announce:announce];
    [result layoutRows];
    if (index >= 0 && (selectedWasVisible || ![previous isEqual:rows[(NSUInteger)index][@"id"]]))
        [result scrollRowToVisible:index];
    NSAccessibilityPostNotification(result, NSAccessibilityLayoutChangedNotification);
}

- (NSDictionary *)collectionRowForID:(int64_t)identifier {
    for (NSDictionary *collection in self.collections) {
        if ([collection[@"id"] longLongValue] == identifier)
            return @{@"id":collection[@"id"],@"title":collection[@"name"] ?: @"",@"kind":@"koleksi",
                     @"color":collection[@"color"] ?: @""};
    }
    return nil;
}

- (void)refreshTabState {
    self.tabs.selectedID = self.activeTab;
    NSString *name = [self collectionRowForID:self.activeTab][@"title"];
    self.search.placeholderString = self.activeTab && name
        ? [NSString stringWithFormat:OCText(@"Cari di %@", @"Search in %@"),name] : OCText(@"Cari klip", @"Search clips");
}

- (void)selectTab:(int64_t)collectionID {
    if (!self.panel) return;
    if (collectionID == self.activeTab) {
        if (self.catalogFailed) [self fetchCatalog];
        return;
    }
    [self clearPreview];
    self.activeTab = collectionID;
    self.revealTab = YES;
    self.search.stringValue = @"";
    [self refreshTabState];
    [self.tabs scrollSelectedToVisible];
    self.results.rows = @[];
    [self suspendResultActions];
    [self.panel makeFirstResponder:self.results];
    [self fetchCatalog];
}

- (void)selectTabAtIndex:(NSInteger)index {
    if (self.tabs) [self selectTab:[self.tabs collectionIDAtIndex:index]];
}

- (void)stepTab:(NSInteger)delta {
    if (!self.tabs) return;
    [self selectTabAtIndex:(NSInteger)oc_tab_step(self.tabs.selectedIndex,self.tabs.tabCount,delta)];
}

- (NSDictionary *)selectedIn:(OCResults *)results {
    return results.selected >= 0 && (NSUInteger)results.selected < results.rows.count
        ? results.rows[(NSUInteger)results.selected] : nil;
}

- (void)pick:(NSInteger)index in:(OCResults *)canvas confirm:(BOOL)confirm {
    [self pick:index in:canvas action:confirm ? OCResultConfirm : OCResultSelect];
}

- (void)pick:(NSInteger)index in:(OCResults *)canvas action:(OCResultAction)action {
    if (canvas.actionsSuspended || index < 0 || (NSUInteger)index >= canvas.rows.count) return;
    if (index != canvas.selected || action == OCResultExtendSelection || action == OCResultToggleSelection)
        [self clearPreview];
    if (action == OCResultExtendSelection) [canvas extendSelectionTo:index];
    else if (action == OCResultToggleSelection) [canvas toggleSelectionAt:index];
    else canvas.selected = index;
    [canvas scrollRowToVisible:index];
    if (action == OCResultConfirm) [self useSelected:OCPaste];
}

- (NSButton *)makeUndoButtonIn:(NSView *)view right:(CGFloat)right y:(CGFloat)y {
    NSButton *button = [NSButton buttonWithTitle:OCText(@"Urungkan", @"Undo") target:self action:@selector(undoDelete:)];
    button.frame = NSMakeRect(right-88,y,88,24);
    button.controlSize = NSControlSizeSmall;
    button.toolTip = OCText(@"Pulihkan klip yang baru dihapus (⌘Z saat fokus di hasil)", @"Restore deleted clips (⌘Z when results are focused)");
    [view addSubview:button];
    return button;
}

- (void)refreshUndoControls {
    BOOL available = self.undoTicket != 0;
    NSButton *button = self.undoButton;
    if (!available && button.window.firstResponder == button)
        [button.window makeFirstResponder:self.results.rows.count ? self.results : self.search];
    BOOL appeared = available && button.hidden;
    button.hidden = !available;
    button.enabled = !self.undoPending;
    if (appeared && self.panel.visible) FadeInFeedback(button);
    [self updateStatusLayout];
}

- (void)updateStatusLayout {
    NSTextField *label = self.status;
    if (!label) return;
    BOOL hasText = label.stringValue.length > 0;
    BOOL appeared = hasText && label.hidden;
    label.hidden = !hasText;
    NSRect frame = label.frame;
    CGFloat edge = NSMinX(frame)-2;
    frame.size.width = MAX(0,NSWidth(label.superview.bounds)-2*edge-2-(self.undoButton.hidden ? 0 : 96));
    label.frame = frame;
    if (appeared && self.panel.visible) FadeInFeedback(label);
    [self updateFooterSpace:hasText || !self.undoButton.hidden];
}

- (void)updateFooterSpace:(BOOL)visible {
    CGFloat footer = visible ? FooterHeight : 0;
    if (self.openingBottomPanel || footer == self.reservedFooterHeight) return;
    self.reservedFooterHeight = footer;
    NSRect frame = self.panel.frame;
    NSScreen *screen = self.panel.screen ?: ScreenAt(frame.origin);
    NSRect room = NSInsetRect(screen.visibleFrame,0,self.bottom ? BottomScreenInset : 12);
    BOOL keepBottom = self.bottom || self.compactAboveAnchor;
    CGFloat available = keepBottom ? NSMaxY(room)-NSMinY(frame) : NSMaxY(frame)-NSMinY(room);
    CGFloat height = MIN(self.basePanelHeight+footer,MAX(self.basePanelHeight,available));
    if (!keepBottom) frame.origin.y = NSMaxY(frame)-height;
    frame.size.height = height;
    [self.panel setFrame:frame display:NO];

    NSRect viewport = self.scroll.frame;
    CGFloat bottom = NSMinY(self.status.frame)+footer;
    viewport.size.height = MAX(0,NSMaxY(viewport)-bottom);
    viewport.origin.y = bottom;
    self.scroll.frame = viewport;
    if (!self.bottom) {
        NSRect rail = self.tabs.frame;
        rail.origin.y = bottom;
        rail.size.height = viewport.size.height;
        self.tabs.frame = rail;
    }
    [self.results layoutRows];
}

- (void)undoDelete:(id)sender {
    if (!self.undoTicket || self.undoPending) return;
    self.undoPending = OCSend(@{@"action":@"undo_delete",@"ticket":@(self.undoTicket)});
    if (!self.undoPending) [self setWarning:OCText(@"Riwayat sedang sibuk. Coba lagi.", @"History is busy. Try again.")];
    [self refreshUndoControls];
}

// Neutral status. A non-empty recording status (blocked clipboard, full storage) is a
// standing problem, so it keeps the warning style until it clears.
- (void)setMessage:(NSString *)message {
    BOOL standing = message.length && [message isEqualToString:self.recordingStatus];
    if (!standing) self.messageTicket++;
    [self presentStatus:message warning:standing announce:NO];
}

// Failed action. Shown with a warning icon, announced to VoiceOver, and cleared after a while.
- (void)setWarning:(NSString *)message {
    uint64_t ticket = ++self.messageTicket;
    [self presentStatus:message warning:YES announce:YES];
    __weak OCPicker *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        OCPicker *picker = weakSelf;
        if (picker && picker.panel && picker.messageTicket == ticket) [picker setMessage:picker.recordingStatus];
    });
}

- (void)presentStatus:(NSString *)message warning:(BOOL)warning announce:(BOOL)announce {
    NSTextField *label = self.status;
    if (!label) return;
    NSString *undoMessage = self.undoTicket
        ? [NSString stringWithFormat:OCText(@"%lu klip dihapus.", @"Deleted %lu."), (unsigned long)self.undoCount]
        : @"";
    NSString *text = message.length ? message : undoMessage;
    warning = warning && text.length;
    if (warning) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:nil];
        attachment.image = [symbol imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.systemOrangeColor]]];
        attachment.bounds = NSMakeRect(0,-2,13,12);
        NSMutableAttributedString *content = [[NSMutableAttributedString alloc]
            initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        [content appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:text]
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName:NSColor.labelColor, NSParagraphStyleAttributeName:style}]];
        label.attributedStringValue = content;
    } else {
        label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        label.textColor = NSColor.secondaryLabelColor;
        label.stringValue = text;
    }
    label.accessibilityLabel = warning ? [OCText(@"Peringatan: ", @"Warning: ") stringByAppendingString:text] : nil;
    if (announce && warning) {
        NSAccessibilityPostNotificationWithUserInfo(label,NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey:text,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityHigh)});
    }
    [self updateStatusLayout];
}

- (void)sendAction:(NSDictionary *)request {
    if (!OCSend(request)) [self setWarning:OCText(@"Riwayat sedang sibuk. Coba lagi.", @"History is busy. Try again.")];
}

- (void)loadVisibleImages {
    if (!self.panel) return;
    NSArray *visible = self.activeResults.visibleRows;
    if (self.images.count > 36) {
        NSMutableSet *keep = [NSMutableSet set];
        for (NSDictionary *row in visible) [keep addObject:row[@"id"]];
        for (NSNumber *key in self.images.allKeys)
            if (![keep containsObject:key]) [self.images removeObjectForKey:key];
    }
    for (NSDictionary *row in visible) {
        NSNumber *identifier = row[@"id"];
        if ([row[@"kind"] isEqualToString:@"gambar"] && !self.images[identifier] && ![self.requested containsObject:identifier]) {
            if (OCSend(@{@"action":@"thumbnail",@"ticket":@(self.panelToken),@"id":identifier}))
                [self.requested addObject:identifier];
        }
    }
}

- (void)receiveThumbnail:(NSData *)data ticket:(uint64_t)ticket id:(int64_t)clip {
    if (!self.panel || ticket != self.panelToken) return;
    NSNumber *identifier = @(clip);
    [self.requested removeObject:identifier];
    for (NSDictionary *entry in self.activeResults.visibleRows) {
        if ([entry[@"id"] isEqual:identifier] && [entry[@"kind"] isEqualToString:@"gambar"]) {
            NSImage *image = [[NSImage alloc] initWithData:data];
            if (image) {
                self.images[identifier] = image;
                [self.activeResults invalidateClip:identifier];
            }
            break;
        }
    }
}

- (void)clearPendingDrag {
    self.dragClips = nil;
    self.dragItems = nil;
    self.results.preparingDrag = NO;
}

- (void)prepareDragForRows:(NSArray<NSDictionary *> *)rows {
    NSMutableDictionary<NSNumber *, NSNumber *> *clips = [NSMutableDictionary dictionary];
    for (NSDictionary *row in rows) {
        NSNumber *ticket = @(++self.nextPayloadTicket);
        NSNumber *identifier = row[@"id"];
        if (!OCSend(@{@"action":@"payload",@"id":identifier,@"ticket":ticket})) {
            [self setWarning:OCText(@"Riwayat sedang sibuk. Coba lagi.", @"History is busy. Try again.")];
            return;
        }
        clips[ticket] = identifier;
    }
    self.dragClips = clips;
    self.dragItems = [NSMutableDictionary dictionary];
    __weak OCPicker *weakSelf = self;
    NSDictionary *request = self.dragClips;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        OCPicker *picker = weakSelf;
        if (picker.dragClips == request) picker.results.preparingDrag = YES;
    });
}

- (void)useSelected:(OCPayloadMode)mode {
    OCResults *canvas = self.activeResults;
    NSDictionary *row = [self selectedIn:canvas];
    if (!row || canvas.actionsSuspended) return;
    int64_t identifier = [row[@"id"] longLongValue];
    if (mode == OCPaste) {
        // Without permission to post key events the clip is only copied, so any origin works.
        if (CGPreflightPostEventAccess() && ![self canPasteToOrigin]) return;
    }
    self.payloadMode = mode;
    uint64_t ticket = self.payloadTicket = ++self.nextPayloadTicket;
    if (!OCSend(@{@"action":@"payload",@"id":@(identifier),@"ticket":@(ticket)})) {
        self.payloadMode = OCIdle;
        [self setWarning:OCText(@"Riwayat sedang sibuk. Coba lagi.", @"History is busy. Try again.")];
    }
}

- (void)receivePayload:(NSArray<NSDictionary *> *)parts ticket:(uint64_t)ticket
                    id:(int64_t)clip {
    NSNumber *dragTicket = @(ticket);
    if ([self.dragClips[dragTicket] isEqual:@(clip)]) {
        NSArray<NSPasteboardItem *> *items = OCPasteboardItems(parts);
        if (!items.count) {
            [self clearPendingDrag];
            [self setWarning:OCText(@"Klip gagal disiapkan untuk diseret.", @"Could not prepare the clip for dragging.")];
            return;
        }
        self.dragItems[dragTicket] = items;
        if (self.dragItems.count == self.dragClips.count) {
            NSMutableArray<NSPasteboardItem *> *selection = [NSMutableArray array];
            for (NSNumber *key in [self.dragClips.allKeys sortedArrayUsingSelector:@selector(compare:)])
                [selection addObjectsFromArray:self.dragItems[key]];
            [self clearPendingDrag];
            [self.results beginPreparedDrag:selection];
        }
        return;
    }
    if (!self.panel || self.payloadMode == OCIdle || ticket != self.payloadTicket ||
        [[self selectedIn:self.activeResults][@"id"] longLongValue] != clip) return;
    OCPayloadMode mode = self.payloadMode;
    self.payloadMode = OCIdle;
    if (mode == OCPaste) {
        BOOL direct = CGPreflightPostEventAccess();
        if (direct && ![self canPasteToOrigin]) return;
        NSInteger version;
        if (self.prepareClipboardWrite && !self.prepareClipboardWrite()) {
            [self setWarning:OCText(@"Clipboard sedang direkam. Coba tempel lagi sebentar.", @"The clipboard is being captured. Try pasting again in a moment.")];
            return;
        }
        if (!OCWriteClipboard(parts,&version)) {
            [self setWarning:OCText(@"Klip gagal disiapkan untuk ditempel.", @"Could not prepare the clip for pasting.")];
            return;
        }
        NSRunningApplication *destination = self.origin;
        NSScreen *screen = self.activePanel.screen;
        [self dismissRestoringFocus:YES animate:!direct];
        if (!direct) {
            // No permission to send ⌘V: the clip is on the clipboard, so tell the user to paste it.
            [self showToast:OCAccessibilityReady() ? OCText(@"Disalin. Tekan ⌘V untuk menempel.", @"Copied. Press ⌘V to paste.")
                : OCText(@"Disalin. Tekan ⌘V. Aktifkan Accessibility untuk tempel otomatis.", @"Copied. Press ⌘V. Enable Accessibility to paste automatically.") onScreen:screen];
            return;
        }
        uint64_t token = self.panelToken;
        // Let the original window regain the key focus before dispatching the paste.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pasteTo:destination clip:clip version:version token:token retries:4];
        });
        return;
    }
    [self showPreview:parts];
}

- (void)showToast:(NSString *)text onScreen:(NSScreen *)preferred {
    [self.toast orderOut:nil];
    NSScreen *screen = preferred ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect room = NSInsetRect(screen.visibleFrame,20,20);
    NSTextField *label = OCLabel(text,13,NSFontWeightMedium);
    label.textColor = NSColor.labelColor;
    CGFloat width = MIN(NSWidth(room),ceil([label.attributedStringValue size].width)+48), height = 38;
    NSRect frame = NSMakeRect(NSMidX(room)-width/2,NSMinY(room)+24,width,height);
    NSPanel *toast = [[NSPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    toast.title = OCText(@"Pemberitahuan OpenClipboard", @"OpenClipboard Notification");
    toast.releasedWhenClosed = NO;
    toast.hidesOnDeactivate = NO;
    toast.floatingPanel = YES;
    toast.level = NSFloatingWindowLevel;
    toast.opaque = NO;
    toast.backgroundColor = NSColor.clearColor;
    toast.hasShadow = YES;
    toast.ignoresMouseEvents = YES;
    toast.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    background.material = NSVisualEffectMaterialPopover;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.maskImage = GlassMask(background.bounds.size,height/2);
    label.alignment = NSTextAlignmentCenter;
    label.frame = NSMakeRect(18,(height-18)/2,width-36,18);
    [background addSubview:label];
    toast.contentView = background;
    self.toast = toast;
    [toast orderFrontRegardless];
    NSAccessibilityPostNotificationWithUserInfo(NSApp,NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey:text,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityHigh)});

    uint64_t ticket = ++self.toastTicket;
    __weak OCPicker *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        OCPicker *picker = weakSelf;
        if (!picker || picker.toastTicket != ticket) return;
        NSPanel *visibleToast = picker.toast;
        if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
            [visibleToast orderOut:nil];
            picker.toast = nil;
            return;
        }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = FeedbackFadeDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
            visibleToast.animator.alphaValue = 0;
        } completionHandler:^{
            [visibleToast orderOut:nil];
            OCPicker *currentPicker = weakSelf;
            if (currentPicker.toast == visibleToast) currentPicker.toast = nil;
        }];
    });
}

- (BOOL)canPasteToOrigin {
    pid_t own = NSProcessInfo.processInfo.processIdentifier;
    NSRunningApplication *origin = self.origin;
    if (!origin || origin.terminated || origin.processIdentifier == own) {
        [self setWarning:OCText(@"Buka panel dari aplikasi tujuan tempel.", @"Open the panel from the app you want to paste into.")];
        return NO;
    }
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (front == origin.processIdentifier || front == own) return YES;
    [self setWarning:OCText(@"Aplikasi tujuan sudah berganti.", @"The destination app has changed.")];
    return NO;
}

- (void)pasteTo:(NSRunningApplication *)destination clip:(int64_t)clip version:(NSInteger)version
          token:(uint64_t)token retries:(NSUInteger)retries {
    if (token != self.panelToken) return;
    pid_t target = destination.processIdentifier;
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (!destination.terminated && front == target && OCPostPaste(target,version)) {
        if (!OCSend(@{@"action":@"pasted",@"id":@(clip)}))
            NSLog(@"OpenClipboard could not update the pasted clip's position in history.");
    } else if (!destination.terminated && front == NSProcessInfo.processInfo.processIdentifier && retries) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self pasteTo:destination clip:clip version:version token:token retries:retries-1];
        });
    } else {
        [self showToast:OCText(@"Tempel otomatis gagal. Periksa clipboard sebelum menempel.", @"Auto-paste failed. Check the clipboard before pasting.") onScreen:nil];
    }
}

- (void)showPreview:(NSArray<NSDictionary *> *)parts {
    [self clearPreview];
    NSRect available = (self.activePanel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = NSMakeSize(floor(MIN(640, NSWidth(available) * 0.72)),
                             floor(MIN(460, NSHeight(available) * 0.55)));
    NSRect body = NSMakeRect(16,14,size.width-32,size.height-54);
    NSViewController *controller = [NSViewController new];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,size.width,size.height)];
    controller.view = view;
    NSTextField *title = OCLabel(OCText(@"Pratinjau", @"Preview"),13,NSFontWeightSemibold);
    title.frame = NSMakeRect(NSMinX(body),size.height-29,NSWidth(body),19);
    [view addSubview:title];

    NSString *kind = [self selectedIn:self.activeResults][@"kind"];
    NSString *text = nil;
    NSImage *image = nil;
    for (NSDictionary *part in parts) {
        NSString *type = part[@"type"];
        NSData *bytes = part[@"data"];
        if (!text && ([type isEqualToString:NSPasteboardTypeString] || [type isEqualToString:NSPasteboardTypeURL]))
            text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
        if (!text && [type hasPrefix:@"public.utf16"])
            text = [[NSString alloc] initWithData:bytes encoding:NSUTF16StringEncoding];
        if (!image && ([type isEqualToString:NSPasteboardTypePNG] || [type isEqualToString:NSPasteboardTypeTIFF]))
            image = [[NSImage alloc] initWithData:bytes];
    }
    if (image) {
        NSImageView *preview = [NSImageView imageViewWithImage:image];
        preview.frame = body;
        preview.imageScaling = NSImageScaleProportionallyUpOrDown;
        [view addSubview:preview];
    } else {
        if (text) {
            NSTextField *count = OCLabel(OCCharacterCountLabel(OCCharacterCount(text)),12,NSFontWeightRegular);
            count.textColor = NSColor.secondaryLabelColor;
            count.alignment = NSTextAlignmentRight;
            CGFloat halfWidth = floor(NSWidth(body)/2);
            title.frame = NSMakeRect(NSMinX(body),size.height-29,halfWidth,19);
            count.frame = NSMakeRect(NSMinX(body)+halfWidth,size.height-29,NSWidth(body)-halfWidth,19);
            [view addSubview:count];
        }
        NSScrollView *scroll = [NSTextView scrollableTextView];
        scroll.frame = body;
        scroll.autohidesScrollers = YES;
        NSTextView *preview = (NSTextView *)scroll.documentView;
        if ([kind isEqualToString:@"json"] && text.length) {
            id object = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (object) {
                NSData *formatted = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
                if (formatted) text = [[NSString alloc] initWithData:formatted encoding:NSUTF8StringEncoding];
            }
        }
        preview.string = text ?: [self selectedIn:self.activeResults][@"title"] ?: @"";
        preview.editable = NO;
        preview.selectable = YES;
        preview.drawsBackground = NO;
        preview.font = ([kind isEqualToString:@"json"] || [kind isEqualToString:@"kode"])
            ? [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular] : [NSFont systemFontOfSize:13];
        scroll.drawsBackground = NO;
        [view addSubview:scroll];
    }
    self.preview = [NSPopover new];
    self.preview.animates = !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.preview.behavior = NSPopoverBehaviorTransient;
    self.preview.delegate = self;
    self.preview.contentViewController = controller;
    self.preview.contentSize = size;
    OCResults *results = self.activeResults;
    NSRect clipRect = [results rowFrame:results.selected];
    if (!NSIntersectsRect(clipRect, results.visibleRect)) [results scrollRectToVisible:clipRect];
    NSRect visibleClip = NSIntersectionRect(clipRect, results.visibleRect);
    [self.preview showRelativeToRect:visibleClip ofView:results
                      preferredEdge:self.bottom ? NSRectEdgeMaxY : NSRectEdgeMaxX];
}

- (void)clearPreview {
    self.payloadTicket++;
    self.payloadMode = OCIdle;
    self.preview.delegate = nil;
    [self.preview close];
    self.preview = nil;
}

- (void)popoverDidClose:(NSNotification *)notification {
    if (notification.object != self.preview) return;
    [self clearPreview];
    [self setMessage:self.recordingStatus];
}

- (BOOL)focusSearchForTyping:(NSEvent *)event inWindow:(NSWindow *)window field:(NSSearchField *)search {
    NSString *characters = event.characters.length ? event.characters : event.charactersIgnoringModifiers;
    if (!characters.length || event.keyCode == kVK_Space) return NO;
    unichar first = [characters characterAtIndex:0];
    if ([NSCharacterSet.controlCharacterSet characterIsMember:first] ||
        (first >= NSUpArrowFunctionKey && first <= NSModeSwitchFunctionKey)) return NO;
    if (![window makeFirstResponder:search]) return NO;
    NSText *editor = search.currentEditor;
    editor.selectedRange = NSMakeRange(editor.string.length,0);
    return YES;
}

- (NSEvent *)handleKey:(NSEvent *)event {
    NSWindow *previewWindow = self.preview.contentViewController.view.window;
    if (!self.panel || (event.window != self.panel && event.window != previewWindow)) return event;
    NSEventModifierFlags flags = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    uint16_t key = event.keyCode;
    NSWindow *window = self.activePanel;
    OCResults *results = self.activeResults;
    NSResponder *focused = window.firstResponder;
    NSSearchField *search = self.activeSearch;
    NSText *editor = search.currentEditor;
    BOOL searchFocused = focused == search || (editor && focused == editor);
    BOOL resultFocused = focused == results;
    BOOL composing = [editor isKindOfClass:NSTextView.class] && [(NSTextView *)editor hasMarkedText];
    BOOL emptySearch = searchFocused && !composing && !(editor ? editor.string.length : search.stringValue.length);
    BOOL preview = self.preview.shown;
    BOOL previewPending = self.payloadMode == OCPreview;
    BOOL horizontalArrow = results.horizontal && (key == kVK_LeftArrow || key == kVK_RightArrow);
    NSButton *undoButton = self.undoButton;

    if (self.tabs.editing) {
        // The inline name field owns the keyboard; Return and editing keys reach it untouched.
        if (key == kVK_Escape) { [self.tabs cancelEditing]; return nil; }
        return event;
    }

    if (flags == NSEventModifierFlagCommand && key == kVK_ANSI_Z && resultFocused && self.undoTicket) {
        if (!event.isARepeat) [self undoDelete:nil];
        return nil;
    }
    if (flags == NSEventModifierFlagCommand && !composing && event.window == window) {
        // ⌘1…⌘9 jump to a tab; ⌘ with any arrow steps tabs, so both axes work in both layouts.
        static const uint16_t digitKeys[] = {kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                             kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9};
        for (NSInteger digit = 1; digit <= 9; digit++) {
            if (key != digitKeys[digit-1]) continue;
            int64_t index = oc_tab_for_digit(digit,self.tabs.tabCount);
            if (!event.isARepeat && index >= 0) [self selectTabAtIndex:(NSInteger)index];
            return nil;
        }
        BOOL back = key == kVK_LeftArrow || key == kVK_UpArrow;
        BOOL forward = key == kVK_RightArrow || key == kVK_DownArrow;
        if (back || forward) {
            if (!event.isARepeat) [self stepTab:back ? -1 : 1];
            return nil;
        }
    }
    if (resultFocused && !preview && event.window == window &&
        !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
        [self focusSearchForTyping:event inWindow:window field:search]) {
        return event;
    }
    if (flags == NSEventModifierFlagOption && horizontalArrow && !composing && !preview &&
        results.rows.count && (resultFocused || emptySearch)) {
        // ⌥← / ⌥→ jump between days in the card row.
        if (searchFocused && ![window makeFirstResponder:results]) return event;
        [self pick:DayGroupIndex(results.rows,results.selected,key == kVK_RightArrow) in:results action:OCResultSelect];
        return nil;
    }
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return event;

    if (!flags && (key == kVK_Delete || key == kVK_ForwardDelete) &&
        resultFocused && !preview) {
        if (!event.isARepeat) [self deleteSelected];
        return nil;
    }
    if (!flags && key == kVK_Space &&
        (preview || ((resultFocused || emptySearch) && (previewPending || results.selected >= 0)))) {
        if (!event.isARepeat) {
            if (preview || previewPending) [self clearPreview];
            else [self useSelected:OCPreview];
        }
        return nil;
    }
    if (key == kVK_Escape) {
        if (preview || previewPending) [self clearPreview];
        else [self dismissRestoringFocus:YES];
        return nil;
    }
    if (focused == self.tabs && !flags) {
        uint16_t previousKey = self.bottom ? kVK_LeftArrow : kVK_UpArrow;
        uint16_t nextKey = self.bottom ? kVK_RightArrow : kVK_DownArrow;
        if (key == previousKey || key == nextKey) {
            [self stepTab:key == nextKey ? 1 : -1];
            [window makeFirstResponder:self.tabs];
            return nil;
        }
    }
    if (key == kVK_Tab) {
        NSMutableArray<NSView *> *order = [NSMutableArray arrayWithObject:search];
        if (results.rows.count) [order addObject:results];
        [order addObject:self.tabs];
        [order addObject:self.action];
        if (undoButton && !undoButton.hidden && undoButton.enabled) [order addObject:undoButton];
        NSUInteger index = searchFocused ? 0 : [order indexOfObjectIdenticalTo:(NSView *)focused];
        if (index == NSNotFound) index = 0;
        NSInteger step = flags & NSEventModifierFlagShift ? -1 : 1;
        NSInteger next = ((NSInteger)order.count + (NSInteger)index + step) % (NSInteger)order.count;
        [window makeFirstResponder:order[(NSUInteger)next]];
        return nil;
    }
    if (key == kVK_Return || key == kVK_ANSI_KeypadEnter) {
        if (preview) { [self useSelected:OCPaste]; return nil; }
        if (focused == self.tabs) {
            if (self.catalogFailed) [self fetchCatalog];
            return nil;
        }
        if (focused == self.action || (undoButton && focused == undoButton)) {
            [(NSButton *)focused performClick:nil];
            return nil;
        }
        if (searchFocused && composing) return event;
        if (searchFocused || resultFocused) {
            if (self.catalogFailed && (results.actionsSuspended || !results.rows.count)) [self fetchCatalog];
            else [self pick:results.selected in:results confirm:YES];
            return nil;
        }
    }
    if (resultFocused && (flags & NSEventModifierFlagShift) && key == kVK_F10) {
        [self showClipActions];
        return nil;
    }
    BOOL extend = flags == NSEventModifierFlagShift &&
        (key == kVK_UpArrow || key == kVK_DownArrow || horizontalArrow);
    if (!results.actionsSuspended && results.rows.count && (!flags || extend)) {
        BOOL downFromSearch = searchFocused && !composing && key == kVK_DownArrow;
        BOOL horizontalFromSearch = horizontalArrow && emptySearch && !preview;
        BOOL previous = key == kVK_UpArrow || (horizontalArrow && key == kVK_LeftArrow);
        BOOL next = key == kVK_DownArrow || (horizontalArrow && key == kVK_RightArrow);
        BOOL extendFromSearch = extend && emptySearch;
        if ((!flags && (downFromSearch || horizontalFromSearch)) || extendFromSearch ||
            (resultFocused && (previous || next))) {
            if (searchFocused && ![window makeFirstResponder:results]) return event;
            NSInteger index = Clamp(results.selected + (previous ? -1 : 1),0,(NSInteger)results.rows.count-1);
            [self pick:index in:results action:extend ? OCResultExtendSelection : OCResultSelect];
            return nil;
        }
    }
    return event;
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action value:(id)value {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = value;
    return item;
}

- (void)actions:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:OCText(@"Tindakan", @"Actions")];
    for (NSInteger i = 0; i < self.tabs.tabCount; i++) {
        NSString *title = i == 0 ? OCText(@"Riwayat", @"History") : self.collections[(NSUInteger)i-1][@"name"];
        NSMenuItem *tab = [self item:title action:@selector(navigateMenu:) value:@(i)];
        if (i < 9) tab.keyEquivalent = [NSString stringWithFormat:@"%ld",(long)i+1];
        tab.state = i == self.tabs.selectedIndex ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:tab];
    }
    [menu addItem:[self item:OCText(@"Tambah koleksi…", @"Add Collection…") action:@selector(createCollection:) value:nil]];
    NSDictionary *activeCollection = [self collectionRowForID:self.activeTab];
    if (activeCollection) {
        NSString *title = OCText(@"Tindakan koleksi", @"Collection Actions");
        NSMenuItem *collectionActions = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        collectionActions.submenu = [[NSMenu alloc] initWithTitle:title];
        [self addCollectionActionsFor:activeCollection toMenu:collectionActions.submenu];
        [menu addItem:collectionActions];
    }

    [menu addItem:NSMenuItem.separatorItem];
    NSDictionary *row = [self selectedIn:self.activeResults];
    if (row) {
        NSMenuItem *clipActions = [[NSMenuItem alloc] initWithTitle:OCText(@"Tindakan klip", @"Clip Actions") action:nil keyEquivalent:@""];
        clipActions.submenu = [self contextFor:row];
        [menu addItem:clipActions];
    }
    [menu addItem:[self item:OCText(@"Bersihkan riwayat…", @"Clear History…") action:@selector(clearHistory:) value:nil]];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:OCText(@"Pengaturan…", @"Settings…") action:@selector(settings:) value:nil]];
    [menu addItem:[self item:OCText(@"Tentang OpenClipboard", @"About OpenClipboard") action:@selector(showAbout:) value:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:OCText(@"Keluar", @"Quit") action:@selector(quitApp:) value:nil]];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,0) inView:sender];
}

- (void)settings:(id)sender { if (self.openSettings) self.openSettings(); }
- (void)showAbout:(id)sender {
    [self dismissRestoringFocus:NO];
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
    [NSApp orderFrontStandardAboutPanel:sender];
}
- (void)quitApp:(id)sender {
    [self dismissRestoringFocus:NO];
    if (self.quit) self.quit();
}
- (void)clearHistory:(id)sender {
    [self clearPreview];
    OCConfirmClearHistory(self.activePanel,NO,^{ [self sendAction:@{@"action":@"clear",@"all":@NO}]; });
}
- (void)navigateMenu:(NSMenuItem *)sender { [self selectTabAtIndex:[sender.representedObject integerValue]]; }

- (void)createCollection:(id)sender {
    [self clearPreview];
    [self.tabs beginEditingCollectionID:0];
}

- (void)renameCollection:(NSMenuItem *)sender {
    [self clearPreview];
    [self.tabs beginEditingCollectionID:[sender.representedObject[@"id"] longLongValue]];
}

- (void)deleteCollection:(NSMenuItem *)sender {
    NSDictionary *collection = sender.representedObject;
    NSPanel *panel = self.activePanel;
    if (!collection || !panel || panel.attachedSheet) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = OCText(@"Hapus koleksi?", @"Delete collection?");
    alert.informativeText = [NSString stringWithFormat:OCText(@"Klip dari “%@” tetap ada di Riwayat.", @"Clips from “%@” are kept in History."), collection[@"title"]];
    NSButton *cancel = [alert addButtonWithTitle:OCText(@"Batal", @"Cancel")];
    cancel.keyEquivalent = @"\e";
    [alert addButtonWithTitle:OCText(@"Hapus koleksi", @"Delete Collection")].hasDestructiveAction = YES;
    [alert beginSheetModalForWindow:panel completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) {
            if ([collection[@"id"] longLongValue] == self.activeTab) [self selectTab:0];
            [self sendAction:@{@"action":@"delete_collection",@"id":collection[@"id"]}];
        }
    }];
}

- (void)addCollectionActionsFor:(NSDictionary *)row toMenu:(NSMenu *)menu {
    [menu addItem:[self item:OCText(@"Ubah nama…", @"Rename…") action:@selector(renameCollection:) value:row]];
    NSMenu *colors = [[NSMenu alloc] initWithTitle:OCText(@"Warna", @"Color")];
    NSNumber *identifier = row[@"id"];
    NSString *current = row[@"color"] ?: @"";
    NSMutableArray<NSDictionary *> *choices = [NSMutableArray arrayWithObject:@{@"key":@"",@"title":OCText(@"Otomatis", @"Automatic")}];
    [choices addObjectsFromArray:OCTabPalette()];
    for (NSDictionary *choice in choices) {
        NSMenuItem *item = [self item:choice[@"title"] action:@selector(runMenuAction:)
            value:@{@"action":@"set_collection_color",@"id":identifier,@"color":choice[@"key"]}];
        SetCollectionColorDot(item,choice[@"key"],identifier.longLongValue);
        item.state = [choice[@"key"] isEqualToString:current] ? NSControlStateValueOn : NSControlStateValueOff;
        [colors addItem:item];
    }
    NSMenuItem *colorItem = [[NSMenuItem alloc] initWithTitle:OCText(@"Warna", @"Color") action:nil keyEquivalent:@""];
    colorItem.submenu = colors;
    [menu addItem:colorItem];
    [menu addItem:[self item:OCText(@"Hapus koleksi…", @"Delete Collection…") action:@selector(deleteCollection:) value:row]];
}

- (NSMenu *)contextFor:(NSDictionary *)row {
    if ([row[@"kind"] isEqualToString:@"koleksi"]) {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:OCText(@"Tindakan koleksi", @"Collection Actions")];
        [self addCollectionActionsFor:row toMenu:menu];
        return menu;
    }
    NSNumber *identifier = row[@"id"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:OCText(@"Tindakan klip", @"Clip Actions")];
    BOOL pinned = [row[@"pinned"] boolValue];
    [menu addItem:[self item:pinned ? OCText(@"Lepas sematan", @"Unpin") : OCText(@"Sematkan", @"Pin")
        action:@selector(runMenuAction:) value:@{@"action":@"pin",@"id":identifier,@"pinned":(pinned ? @NO : @YES)}]];
    [menu addItem:[self item:OCText(@"Pratinjau", @"Preview") action:@selector(previewMenu:) value:nil]];

    if (self.collections.count) {
        NSMenu *collections = [[NSMenu alloc] initWithTitle:OCText(@"Koleksi", @"Collections")];
        for (NSDictionary *collection in self.collections) {
            NSNumber *collectionID = collection[@"id"];
            BOOL member = [row[@"collections"] containsObject:collectionID];
            NSMenuItem *choice = [self item:collection[@"name"] action:@selector(runMenuAction:)
                value:@{@"action":@"membership",@"id":identifier,@"collection":collectionID,@"add":(member ? @NO : @YES)}];
            SetCollectionColorDot(choice,collection[@"color"],collectionID.longLongValue);
            choice.state = member ? NSControlStateValueOn : NSControlStateValueOff;
            [collections addItem:choice];
        }
        NSMenuItem *assigned = [[NSMenuItem alloc] initWithTitle:OCText(@"Tambahkan ke koleksi", @"Add to Collection") action:nil keyEquivalent:@""];
        assigned.submenu = collections;
        [menu addItem:assigned];
    }
    if (self.activeTab) {
        [menu addItem:[self item:OCText(@"Keluarkan dari koleksi", @"Remove from Collection") action:@selector(runMenuAction:)
            value:@{@"action":@"membership",@"id":identifier,@"collection":@(self.activeTab),@"add":@NO}]];
    }
    return menu;
}

- (void)showClipActions {
    OCResults *results = self.activeResults;
    NSDictionary *row = [self selectedIn:results];
    if (!row) return;
    NSRect rect = [results rowFrame:results.selected];
    [[self contextFor:row] popUpMenuPositioningItem:nil
        atLocation:NSMakePoint(NSMinX(rect)+12, NSMaxY(rect)) inView:results];
}

- (void)previewMenu:(id)sender { [self useSelected:OCPreview]; }

- (void)runMenuAction:(NSMenuItem *)sender {
    [self clearPreview];
    [self sendAction:sender.representedObject];
}

- (void)deleteSelected {
    OCResults *results = self.activeResults;
    if (!results.selectedIndexes.count) return;
    NSMutableArray<NSNumber *> *identifiers = [NSMutableArray arrayWithCapacity:results.selectedIndexes.count];
    [results.selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger index, __unused BOOL *stop) {
        if (index < results.rows.count) [identifiers addObject:results.rows[index][@"id"]];
    }];
    if (!identifiers.count) return;
    [self clearPreview];
    [self sendAction:@{@"action":@"delete_many",@"ids":identifiers}];
}
@end
