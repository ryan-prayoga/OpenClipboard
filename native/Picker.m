#import "Native.h"
#import "AccessibilityGuide.h"
#import "Results.h"
#import "Toolbar.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

static const CGFloat CompactPanelInset = 14;
static const CGFloat SearchFieldInset = 33;
static const CGFloat SearchTextInset = 2;

static CGFloat Clamp(CGFloat value, CGFloat low, CGFloat high) {
    return MAX(low, MIN(value, high));
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

        // Sample the other windows behind the panel before applying the clear glass treatment.
        NSRect materialFrame = NSInsetRect(bounds,2,2);
        NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] initWithFrame:materialFrame];
        backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        backdrop.material = NSVisualEffectMaterialPopover;
        backdrop.state = NSVisualEffectStateActive;
        backdrop.maskImage = GlassMask(materialFrame.size, radius - 2);
        [root addSubview:backdrop];

        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:bounds];
        glass.style = NSGlassEffectViewStyleClear;
        glass.cornerRadius = radius;
        glass.effectIsInteractive = YES;
        NSView *content = [[NSView alloc] initWithFrame:bounds];
        glass.contentView = content;
        [root addSubview:glass];
        panel.contentView = root;
        panel.surfaceContent = content;
    }
    return panel;
}

static NSView *PanelContent(NSPanel *panel) {
    return ((OCPanel *)panel).surfaceContent;
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
@property(nonatomic, strong) NSPanel *side;
@property(nonatomic, strong) NSRunningApplication *origin;
@property(nonatomic, strong) NSSearchField *search;
@property(nonatomic, strong) NSSearchField *sideSearch;
@property(nonatomic, strong) NSButton *navigation;
@property(nonatomic, strong) NSButton *action;
@property(nonatomic, strong) NSButton *addCollection;
@property(nonatomic, strong) NSButton *backButton;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSTextField *sideStatus;
@property(nonatomic, strong) NSTextField *shortcutHints;
@property(nonatomic, strong) NSButton *undoButton;
@property(nonatomic, strong) NSButton *sideUndoButton;
@property(nonatomic) uint64_t undoTicket;
@property(nonatomic) BOOL undoPending;
@property(nonatomic, copy) NSString *undoMessage;
@property(nonatomic, copy) NSString *collectionName;
@property(nonatomic, strong) OCResults *results;
@property(nonatomic, strong) OCResults *sideResults;
@property(nonatomic, strong) NSScrollView *scroll;
@property(nonatomic, strong) NSScrollView *sideScroll;
@property(nonatomic, strong) NSPopover *preview;
@property(nonatomic, strong) id keyMonitor;
@property(nonatomic, strong) id mouseMonitor;
@property(nonatomic, strong) id appMouseMonitor;
@property(nonatomic, strong) id resignObserver;
@property(nonatomic, strong) id workspaceObserver;
@property(nonatomic, strong) id scrollObserver;
@property(nonatomic, strong) id sideScrollObserver;
@property(nonatomic, copy) NSArray<NSDictionary *> *collections;
@property(nonatomic, copy) NSArray<NSDictionary *> *clips;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *images;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *requested;
@property(nonatomic) BOOL bottom;
@property(nonatomic) BOOL browsing;
@property(nonatomic) BOOL inlineCollection;
@property(nonatomic) int64_t collection;
@property(nonatomic) NSInteger collectionRow;
@property(nonatomic) uint64_t catalogTicket;
@property(nonatomic) NSTimeInterval searchStarted;
@property(nonatomic) uint64_t payloadTicket;
@property(nonatomic) uint64_t panelToken;
@property(nonatomic) int64_t revealed;
@property(nonatomic) OCPayloadMode payloadMode;
@property(nonatomic) BOOL didOfferAccessibilityGuide;
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
    self.browsing = NO;
    self.inlineCollection = NO;
    self.collection = 0;
    self.collectionName = nil;
    self.collectionRow = -1;
    self.clips = @[];
    self.revealed = 0;
    self.payloadMode = OCIdle;
    self.searchStarted = 0;
    [self.images removeAllObjects];
    [self.requested removeAllObjects];

    self.origin = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSPoint pointer = NSEvent.mouseLocation;
    NSRect caret = NSZeroRect;
    BOOL hasCaret = !bottom && OCGetCaret(self.origin.processIdentifier,&caret);
    NSPoint anchor = hasCaret ? caret.origin : pointer;
    NSScreen *screen = ScreenAt(anchor);
    NSRect room = NSInsetRect(screen.visibleFrame, bottom ? 0 : 12, bottom ? 17 : 12);
    if (bottom) {
        room.origin.x = NSMinX(screen.frame);
        room.size.width = NSWidth(screen.frame);
    }
    CGFloat width = bottom ? NSWidth(room) : MIN(432, NSWidth(room));
    CGFloat targetHeight = bottom ? (width >= 710 ? 328 : 372) : 380;
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
        height = MIN(height,MAX(140,placeBelow ? below : above));
        y = Clamp(placeBelow ? anchor.y-gap-height : upperEdge,NSMinY(room),NSMaxY(room)-height);
    }

    self.panel = MakePanel(NSMakeRect(x,y,width,height), @"Riwayat OpenClipboard");
    [self buildMain:PanelContent(self.panel)];
    [self installMonitors];
    [self.panel makeKeyAndOrderFront:nil];
    if ([self.panel makeFirstResponder:self.results]) ReportMetric("open", self.bottom, started);
    [self fetchCatalog];
}

- (void)buildMain:(NSView *)view {
    CGFloat w = view.bounds.size.width, h = view.bounds.size.height;
    CGFloat edge = self.bottom ? 20 : CompactPanelInset;
    CGFloat control = OCToolbarHeight, gap = 8;
    CGFloat barY = h - edge - control;
    CGFloat buttonX = w - edge - control;
    self.search = [self makeSearch:NSMakeRect(edge,barY,160,control) view:view];
    self.action = OCToolbarIcon(NSMakeRect(buttonX,barY,control,control), view,
        @"ellipsis", @"Tindakan", self, @selector(actions:));
    self.addCollection = OCToolbarIcon(NSMakeRect(buttonX-gap-control,barY,control,control), view,
        @"plus", @"Tambah koleksi", self, @selector(createCollection:));
    [self makeNavigationInView:view frame:NSMakeRect(edge,barY,95,control)];

    CGFloat footerY = self.bottom ? 15 : 11;
    CGFloat resultsBottom = footerY + 25;
    CGFloat resultsTop = barY - 10;
    self.scroll = [self makeScroll:NSMakeRect(edge-2,resultsBottom,w-2*(edge-2),
        MAX(35,resultsTop-resultsBottom)) inView:view horizontal:self.bottom];
    self.results = (OCResults *)self.scroll.documentView;

    CGFloat hintsWidth = w >= 370 ? 226 : 0;
    self.status = OCLabel(self.recordingStatus ?: @"", 11, NSFontWeightMedium);
    self.status.textColor = NSColor.secondaryLabelColor;
    self.status.frame = NSMakeRect(edge+2,footerY,w-2*edge-hintsWidth-8,16);
    [view addSubview:self.status];

    self.shortcutHints = nil;
    if (hintsWidth) {
        self.shortcutHints = OCLabel(@"",11,NSFontWeightMedium);
        self.shortcutHints.textColor = NSColor.secondaryLabelColor;
        self.shortcutHints.alignment = NSTextAlignmentRight;
        self.shortcutHints.frame = NSMakeRect(w-edge-hintsWidth,footerY,hintsWidth,16);
        [view addSubview:self.shortcutHints];
    }

    self.undoButton = [self makeUndoButtonIn:view right:w-edge y:footerY-4];
    [self refreshUndoControls];
    [self setMessage:self.recordingStatus];
    __weak OCPicker *weakSelf = self;
    self.results.picked = ^(NSInteger index, OCResultAction action) {
        [weakSelf pick:index in:weakSelf.results action:action];
    };
    self.results.contextMenu = ^NSMenu *(NSInteger index) {
        OCPicker *picker = weakSelf;
        return picker ? [picker contextFor:picker.results.rows[(NSUInteger)index]] : nil;
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
    search.placeholderString = @"Cari klip";
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
    [clear setAccessibilityLabel:@"Hapus pencarian"];
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
    scroll.hasVerticalScroller = !horizontal;
    scroll.hasHorizontalScroller = horizontal;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    OCResults *canvas = [[OCResults alloc] initWithFrame:NSMakeRect(0,0,NSWidth(rect),NSHeight(rect))];
    canvas.horizontal = horizontal;
    canvas.images = self.images;
    scroll.documentView = canvas;
    [view addSubview:scroll];
    return scroll;
}

- (OCResults *)activeResults { return self.side ? self.sideResults : self.results; }
- (NSSearchField *)activeSearch { return self.side ? self.sideSearch : self.search; }
- (NSPanel *)activePanel { return self.side ?: self.panel; }

- (id)observeScroll:(NSScrollView *)scroll {
    scroll.contentView.postsBoundsChangedNotifications = YES;
    __weak OCPicker *weakSelf = self;
    return [NSNotificationCenter.defaultCenter addObserverForName:NSViewBoundsDidChangeNotification
        object:scroll.contentView queue:nil usingBlock:^(__unused NSNotification *note) { [weakSelf loadVisibleImages]; }];
}

- (void)removeSideScrollObserver {
    if (self.sideScrollObserver) [NSNotificationCenter.defaultCenter removeObserver:self.sideScrollObserver];
    self.sideScrollObserver = nil;
}

- (void)installMonitors {
    __weak OCPicker *weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) { return [weakSelf handleKey:event]; }];
    NSEventMask click = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    self.mouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:click handler:^(__unused NSEvent *event) {
        [weakSelf dismissRestoringFocus:NO];
    }];
    self.appMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:click | NSEventMaskLeftMouseUp
        handler:^NSEvent *(NSEvent *event) {
        OCPicker *picker = weakSelf;
        if (!picker) return event;
        if ([event.window.title isEqualToString:@"Pengaturan OpenClipboard"] && event.type != NSEventTypeLeftMouseUp) {
            [picker dismissRestoringFocus:NO];
            return event;
        }
        if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseUp) return event;
        OCResults *results = event.window == picker.panel ? picker.results
            : event.window == picker.side ? picker.sideResults : nil;
        if (![results containsPickerClick:event]) return event;
        if (event.type == NSEventTypeLeftMouseDown) [results mouseDown:event];
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
    if (!self.panel) return;
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
    [self removeSideScrollObserver];
    [self clearPreview];
    NSRunningApplication *origin = self.origin;
    [self.side orderOut:nil];
    [self.panel orderOut:nil];
    self.side = nil;
    self.backButton = nil;
    self.panel = nil;
    self.origin = nil;
    self.panelToken++;
    self.catalogTicket++;
    self.results = nil;
    self.sideResults = nil;
    self.undoButton = nil;
    self.sideUndoButton = nil;
    [self.images removeAllObjects];
    [self.requested removeAllObjects];
    if (restore && NSApp.isActive && origin && !origin.terminated &&
        origin.processIdentifier != NSProcessInfo.processInfo.processIdentifier &&
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != origin.processIdentifier) {
        [NSApp yieldActivationToApplication:origin];
        [origin activateWithOptions:0];
    }
}

- (void)fetchCatalog {
    if (!self.panel || (self.browsing && !self.collection)) {
        if (self.panel) OCSend(@{@"action":@"catalog", @"ticket":@(++self.catalogTicket),
            @"query":@"", @"kind":@"", @"collection":@0});
        return;
    }
    uint64_t ticket = self.catalogTicket + 1;
    if (OCSend(@{@"action":@"catalog", @"ticket":@(ticket),
        @"query":self.activeSearch.stringValue ?: @"", @"kind":@"", @"collection":@(self.collection)})) {
        self.catalogTicket = ticket;
    } else {
        [self setMessage:@"Riwayat sedang sibuk. Coba lagi."];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.activeSearch) return;
    [(OCToolbarSearchField *)notification.object refreshClearButton];
    if (self.browsing && !self.collection) {
        [self renderCollections];
        return;
    }
    [self clearPreview];
    self.activeResults.selected = -1;
    self.searchStarted = NSProcessInfo.processInfo.systemUptime;
    [self fetchCatalog];
}

- (void)receiveEvent:(NSDictionary *)event {
    NSString *kind = event[@"kind"];
    if ([kind isEqualToString:@"deleted"]) {
        self.undoTicket = [event[@"ticket"] unsignedLongLongValue];
        self.undoPending = NO;
        NSUInteger count = [event[@"count"] unsignedIntegerValue];
        self.undoMessage = [NSString stringWithFormat:@"%lu klip dihapus.",(unsigned long)count];
        [self refreshUndoControls];
        [self setMessage:self.recordingStatus];
        return;
    }
    if ([kind isEqualToString:@"undo_expired"] || [kind isEqualToString:@"delete_undone"]) {
        if ([event[@"ticket"] unsignedLongLongValue] != self.undoTicket) return;
        self.undoTicket = 0;
        self.undoPending = NO;
        self.undoMessage = nil;
        [self refreshUndoControls];
        [self setMessage:[kind isEqualToString:@"delete_undone"] ? @"Klip dipulihkan." : self.recordingStatus];
        return;
    }
    if ([kind isEqualToString:@"undo_failed"]) {
        if ([event[@"ticket"] unsignedLongLongValue] != self.undoTicket) return;
        self.undoPending = NO;
        [self refreshUndoControls];
        [self setMessage:[event[@"reason"] isEqualToString:@"undo_full"]
            ? @"Batas riwayat tercapai." : @"Klip belum dipulihkan."];
        return;
    }
    if (!self.panel) return;
    if ([kind isEqualToString:@"changed"]) {
        [self fetchCatalog];
    } else if ([kind isEqualToString:@"created"]) {
        [self setMessage:@"Koleksi dibuat."];
        [self fetchCatalog];
    } else if ([kind isEqualToString:@"error"]) {
        NSString *reason = event[@"reason"];
        self.payloadMode = OCIdle;
        NSString *description = @{@"full":@"Ruang penyimpanan tidak cukup.",
            @"missing":@"Klip ini sudah tidak tersedia.", @"collection_name":@"Nama koleksi kosong, terlalu panjang, atau sudah dipakai.",
            @"collection_missing":@"Koleksi sudah tidak tersedia.",
            @"not_manually_sensitive":@"Klip ini ditandai oleh deteksi otomatis."}[reason];
        [self setMessage:description ?: @"Tindakan gagal. Coba lagi."];
    } else if ([kind isEqualToString:@"catalog"] && [event[@"ticket"] unsignedLongLongValue] == self.catalogTicket) {
        NSDictionary *catalog = event[@"catalog"];
        NSArray *nextCollections = catalog[@"collections"] ?: @[];
        self.collections = nextCollections;
        if (self.browsing && !self.collection) {
            [self renderCollections];
            return;
        }
        self.clips = catalog[@"clips"] ?: @[];
        for (NSDictionary *clip in self.clips) {
            if ([clip[@"sensitive"] boolValue]) {
                [self.images removeObjectForKey:clip[@"id"]];
                [self.requested removeObject:clip[@"id"]];
            }
        }
        OCResults *result = self.activeResults;
        BOOL query = self.activeSearch.stringValue.length > 0;
        NSString *title = query ? @"Tidak ada hasil" : self.collection ? @"Koleksi masih kosong" : @"Belum ada klip";
        NSString *detail = nil;
        if (!query && !self.collection) {
            detail = self.shortcutLabel.length
                ? [NSString stringWithFormat:@"Salin teks atau gambar, lalu tekan %@.",self.shortcutLabel]
                : @"Salin teks atau gambar untuk mulai mengisi riwayat.";
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
    [result replaceRowsPreservingSelection:rows];
    NSInteger index = result.selected;
    if (self.revealed && ![previous isEqual:(index < 0 ? nil : rows[(NSUInteger)index][@"id"])]) {
        [self clearPreview];
    }
    [self refreshSelectionHint:result];
    [result showEmptyTitle:title detail:detail announce:announce];
    [result layoutRows];
    if (index >= 0 && ![previous isEqual:rows[(NSUInteger)index][@"id"]])
        [result scrollRectToVisible:[result rowFrame:index]];
    NSAccessibilityPostNotification(result, NSAccessibilityLayoutChangedNotification);
}

- (void)refreshSelectionHint:(OCResults *)results {
    if (results != self.results) return;
    NSUInteger count = results.selectedIndexes.count;
    self.shortcutHints.stringValue = !count ? @""
        : results.collections ? @"↵ Buka koleksi"
        : count > 1 ? [NSString stringWithFormat:@"%lu klip dipilih    ⌫ Hapus",(unsigned long)count]
        : self.activePanel.firstResponder == results ? @"Spasi Pratinjau    ↵ Tempel    ⌫ Hapus"
        : @"Spasi Pratinjau    ↵ Tempel";
}

- (void)makeNavigationInView:(NSView *)view frame:(NSRect)frame {
    NSView *surface = OCToolbarSurface(frame,view);
    self.navigation = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleNavigation:)];
    self.navigation.frame = surface.bounds;
    self.navigation.bordered = NO;
    self.navigation.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    [surface addSubview:self.navigation];
    [self refreshNavigation];
}

- (void)refreshNavigation {
    BOOL inCollection = self.collection != 0;
    BOOL listing = self.browsing && !inCollection;
    BOOL namedBack = inCollection && self.inlineCollection;
    NSString *forwardTitle = self.bottom ? @"Koleksi  ⌘→" : @"Koleksi  →";
    NSString *historyTitle = self.bottom ? @"⌘←  Riwayat" : @"Riwayat";
    self.navigation.title = namedBack ? [NSString stringWithFormat:@"‹  %@",self.collectionName]
        : inCollection ? @"Kembali" : self.browsing ? historyTitle : forwardTitle;
    self.navigation.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    self.navigation.toolTip = namedBack ? [NSString stringWithFormat:@"Kembali dari %@",self.collectionName] : nil;
    [self.navigation setAccessibilityLabel:self.navigation.toolTip ?: (inCollection ? @"Kembali ke koleksi"
        : self.browsing ? @"Riwayat" : @"Koleksi")];
    NSView *navigationSurface = self.navigation.superview;
    CGFloat navigationWidth = namedBack && NSWidth(navigationSurface.superview.bounds) >= 385 ? 138 : 95;
    [navigationSurface setFrameSize:NSMakeSize(navigationWidth,OCToolbarHeight)];
    self.navigation.frame = navigationSurface.bounds;
    self.action.toolTip = listing ? @"Tindakan koleksi" : @"Tindakan";
    [self.action setAccessibilityLabel:self.action.toolTip];
    self.addCollection.superview.hidden = !listing;

    NSView *searchSurface = self.search.superview;
    NSView *nextControl = (listing ? self.addCollection : self.action).superview;
    const CGFloat gap = 8;
    NSRect frame = searchSurface.frame;
    CGFloat available = NSMinX(nextControl.frame)-NSMinX(frame)-NSWidth(navigationSurface.frame)-2*gap;
    frame.size.width = MAX(75,MIN(self.bottom ? 408 : available,available));
    searchSurface.frame = frame;
    [navigationSurface setFrameOrigin:NSMakePoint(NSMaxX(frame)+gap,NSMinY(frame))];
}

- (void)toggleNavigation:(id)sender {
    [self navigateTo:self.collection || !self.browsing ? 1 : 0];
}

- (void)navigateTo:(NSInteger)segment {
    BOOL browsing = segment == 1;
    if (self.collection) [self closeCollection];
    if (self.browsing == browsing) return;
    [self clearPreview];
    self.browsing = browsing;
    [self refreshNavigation];
    self.results.collections = browsing;
    self.search.placeholderString = browsing ? @"Cari koleksi" : @"Cari klip";
    self.results.rows = @[];
    self.results.selected = -1;
    [self.results showEmptyTitle:nil detail:nil announce:NO];
    [self.panel makeFirstResponder:browsing ? self.results : self.search];
    self.search.stringValue = @"";
    [self.results layoutRows];
    if (browsing) [self renderCollections];
    else [self fetchCatalog];
}

- (void)renderCollections {
    NSString *query = self.search.stringValue.lowercaseString;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *collection in self.collections) {
        NSString *name = collection[@"name"];
        if (!query.length || [name.lowercaseString containsString:query]) {
            [rows addObject:@{@"id":collection[@"id"],@"title":name,@"kind":@"koleksi"}];
        }
    }
    self.results.collections = YES;
    [self renderRows:rows in:self.results emptyTitle:query.length ? @"Tidak ada hasil" : @"Belum ada koleksi"
              detail:nil announce:query.length > 0];
}

- (NSDictionary *)selectedIn:(OCResults *)results {
    return results.selected >= 0 && (NSUInteger)results.selected < results.rows.count
        ? results.rows[(NSUInteger)results.selected] : nil;
}

- (void)pick:(NSInteger)index in:(OCResults *)canvas confirm:(BOOL)confirm {
    [self pick:index in:canvas action:confirm ? OCResultConfirm : OCResultSelect];
}

- (void)pick:(NSInteger)index in:(OCResults *)canvas action:(OCResultAction)action {
    if (index < 0 || (NSUInteger)index >= canvas.rows.count) return;
    if (index != canvas.selected || action == OCResultExtendSelection || action == OCResultToggleSelection)
        [self clearPreview];
    if (action == OCResultExtendSelection) [canvas extendSelectionTo:index];
    else if (action == OCResultToggleSelection) [canvas toggleSelectionAt:index];
    else canvas.selected = index;
    [self refreshSelectionHint:canvas];
    [canvas scrollRectToVisible:[canvas rowFrame:index]];
    if (action == OCResultConfirm && canvas.collections) {
        self.collectionRow = index;
        [self openCollection:canvas.rows[(NSUInteger)index]];
    } else if (action == OCResultConfirm) {
        [self useSelected:OCPaste];
    }
}

- (void)openCollection:(NSDictionary *)entry {
    if (self.collection) return;
    self.collection = [entry[@"id"] longLongValue];
    self.collectionName = entry[@"title"];
    [self refreshNavigation];
    NSRect base = self.panel.frame;
    NSRect bounds = NSInsetRect(self.panel.screen.visibleFrame,12,12);
    CGFloat width = MIN(335,NSWidth(bounds));
    CGFloat right = NSMaxX(bounds)-NSMaxX(base)-8, left = NSMinX(base)-NSMinX(bounds)-8;
    if (self.bottom || (right < width && left < width)) {
        self.inlineCollection = YES;
        [self refreshNavigation];
        self.results.collections = NO;
        self.search.stringValue = @"";
        self.search.placeholderString = [NSString stringWithFormat:@"Cari di %@",self.collectionName];
        self.results.rows = @[];
        self.results.selected = -1;
        [self.results showEmptyTitle:nil detail:nil announce:NO];
        [self.results layoutRows];
        [self.panel makeFirstResponder:self.results];
        [self fetchCatalog];
        return;
    }
    CGFloat height = MIN(340,NSHeight(bounds));
    NSRect row = [self.panel convertRectToScreen:[self.results convertRect:[self.results rowFrame:self.collectionRow] toView:nil]];
    CGFloat y = Clamp(NSMaxY(row)-height+42,NSMinY(bounds),NSMaxY(bounds)-height);
    CGFloat x = right >= width ? NSMaxX(base)+8 : NSMinX(base)-width-8;
    self.side = MakePanel(NSMakeRect(x,y,width,height), entry[@"title"]);
    NSView *view = PanelContent(self.side);
    self.backButton = OCToolbarIcon(NSMakeRect(14,height-46,36,36), view,
        @"chevron.left", @"Kembali ke koleksi", self, @selector(backToCollections:));
    NSTextField *title = OCLabel(entry[@"title"],14,NSFontWeightSemibold);
    title.frame = NSMakeRect(58,height-38,width-72,20);
    [view addSubview:title];
    self.sideSearch = [self makeSearch:NSMakeRect(14,height-90,width-28,OCToolbarHeight) view:view];
    self.sideScroll = [self makeScroll:NSMakeRect(10,26,width-20,height-123) inView:view horizontal:NO];
    self.sideResults = (OCResults *)self.sideScroll.documentView;
    self.sideScrollObserver = [self observeScroll:self.sideScroll];
    self.sideStatus = OCLabel(@"",11,NSFontWeightRegular);
    self.sideStatus.textColor = NSColor.secondaryLabelColor;
    self.sideStatus.frame = NSMakeRect(15,6,width-118,17);
    [view addSubview:self.sideStatus];
    self.sideUndoButton = [self makeUndoButtonIn:view right:width-14 y:2];
    [self refreshUndoControls];
    [self setMessage:self.recordingStatus];
    __weak OCPicker *weakSelf = self;
    self.sideResults.picked = ^(NSInteger index, OCResultAction action) {
        [weakSelf pick:index in:weakSelf.sideResults action:action];
    };
    self.sideResults.contextMenu = ^NSMenu *(NSInteger index) {
        OCPicker *picker = weakSelf;
        return picker ? [picker contextFor:picker.sideResults.rows[(NSUInteger)index]] : nil;
    };
    [self.side makeKeyAndOrderFront:nil];
    [self.side makeFirstResponder:self.sideResults];
    [self fetchCatalog];
}

- (void)backToCollections:(id)sender { [self closeCollection]; }

- (void)closeCollection {
    if (!self.collection) return;
    [self clearPreview];
    BOOL wasInline = self.inlineCollection;
    self.inlineCollection = NO;
    self.collection = 0;
    self.collectionName = nil;
    [self refreshNavigation];
    [self removeSideScrollObserver];
    [self.side orderOut:nil];
    self.side = nil;
    self.backButton = nil;
    self.sideStatus = nil;
    self.sideUndoButton = nil;
    self.sideResults = nil;
    [self setMessage:self.recordingStatus];
    if (wasInline) {
        self.search.stringValue = @"";
        self.search.placeholderString = @"Cari koleksi";
        self.results.selected = -1;
    }
    if (self.browsing) {
        [self renderCollections];
        [self pick:self.collectionRow in:self.results confirm:NO];
    }
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.results];
    self.catalogTicket++;
}

- (NSButton *)makeUndoButtonIn:(NSView *)view right:(CGFloat)right y:(CGFloat)y {
    NSButton *button = [NSButton buttonWithTitle:@"Urungkan" target:self action:@selector(undoDelete:)];
    button.frame = NSMakeRect(right-88,y,88,24);
    button.controlSize = NSControlSizeSmall;
    button.toolTip = @"Pulihkan klip yang baru dihapus (⌘Z saat fokus di hasil)";
    [view addSubview:button];
    return button;
}

- (void)refreshUndoControls {
    BOOL available = self.undoTicket != 0;
    NSButton *buttons[] = {self.undoButton,self.sideUndoButton};
    for (NSUInteger i = 0; i < 2; i++) {
        NSButton *button = buttons[i];
        if (!available && button.window.firstResponder == button)
            [button.window makeFirstResponder:self.activeResults.rows.count ? self.activeResults : self.activeSearch];
        button.hidden = !available;
        button.enabled = !self.undoPending;
    }
    self.shortcutHints.hidden = available;
}

- (void)undoDelete:(id)sender {
    if (!self.undoTicket || self.undoPending) return;
    self.undoPending = OCSend(@{@"action":@"undo_delete",@"ticket":@(self.undoTicket)});
    if (!self.undoPending) [self setMessage:@"Riwayat sedang sibuk. Coba lagi."];
    [self refreshUndoControls];
}

- (void)setMessage:(NSString *)message {
    (self.side ? self.sideStatus : self.status).stringValue = message.length ? message : self.undoMessage ?: @"";
}

- (void)sendAction:(NSDictionary *)request {
    if (!OCSend(request)) [self setMessage:@"Riwayat sedang sibuk. Coba lagi."];
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
                self.activeResults.needsDisplay = YES;
            }
            break;
        }
    }
}

- (void)useSelected:(OCPayloadMode)mode {
    OCResults *canvas = self.activeResults;
    NSDictionary *row = [self selectedIn:canvas];
    if (!row || canvas.collections) return;
    int64_t identifier = [row[@"id"] longLongValue];
    if (mode == OCPaste) {
        if ([row[@"sensitive"] boolValue] && self.revealed != identifier) {
            [self setMessage:@"Tekan Spasi untuk membuka item sensitif."];
            return;
        }
        if (![self canPasteToOrigin]) return;
        if (!CGPreflightPostEventAccess()) {
            BOOL hasAccessibility = OCAccessibilityReady();
            [self setMessage:hasAccessibility ? @"macOS belum mengizinkan tempel langsung."
                                               : @"Buka panduan Accessibility dari menu ⋯."];
            if (!hasAccessibility && !self.didOfferAccessibilityGuide && self.openAccessibilityGuide) {
                self.didOfferAccessibilityGuide = YES;
                self.openAccessibilityGuide();
            }
            return;
        }
    }
    self.payloadMode = mode;
    uint64_t ticket = ++self.payloadTicket;
    if (!OCSend(@{@"action":@"payload",@"id":@(identifier),@"ticket":@(ticket)})) {
        self.payloadMode = OCIdle;
        [self setMessage:@"Riwayat sedang sibuk. Coba lagi."];
    }
}

- (void)receivePayload:(NSArray<NSDictionary *> *)parts ticket:(uint64_t)ticket
                    id:(int64_t)clip sensitive:(BOOL)sensitive {
    if (!self.panel || self.payloadMode == OCIdle || ticket != self.payloadTicket ||
        [[self selectedIn:self.activeResults][@"id"] longLongValue] != clip) return;
    OCPayloadMode mode = self.payloadMode;
    self.payloadMode = OCIdle;
    if (mode == OCPaste) {
        if (sensitive && self.revealed != clip) return;
        if (![self canPasteToOrigin]) return;
        if (!CGPreflightPostEventAccess()) {
            [self setMessage:OCAccessibilityReady() ? @"macOS belum mengizinkan tempel langsung."
                                                  : @"Buka panduan Accessibility dari menu ⋯."];
            return;
        }
        NSInteger version;
        if (!OCWriteClipboard(parts,sensitive,&version)) {
            [self setMessage:@"Klip gagal disiapkan untuk ditempel."];
            return;
        }
        NSRunningApplication *destination = self.origin;
        if (self.didWriteClipboard) self.didWriteClipboard();
        [self dismissRestoringFocus:YES];
        uint64_t token = self.panelToken;
        // Let the original window regain the key focus before dispatching the paste.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pasteTo:destination clip:clip version:version token:token retries:4];
        });
        return;
    }
    [self showPreview:parts sensitive:sensitive id:clip];
}

- (BOOL)canPasteToOrigin {
    pid_t own = NSProcessInfo.processInfo.processIdentifier;
    NSRunningApplication *origin = self.origin;
    if (!origin || origin.terminated || origin.processIdentifier == own) {
        [self setMessage:@"Buka panel dari aplikasi tujuan tempel."];
        return NO;
    }
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (front == origin.processIdentifier || front == own) return YES;
    [self setMessage:@"Aplikasi tujuan sudah berganti."];
    return NO;
}

- (void)pasteTo:(NSRunningApplication *)destination clip:(int64_t)clip version:(NSInteger)version
          token:(uint64_t)token retries:(NSUInteger)retries {
    if (token != self.panelToken || destination.terminated) return;
    pid_t target = destination.processIdentifier;
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (front == target) {
        if (OCPostPaste(target,version) && !OCSend(@{@"action":@"pasted",@"id":@(clip)}))
            NSLog(@"OpenClipboard could not update the pasted clip's position in history.");
    } else if (front == NSProcessInfo.processInfo.processIdentifier && retries) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self pasteTo:destination clip:clip version:version token:token retries:retries-1];
        });
    }
}

- (void)showPreview:(NSArray<NSDictionary *> *)parts sensitive:(BOOL)sensitive id:(int64_t)clip {
    [self clearPreview];
    NSRect available = (self.activePanel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = NSMakeSize(floor(MIN(640, NSWidth(available) * 0.72)),
                             floor(MIN(460, NSHeight(available) * 0.55)));
    NSRect body = NSMakeRect(16,14,size.width-32,size.height-54);
    NSViewController *controller = [NSViewController new];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,size.width,size.height)];
    controller.view = view;
    NSTextField *title = OCLabel(sensitive ? @"Item sensitif" : @"Pratinjau",13,NSFontWeightSemibold);
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
        preview.selectable = NO;
        preview.drawsBackground = NO;
        preview.font = ([kind isEqualToString:@"json"] || [kind isEqualToString:@"kode"])
            ? [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular] : [NSFont systemFontOfSize:13];
        scroll.drawsBackground = NO;
        [view addSubview:scroll];
    }
    self.preview = [NSPopover new];
    self.preview.animates = NO;
    self.preview.behavior = NSPopoverBehaviorTransient;
    self.preview.delegate = self;
    self.preview.contentViewController = controller;
    self.preview.contentSize = size;
    if (sensitive) {
        self.revealed = clip;
        [self setMessage:@"Item sensitif terbuka. Enter menempelkan klip."];
    }
    OCResults *results = self.activeResults;
    [self.preview showRelativeToRect:[results rowFrame:results.selected] ofView:results
                      preferredEdge:self.bottom ? NSRectEdgeMaxY : NSRectEdgeMaxX];
}

- (void)clearPreview {
    if (self.revealed) [self setMessage:self.recordingStatus];
    self.payloadTicket++;
    self.payloadMode = OCIdle;
    self.revealed = 0;
    self.preview.delegate = nil;
    [self.preview close];
    self.preview = nil;
}

- (void)popoverDidClose:(NSNotification *)notification {
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
    if (!self.panel || (event.window != self.panel && event.window != self.side && event.window != previewWindow)) return event;
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
    BOOL horizontalArrow = results.horizontal && (key == kVK_LeftArrow || key == kVK_RightArrow);
    NSButton *undoButton = self.side ? self.sideUndoButton : self.undoButton;

    if (flags == NSEventModifierFlagCommand && key == kVK_ANSI_Z && resultFocused && self.undoTicket) {
        if (!event.isARepeat) [self undoDelete:nil];
        return nil;
    }
    if (flags == NSEventModifierFlagCommand && (key == kVK_ANSI_1 || key == kVK_ANSI_2)) {
        if (!event.isARepeat) [self navigateTo:key == kVK_ANSI_1 ? 0 : 1];
        return nil;
    }
    if (flags == NSEventModifierFlagCommand && horizontalArrow && !composing) {
        if (event.isARepeat) return nil;
        if (key == kVK_LeftArrow) {
            if (self.collection) [self closeCollection];
            else if (self.browsing) [self navigateTo:0];
        } else if (!self.browsing) {
            [self navigateTo:1];
        } else if (results.collections) {
            [self pick:results.selected in:results confirm:YES];
        }
        return nil;
    }
    if (resultFocused && !preview && event.window == window &&
        !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
        [self focusSearchForTyping:event inWindow:window field:search]) {
        [self refreshSelectionHint:results];
        return event;
    }
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return event;

    if (!flags && (key == kVK_Delete || key == kVK_ForwardDelete) &&
        !results.collections && resultFocused && !preview) {
        if (!event.isARepeat) [self deleteSelected];
        return nil;
    }
    if (!flags && key == kVK_Space && !results.collections &&
        (preview || ((resultFocused || emptySearch) && results.selected >= 0))) {
        if (!event.isARepeat) {
            if (preview) [self clearPreview];
            else [self useSelected:OCPreview];
        }
        return nil;
    }
    if (key == kVK_Escape) {
        if (preview) [self clearPreview];
        else if (self.collection) [self closeCollection];
        else if (self.browsing) [self navigateTo:0];
        else [self dismissRestoringFocus:YES];
        return nil;
    }
    if (key == kVK_Tab) {
        NSMutableArray<NSView *> *order = [NSMutableArray arrayWithObject:search];
        if (results.rows.count) [order addObject:results];
        if (self.side) [order addObject:self.backButton];
        else {
            [order addObject:self.navigation];
            if (!self.addCollection.superview.hidden) [order addObject:self.addCollection];
            [order addObject:self.action];
        }
        if (undoButton && !undoButton.hidden && undoButton.enabled) [order addObject:undoButton];
        NSUInteger index = searchFocused ? 0 : [order indexOfObjectIdenticalTo:(NSView *)focused];
        if (index == NSNotFound) index = 0;
        NSInteger step = flags & NSEventModifierFlagShift ? -1 : 1;
        NSInteger next = ((NSInteger)order.count + (NSInteger)index + step) % (NSInteger)order.count;
        [window makeFirstResponder:order[(NSUInteger)next]];
        [self refreshSelectionHint:results];
        return nil;
    }
    if (key == kVK_Return || key == kVK_ANSI_KeypadEnter) {
        if (preview) { [self useSelected:OCPaste]; return nil; }
        if (focused == self.navigation || focused == self.backButton || focused == self.action ||
            focused == self.addCollection || (undoButton && focused == undoButton)) {
            [(NSButton *)focused performClick:nil];
            return nil;
        }
        if (searchFocused && composing) return event;
        if (searchFocused || resultFocused) {
            [self pick:results.selected in:results confirm:YES];
            return nil;
        }
    }
    if (!flags && key == kVK_RightArrow && !preview && !horizontalArrow) {
        NSRange selection = editor.selectedRange;
        BOOL searchAtEnd = emptySearch || (searchFocused && editor && !composing &&
            selection.length == 0 && selection.location == editor.string.length);
        if (!self.browsing && (searchAtEnd || resultFocused)) {
            if (!event.isARepeat) [self navigateTo:1];
            return nil;
        }
        if (results.collections && (resultFocused || searchAtEnd)) {
            if (!event.isARepeat) [self pick:results.selected in:results confirm:YES];
            return nil;
        }
    }
    if (resultFocused && (flags & NSEventModifierFlagShift) && key == kVK_F10) {
        [self showClipActions];
        return nil;
    }
    if (resultFocused && !flags && key == kVK_LeftArrow && !horizontalArrow) {
        if (self.collection && !self.bottom) { [self closeCollection]; return nil; }
        if (results.collections) { [self navigateTo:0]; return nil; }
    }
    BOOL extend = flags == NSEventModifierFlagShift && !results.collections &&
        (key == kVK_UpArrow || key == kVK_DownArrow);
    if (results.rows.count && (!flags || extend)) {
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
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tindakan"];
    NSMenuItem *history = [self item:@"Riwayat" action:@selector(navigateMenu:) value:@0];
    history.keyEquivalent = @"1";
    [menu addItem:history];
    NSMenuItem *collections = [self item:@"Koleksi" action:@selector(navigateMenu:) value:@1];
    collections.keyEquivalent = @"2";
    [menu addItem:collections];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"Pengaturan…" action:@selector(settings:) value:nil]];
    if (!OCAccessibilityReady()) {
        [menu addItem:[self item:@"Panduan Accessibility…" action:@selector(accessibilityGuide:) value:nil]];
    }
    OCResults *results = self.activeResults;
    NSDictionary *row = [self selectedIn:results];
    [menu addItem:[self item:@"Tambah koleksi…" action:@selector(createCollection:) value:nil]];
    if (row && results.collections) {
        [self addCollectionActionsFor:row toMenu:menu];
    } else if (row) {
        NSMenuItem *clipActions = [[NSMenuItem alloc] initWithTitle:@"Tindakan klip" action:nil keyEquivalent:@""];
        clipActions.submenu = [self contextFor:row];
        [menu addItem:clipActions];
    }
    if (!self.browsing) {
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:[self item:@"Bersihkan riwayat…" action:@selector(clearHistory:) value:nil]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Keluar" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;
    [menu addItem:quit];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,0) inView:sender];
}

- (void)settings:(id)sender { if (self.openSettings) self.openSettings(); }
- (void)clearHistory:(id)sender {
    [self clearPreview];
    OCConfirmClearHistory(self.activePanel,NO,^{ [self sendAction:@{@"action":@"clear",@"all":@NO}]; });
}
- (void)navigateMenu:(NSMenuItem *)sender { [self navigateTo:[sender.representedObject integerValue]]; }
- (void)accessibilityGuide:(id)sender { if (self.openAccessibilityGuide) self.openAccessibilityGuide(); }

- (void)createCollection:(id)sender {
    [self editCollection:nil];
}

- (void)renameCollection:(NSMenuItem *)sender {
    [self editCollection:sender.representedObject];
}

- (void)editCollection:(NSDictionary *)collection {
    NSPanel *panel = self.activePanel;
    if (!panel || panel.attachedSheet) return;
    NSSearchField *field = self.activeSearch;
    NSAlert *alert = [NSAlert new];
    alert.messageText = collection ? @"Ubah nama koleksi" : @"Tambah koleksi";
    NSTextField *name = [NSTextField textFieldWithString:collection[@"title"] ?: @""];
    name.placeholderString = @"Nama koleksi";
    name.frame = NSMakeRect(0,0,245,24);
    alert.accessoryView = name;
    alert.window.initialFirstResponder = name;
    [alert addButtonWithTitle:collection ? @"Simpan" : @"Tambah"];
    [alert addButtonWithTitle:@"Batal"];
    [alert beginSheetModalForWindow:panel completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            NSDictionary *request = collection
                ? @{@"action":@"rename_collection",@"id":collection[@"id"],@"name":name.stringValue}
                : @{@"action":@"create_collection",@"name":name.stringValue};
            [self sendAction:request];
        }
        [field.window makeFirstResponder:field];
    }];
}

- (void)deleteCollection:(NSMenuItem *)sender {
    NSDictionary *collection = sender.representedObject;
    NSPanel *panel = self.activePanel;
    if (!collection || !panel || panel.attachedSheet) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Hapus koleksi?";
    alert.informativeText = [NSString stringWithFormat:@"Klip dari “%@” tetap ada di Riwayat.", collection[@"title"]];
    NSButton *cancel = [alert addButtonWithTitle:@"Batal"];
    cancel.keyEquivalent = @"\e";
    [alert addButtonWithTitle:@"Hapus koleksi"].hasDestructiveAction = YES;
    [alert beginSheetModalForWindow:panel completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) {
            if ([collection[@"id"] longLongValue] == self.collection) [self closeCollection];
            [self sendAction:@{@"action":@"delete_collection",@"id":collection[@"id"]}];
        }
    }];
}

- (void)addCollectionActionsFor:(NSDictionary *)row toMenu:(NSMenu *)menu {
    [menu addItem:[self item:@"Ubah nama…" action:@selector(renameCollection:) value:row]];
    [menu addItem:[self item:@"Hapus koleksi…" action:@selector(deleteCollection:) value:row]];
}

- (NSMenu *)contextFor:(NSDictionary *)row {
    if ([row[@"kind"] isEqualToString:@"koleksi"]) {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tindakan koleksi"];
        [self addCollectionActionsFor:row toMenu:menu];
        return menu;
    }
    NSNumber *identifier = row[@"id"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tindakan klip"];
    BOOL pinned = [row[@"pinned"] boolValue];
    [menu addItem:[self item:pinned ? @"Lepas sematan" : @"Sematkan"
        action:@selector(runMenuAction:) value:@{@"action":@"pin",@"id":identifier,@"pinned":(pinned ? @NO : @YES)}]];
    [menu addItem:[self item:@"Pratinjau" action:@selector(previewMenu:) value:nil]];

    if (self.collections.count) {
        NSMenu *collections = [[NSMenu alloc] initWithTitle:@"Koleksi"];
        for (NSDictionary *collection in self.collections) {
            NSNumber *collectionID = collection[@"id"];
            BOOL member = [row[@"collections"] containsObject:collectionID];
            NSMenuItem *choice = [self item:collection[@"name"] action:@selector(runMenuAction:)
                value:@{@"action":@"membership",@"id":identifier,@"collection":collectionID,@"add":(member ? @NO : @YES)}];
            choice.state = member ? NSControlStateValueOn : NSControlStateValueOff;
            [collections addItem:choice];
        }
        NSMenuItem *assigned = [[NSMenuItem alloc] initWithTitle:@"Tambahkan ke koleksi" action:nil keyEquivalent:@""];
        assigned.submenu = collections;
        [menu addItem:assigned];
    }
    if (self.collection) {
        [menu addItem:[self item:@"Keluarkan dari koleksi" action:@selector(runMenuAction:)
            value:@{@"action":@"membership",@"id":identifier,@"collection":@(self.collection),@"add":@NO}]];
    }
    if ([row[@"manually_sensitive"] boolValue]) {
        [menu addItem:[self item:@"Lepas tanda sensitif" action:@selector(runMenuAction:)
            value:@{@"action":@"unmark_sensitive",@"id":identifier}]];
    } else if (![row[@"sensitive"] boolValue]) {
        [menu addItem:[self item:@"Tandai sensitif" action:@selector(runMenuAction:)
            value:@{@"action":@"mark_sensitive",@"id":identifier}]];
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
    if (results.collections) return;
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
