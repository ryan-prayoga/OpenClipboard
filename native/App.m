#import "Native.h"
#import "AccessibilityGuide.h"
#import "Toolbar.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CoreServices/CoreServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *ShortcutHelp(void) { return OCText(@"Buka riwayat dari aplikasi yang sedang dipakai.", @"Open history from any app."); }
static NSString *const ShortcutKey = @"OCShortcutKey";
static NSString *const ShortcutFlags = @"OCShortcutFlags";
static NSString *const ShortcutLabel = @"OCShortcutLabel";
static NSString *const BottomMode = @"OCBottomMode";
NSString *const OCLiquidGlassPreference = @"OCLiquidGlass";
static NSString *const HistoryRetentionDays = @"OCHistoryRetentionDays";
static NSString *CurrentShortcutLabel(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *label = [defaults stringForKey:ShortcutLabel] ?: @"⌘⇧V";
    if ([defaults integerForKey:ShortcutKey] != 49) return label;
    for (NSString *space in @[@"Spasi", @"Space"]) {
        if ([label hasSuffix:space]) {
            NSString *modifiers = [label substringToIndex:label.length - space.length];
            return [modifiers stringByAppendingString:OCText(@"Spasi", @"Space")];
        }
    }
    return label;
}

static NSString *HistoryStorageNote(void) { return OCText(@"Riwayat clipboard disimpan di Mac ini.", @"Clipboard history is stored on this Mac."); }

BOOL OCSend(NSDictionary *command) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    if (!json) return NO;
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    return text && oc_send(text.UTF8String);
}

void OCConfirmClearHistory(NSWindow *window, BOOL all, dispatch_block_t confirm) {
    if (!window || window.attachedSheet) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = all ? OCText(@"Hapus semua klip?", @"Delete all clips?") : OCText(@"Bersihkan riwayat?", @"Clear history?");
    alert.informativeText = all
        ? OCText(@"Semua klip akan dihapus, termasuk klip sematan dan klip di koleksi.", @"This deletes all clips, including pinned clips and clips in collections.")
        : OCText(@"Klip sematan dan klip di koleksi akan tetap tersimpan.", @"Pinned clips and clips in collections are kept.");
    NSButton *cancel = [alert addButtonWithTitle:OCText(@"Batal", @"Cancel")];
    cancel.keyEquivalent = @"\e";
    [alert addButtonWithTitle:all ? OCText(@"Hapus semua klip", @"Delete All Clips") : OCText(@"Bersihkan riwayat", @"Clear History")].hasDestructiveAction = YES;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) confirm();
    }];
}

@interface OCApplication : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) NSWindow *settings;
@property(nonatomic, strong) NSTabView *settingsPages;
@property(nonatomic, copy) NSArray<NSButton *> *settingsNavigation;
@property(nonatomic, strong) OCPicker *picker;
@property(nonatomic, strong) OCRecorder *recorder;
@property(nonatomic, strong) OCAccessibilityGuide *accessibilityGuide;
@property(nonatomic, strong) NSTextField *shortcutValue;
@property(nonatomic, strong) NSTextField *shortcutFeedback;
@property(nonatomic, strong) NSButton *shortcutCapture;
@property(nonatomic, copy) NSArray<NSButton *> *modeButtons;
@property(nonatomic, strong) NSButton *loginButton;
@property(nonatomic, strong) NSTextField *loginStatus;
@property(nonatomic, strong) NSTextField *historyStatus;
@property(nonatomic, strong) NSTextField *historyFeedback;
@property(nonatomic, strong) NSButton *retryButton;
@property(nonatomic, strong) NSView *historyRetentionContainer;
@property(nonatomic, strong) NSPopUpButton *historyRetention;
@property(nonatomic, strong) NSTextField *clipboardPermission;
@property(nonatomic, strong) NSTextField *caretPermission;
@property(nonatomic, strong) NSButton *guideButton;
@property(nonatomic, strong) NSTableView *excludedTable;
@property(nonatomic, copy) NSArray<NSDictionary *> *excludedRows;
@property(nonatomic, strong) NSTextField *excludedEmpty;
@property(nonatomic, strong) NSButton *removeExclusionButton;
@property(nonatomic, strong) id captureMonitor;
@property(nonatomic) int64_t shortcutID;
@property(nonatomic) BOOL launchedAtLogin;
- (void)receiveEvent:(NSDictionary *)event;
- (void)showSettings;
@end

static OCApplication *applicationDelegate;

static NSButton *PlaceButton(NSView *view, NSString *title, id target, SEL action, NSRect rect) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.frame = rect;
    [view addSubview:button];
    return button;
}

static NSTextField *PlaceLabel(NSView *view, NSString *title, NSRect rect, BOOL secondary) {
    NSTextField *field = OCLabel(title, 13, NSFontWeightRegular);
    if (secondary) field.textColor = NSColor.secondaryLabelColor;
    field.frame = rect;
    [view addSubview:field];
    return field;
}


@interface OCSettingsNavCell : NSButtonCell
@end

@implementation OCSettingsNavCell
- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    NSRect iconFrame = NSMakeRect(NSMinX(cellFrame)+11,NSMidY(cellFrame)-8,16,16);
    NSRect titleFrame = NSMakeRect(NSMinX(cellFrame)+35,NSMinY(cellFrame),NSWidth(cellFrame)-46,NSHeight(cellFrame));
    [self drawImage:self.image withFrame:iconFrame inView:controlView];
    [self drawTitle:self.attributedTitle withFrame:titleFrame inView:controlView];
}
@end

@interface OCSettingsNavButton : NSButton
@end

@implementation OCSettingsNavButton
+ (Class)cellClass { return OCSettingsNavCell.class; }

- (void)drawRect:(NSRect)dirtyRect {
    if (self.state == NSControlStateValueOn) {
        NSRect bounds = NSInsetRect(self.bounds,0.5,1);
        NSBezierPath *selection = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:9 yRadius:9];
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.15] setFill];
        [selection fill];
    }
    [super drawRect:dirtyRect];
}
@end

@interface OCSettingsGroup : NSView
@end

@implementation OCSettingsGroup
- (void)drawRect:(NSRect)dirtyRect {
    NSRect surface = NSInsetRect(self.bounds,0.5,0.5);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:surface xRadius:14 yRadius:14];
    [[NSColor.labelColor colorWithAlphaComponent:0.045] setFill];
    [shape fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.075] setStroke];
    shape.lineWidth = 0.8;
    [shape stroke];
}
@end

static void FillPreviewShape(NSRect rect, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

@interface OCModePreview : NSView
@property(nonatomic) BOOL bottom;
@property(nonatomic, weak) NSButton *modeButton;
- (void)selectMode:(NSClickGestureRecognizer *)gesture;
@end

@implementation OCModePreview
- (void)selectMode:(NSClickGestureRecognizer *)gesture {
    [self.modeButton performClick:nil];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect screen = NSInsetRect(self.bounds,0.5,0.5);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:screen xRadius:8 yRadius:8];
    [[NSColor.labelColor colorWithAlphaComponent:0.045] setFill];
    [outline fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.16] setStroke];
    outline.lineWidth = 1;
    [outline stroke];

    NSColor *line = [NSColor.labelColor colorWithAlphaComponent:0.19];
    NSColor *panel = [NSColor.labelColor colorWithAlphaComponent:0.12];
    NSColor *selection = [NSColor.controlAccentColor colorWithAlphaComponent:0.38];
    CGFloat middle = NSMidX(screen);
    CGFloat firstLineY = NSHeight(self.bounds)-9;
    for (NSInteger row = 0; row < 2; row++) {
        FillPreviewShape(NSMakeRect(middle-48,firstLineY-row*8,70-row*17,2),1,line);
    }
    if (self.bottom) {
        NSRect tray = NSMakeRect(8,7,NSWidth(self.bounds)-16,27);
        FillPreviewShape(tray,5,panel);
        CGFloat cardWidth = (NSWidth(tray)-23)/4;
        for (NSInteger card = 0; card < 4; card++) {
            FillPreviewShape(NSMakeRect(13+card*(cardWidth+4),12,cardWidth,17),3,card == 0 ? selection : line);
        }
    } else {
        FillPreviewShape(NSMakeRect(middle+7,firstLineY-11,1.5,8),0.75,NSColor.controlAccentColor);
        FillPreviewShape(NSMakeRect(middle+7,7,67,27),5,panel);
        FillPreviewShape(NSMakeRect(middle+12,25,57,5),2,selection);
        FillPreviewShape(NSMakeRect(middle+12,18,41,3),1.5,line);
        FillPreviewShape(NSMakeRect(middle+12,12,34,3),1.5,line);
    }
}
@end

@interface OCSettingsWell : NSView
@end

@implementation OCSettingsWell
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,0.5,0.5) xRadius:8 yRadius:8];
    [[NSColor.labelColor colorWithAlphaComponent:0.06] setFill];
    [shape fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.14] setStroke];
    shape.lineWidth = 1;
    [shape stroke];
}
@end

static void SettingsGroup(NSView *pane, CGFloat y, CGFloat height) {
    [pane addSubview:[[OCSettingsGroup alloc] initWithFrame:NSMakeRect(0,y,480,height)]];
}

static void SettingsTitle(NSView *pane, NSString *title) {
    NSTextField *heading = OCLabel(title, 27, NSFontWeightSemibold);
    heading.frame = NSMakeRect(1,307,475,36);
    [pane addSubview:heading];
}

@implementation OCApplication
- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSAppleEventDescriptor *event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
    self.launchedAtLogin = [event paramDescriptorForKeyword:keyAELaunchedAsLogInItem] != nil;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{
        ShortcutKey: @9, ShortcutFlags: @12, ShortcutLabel: @"⌘⇧V",
        BottomMode: @NO, OCLiquidGlassPreference: @YES, HistoryRetentionDays: @0,
    }];

    NSString *testDirectory = [defaults stringForKey:@"OCTestDataDirectory"];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    NSString *directory = testDirectory.length ? testDirectory
        : [support.path stringByAppendingPathComponent:@"OpenClipboard"];
    oc_start_worker([directory stringByAppendingPathComponent:@"history.sqlite3"].fileSystemRepresentation);
    OCSend(@{@"action": @"retention", @"days": @([defaults integerForKey:HistoryRetentionDays])});

    [self installMainMenu];
    self.picker = [OCPicker new];
    self.recorder = [OCRecorder new];
    __weak OCApplication *weakSelf = self;
    self.picker.openSettings = ^{ [weakSelf showSettings]; };
    self.picker.quit = ^{ [weakSelf confirmQuit:nil]; };
    self.picker.prepareClipboardWrite = ^BOOL { return [weakSelf.recorder prepareClipboardWrite]; };
    self.recorder.statusChanged = ^{ [weakSelf refreshRecording]; };
    [self.recorder startTimer];
    self.shortcutID = oc_register_shortcut((uint16_t)[defaults integerForKey:ShortcutKey],
                                          (uint8_t)[defaults integerForKey:ShortcutFlags]);
    [self updateShortcutLabel];
    NSAppleEventDescriptor *event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
    if (!self.launchedAtLogin && ![event paramDescriptorForKeyword:keyAELaunchedAsLogInItem]) {
        [self openFromLaunch];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    [self openFromLaunch];
    return NO;
}

// Opening the app only shows Settings. The Accessibility guide starts when the user asks for it.
- (void)openFromLaunch {
    [self showSettings];
}

- (void)installMainMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *app = [[NSMenu alloc] initWithTitle:@"OpenClipboard"];
    NSMenuItem *settings = [app addItemWithTitle:OCText(@"Pengaturan…", @"Settings…") action:@selector(openSettingsFromMenu:) keyEquivalent:@","];
    settings.target = self;
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:OCText(@"Keluar dari OpenClipboard", @"Quit OpenClipboard") action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = app;
    [bar addItem:appItem];

    NSMenuItem *editItem = [NSMenuItem new];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:OCText(@"Urungkan", @"Undo") action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    NSMenuItem *redo = [edit addItemWithTitle:OCText(@"Ulangi", @"Redo") action:NSSelectorFromString(@"redo:") keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:OCText(@"Potong", @"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:OCText(@"Salin", @"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:OCText(@"Tempel", @"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:OCText(@"Pilih Semua", @"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    [bar addItem:editItem];

    NSMenuItem *windowItem = [NSMenuItem new];
    NSMenu *window = [[NSMenu alloc] initWithTitle:OCText(@"Jendela", @"Window")];
    [window addItemWithTitle:OCText(@"Tutup", @"Close") action:@selector(performClose:) keyEquivalent:@"w"];
    windowItem.submenu = window;
    [bar addItem:windowItem];
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = window;
}

- (void)openSettingsFromMenu:(id)sender { [self showSettings]; }

// The app has no Dock or menu bar icon, so quitting from a menu removes its only entry point.
- (void)confirmQuit:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = OCText(@"Keluar dari OpenClipboard?", @"Quit OpenClipboard?");
    alert.informativeText = OCText(@"Perekaman clipboard dan shortcut berhenti sampai aplikasi dibuka lagi dari Finder atau Spotlight.", @"Clipboard recording and the shortcut stop until you reopen the app from Finder or Spotlight.");
    NSButton *cancel = [alert addButtonWithTitle:OCText(@"Batal", @"Cancel")];
    cancel.keyEquivalent = @"\e";
    [alert addButtonWithTitle:OCText(@"Keluar", @"Quit")].hasDestructiveAction = YES;
    if ([alert runModal] == NSAlertSecondButtonReturn) [NSApp terminate:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self refreshPermissions];
    [self refreshLogin];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    if (self.captureMonitor) {
        [self finishCapture];
        self.shortcutFeedback.stringValue = ShortcutHelp();
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.settings && self.captureMonitor) {
        [self finishCapture];
        self.shortcutFeedback.stringValue = ShortcutHelp();
    }
}

- (void)showSettings {
    [self.picker dismissRestoringFocus:NO];
    if (!self.settings) [self buildSettings];
    [self refreshPermissions];
    [self refreshRecording];
    [self refreshLogin];
    [self refreshExcluded];
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
    [self.settings makeKeyAndOrderFront:nil];
}

- (void)buildSettings {
    self.settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 712, 403)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.settings.identifier = OCSettingsWindowIdentifier;
    self.settings.titleVisibility = NSWindowTitleHidden;
    self.settings.titlebarAppearsTransparent = YES;
    self.settings.releasedWhenClosed = NO;
    self.settings.delegate = self;
    [self.settings center];

    [self buildSettingsContent];
    [self showSettingsSection:self.settingsNavigation.firstObject];
}

- (void)buildSettingsContent {
    self.settings.title = OCText(@"Pengaturan OpenClipboard", @"OpenClipboard Settings");
    NSView *root = [[NSView alloc] initWithFrame:self.settings.contentView.bounds];
    self.settings.contentView = root;
    NSVisualEffectView *rail = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,179,403)];
    rail.material = NSVisualEffectMaterialSidebar;
    rail.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    rail.state = NSVisualEffectStateActive;
    [root addSubview:rail];

    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"clipboard.fill" accessibilityDescription:nil];
    NSImageView *mark = [NSImageView imageViewWithImage:symbol];
    mark.contentTintColor = NSColor.controlAccentColor;
    mark.frame = NSMakeRect(19,326,23,27);
    [rail addSubview:mark];
    NSTextField *wordmark = OCLabel(@"OpenClipboard",14,NSFontWeightSemibold);
    wordmark.frame = NSMakeRect(48,329,126,21);
    [rail addSubview:wordmark];

    self.settingsPages = [[NSTabView alloc] initWithFrame:NSMakeRect(205,22,480,350)];
    self.settingsPages.tabViewType = NSNoTabsNoBorder;
    [root addSubview:self.settingsPages];
    NSArray *sections = @[OCText(@"Umum", @"General"), OCText(@"Riwayat", @"History"), OCText(@"Privasi", @"Privacy")];
    NSArray *icons = @[@"slider.horizontal.3", @"clock.arrow.circlepath", @"lock.shield"];
    NSMutableArray *navigation = [NSMutableArray array];
    for (NSUInteger i=0; i<sections.count; i++) {
        NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@(i)];
        item.label = sections[i];
        item.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,480,350)];
        [self.settingsPages addTabViewItem:item];
        if (i==0) [self buildGeneral:item.view];
        if (i==1) [self buildHistory:item.view];
        if (i==2) [self buildPrivacy:item.view];

        NSImage *image = [NSImage imageWithSystemSymbolName:icons[i] accessibilityDescription:nil];
        NSButton *button = [OCSettingsNavButton buttonWithTitle:sections[i] image:image target:self
                                             action:@selector(showSettingsSection:)];
        button.tag = (NSInteger)i;
        button.bordered = NO;
        button.buttonType = NSButtonTypePushOnPushOff;
        button.imagePosition = NSImageLeading;
        button.alignment = NSTextAlignmentLeft;
        button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        button.frame = NSMakeRect(12,275-i*42,155,36);
        [rail addSubview:button];
        [navigation addObject:button];
    }
    self.settingsNavigation = navigation;
    NSImage *power = [NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:nil];
    NSButton *quit = [OCSettingsNavButton buttonWithTitle:OCText(@"Keluar", @"Quit") image:power target:self action:@selector(confirmQuit:)];
    quit.frame = NSMakeRect(12,14,155,36);
    quit.bordered = NO;
    quit.contentTintColor = NSColor.secondaryLabelColor;
    quit.alignment = NSTextAlignmentLeft;
    quit.imagePosition = NSImageLeading;
    [rail addSubview:quit];

    [self updateShortcutLabel];
    if (self.shortcutID < 0) {
        self.shortcutFeedback.stringValue = OCText(@"Shortcut belum aktif. Pilih kombinasi lain.", @"The shortcut is inactive. Choose another combination.");
    }
}

- (void)showSettingsSection:(NSButton *)sender {
    [self.settingsPages selectTabViewItemAtIndex:sender.tag];
    for (NSButton *button in self.settingsNavigation) {
        BOOL selected = button == sender;
        button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        button.contentTintColor = selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
        button.needsDisplay = YES;
    }
}

- (void)buildGeneral:(NSView *)view {
    SettingsTitle(view, OCText(@"Umum", @"General"));
    NSString *language = OCText(@"Bahasa", @"Language");
    PlaceLabel(view, language, NSMakeRect(246,314,78,20), NO);
    NSPopUpButton *languagePicker = OCGlassPopup(NSMakeRect(326,306,154,34), view);
    [languagePicker addItemsWithTitles:@[@"Bahasa Indonesia", @"English"]];
    [languagePicker selectItemAtIndex:OCUsesEnglish() ? 1 : 0];
    [languagePicker setAccessibilityLabel:language];
    languagePicker.target = self;
    languagePicker.action = @selector(changeLanguage:);
    SettingsGroup(view,223,76);
    SettingsGroup(view,77,135);
    SettingsGroup(view,8,63);

    PlaceLabel(view, OCText(@"Shortcut global", @"Global shortcut"), NSMakeRect(15,262,154,20), NO);
    self.shortcutValue = PlaceLabel(view, @"", NSMakeRect(159,261,94,23), NO);
    self.shortcutValue.font = [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightSemibold];
    self.shortcutCapture = PlaceButton(view, OCText(@"Ubah…", @"Change…"), self, @selector(captureShortcut:), NSMakeRect(244,254,86,32));
    PlaceButton(view, OCText(@"Pulihkan bawaan", @"Restore Default"), self, @selector(resetShortcut:), NSMakeRect(336,254,130,32));
    self.shortcutFeedback = PlaceLabel(view, ShortcutHelp(), NSMakeRect(15,233,450,18), YES);

    PlaceLabel(view, OCText(@"Tampilan clipboard", @"Clipboard layout"), NSMakeRect(18,185,192,20), NO).font =
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    BOOL bottomMode = [NSUserDefaults.standardUserDefaults boolForKey:BottomMode];
    NSMutableArray<NSButton *> *modeButtons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[OCText(@"Dekat kursor teks", @"Near the text cursor"), OCText(@"Panel bawah layar", @"Bottom of the screen")];
    for (NSInteger mode = 0; mode < (NSInteger)titles.count; mode++) {
        CGFloat x = 18+mode*232;
        NSButton *button = [NSButton radioButtonWithTitle:titles[(NSUInteger)mode] target:self action:@selector(changeMode:)];
        button.frame = NSMakeRect(x,161,212,21);
        button.tag = mode;
        button.state = mode == bottomMode ? NSControlStateValueOn : NSControlStateValueOff;
        [view addSubview:button];
        [modeButtons addObject:button];

        OCModePreview *preview = [[OCModePreview alloc] initWithFrame:NSMakeRect(x,108,212,47)];
        preview.bottom = mode == 1;
        preview.modeButton = button;
        [preview addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:preview action:@selector(selectMode:)]];
        [view addSubview:preview];
    }
    self.modeButtons = modeButtons;

    NSButton *glass = [NSButton checkboxWithTitle:OCText(@"Gunakan Liquid Glass", @"Use Liquid Glass") target:self
                                            action:@selector(toggleLiquidGlass:)];
    glass.frame = NSMakeRect(18,82,210,22);
    if (@available(macOS 26.0, *)) {
        glass.state = [NSUserDefaults.standardUserDefaults boolForKey:OCLiquidGlassPreference]
            ? NSControlStateValueOn : NSControlStateValueOff;
        glass.toolTip = OCText(@"Berlaku saat riwayat dibuka lagi.", @"Applies the next time you open history.");
    } else {
        glass.enabled = NO;
        PlaceLabel(view, OCText(@"Perlu macOS 26 atau lebih baru.", @"Requires macOS 26 or later."), NSMakeRect(233,83,227,20), YES);
    }
    [view addSubview:glass];

    self.loginButton = [NSButton checkboxWithTitle:OCText(@"Jalankan saat login", @"Launch at login") target:self action:@selector(toggleLogin:)];
    self.loginButton.frame = NSMakeRect(15,38,227,24);
    [view addSubview:self.loginButton];
    self.loginStatus = PlaceLabel(view, @"", NSMakeRect(33,17,236,19), YES);
    PlaceButton(view, OCText(@"Buka Pengaturan Login", @"Open Login Settings"), self, @selector(openLoginSettings:), NSMakeRect(261,24,202,30));
}

- (void)changeLanguage:(NSPopUpButton *)sender {
    BOOL english = sender.indexOfSelectedItem == 1;
    if (english == OCUsesEnglish()) return;
    NSInteger section = [self.settingsPages indexOfTabViewItem:self.settingsPages.selectedTabViewItem];
    [self finishCapture];
    [NSUserDefaults.standardUserDefaults setObject:english ? @"en" : @"id" forKey:OCLanguagePreference];
    [self installMainMenu];
    [self.accessibilityGuide reloadLanguage];
    [self.recorder updateStatus];
    [self buildSettingsContent];
    [self showSettingsSection:self.settingsNavigation[section]];
    [self showSettings];
}

- (void)buildHistory:(NSView *)view {
    SettingsTitle(view, OCText(@"Riwayat", @"History"));
    SettingsGroup(view,207,80);
    SettingsGroup(view,125,66);
    SettingsGroup(view,37,78);

    self.historyStatus = PlaceLabel(view, @"", NSMakeRect(15,248,194,21), NO);
    self.historyStatus.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    self.retryButton = PlaceButton(view, OCText(@"Coba lagi", @"Retry"), self, @selector(retryClipboard:), NSMakeRect(362,242,101,31));
    self.historyFeedback = PlaceLabel(view, HistoryStorageNote(), NSMakeRect(15,218,446,22), YES);

    PlaceLabel(view, OCText(@"Durasi simpan klip biasa", @"Keep regular clips for"), NSMakeRect(15,159,235,21), NO);
    [self buildHistoryRetention:view];
    PlaceLabel(view, OCText(@"Klip sematan dan klip di koleksi tetap disimpan.", @"Pinned clips and clips in collections are kept."), NSMakeRect(15,133,448,18), YES);

    PlaceButton(view, OCText(@"Bersihkan riwayat…", @"Clear History…"), self, @selector(clearOrdinary:), NSMakeRect(13,79,178,31));
    NSButton *clear = PlaceButton(view, OCText(@"Hapus semua klip…", @"Delete All Clips…"), self, @selector(clearAll:), NSMakeRect(244,79,162,31));
    clear.contentTintColor = NSColor.systemRedColor;
    NSTextField *ordinaryHelp = [NSTextField wrappingLabelWithString:
        OCText(@"Hapus klip biasa. Klip sematan dan klip di koleksi tetap tersimpan.",
               @"Delete regular clips. Keep pinned clips and clips in collections.")];
    ordinaryHelp.font = [NSFont systemFontOfSize:12];
    ordinaryHelp.textColor = NSColor.secondaryLabelColor;
    ordinaryHelp.frame = NSMakeRect(15,43,215,36);
    [view addSubview:ordinaryHelp];
    NSTextField *allHelp = [NSTextField wrappingLabelWithString:
        OCText(@"Hapus semua klip, termasuk klip sematan. Koleksi jadi kosong.",
               @"Delete all clips, including pinned clips. Collections become empty.")];
    allHelp.font = ordinaryHelp.font;
    allHelp.textColor = NSColor.secondaryLabelColor;
    allHelp.frame = NSMakeRect(246,43,219,36);
    [view addSubview:allHelp];
}

- (void)buildPrivacy:(NSView *)view {
    SettingsTitle(view, OCText(@"Privasi", @"Privacy"));
    SettingsGroup(view,193,94);
    SettingsGroup(view,8,116);

    self.clipboardPermission = PlaceLabel(view, @"", NSMakeRect(15,248,225,20), NO);
    self.caretPermission = PlaceLabel(view, @"", NSMakeRect(15,211,215,20), NO);
    PlaceButton(view, OCText(@"Buka Privasi & Keamanan", @"Open Privacy & Security"), self, @selector(openPrivacy:), NSMakeRect(245,242,217,31));
    self.guideButton = PlaceButton(view, OCText(@"Aktifkan Accessibility…", @"Enable Accessibility…"), self,
        @selector(requestCaret:), NSMakeRect(213,204,249,32));
    self.guideButton.toolTip = OCText(@"Buka panduan untuk posisi dekat kursor teks dan tempel langsung.", @"Open the guide to show the picker near the text cursor and paste directly.");

    PlaceLabel(view, OCText(@"Aplikasi yang dikecualikan", @"Excluded apps"), NSMakeRect(15,96,250,19), NO);
    PlaceButton(view, OCText(@"Tambah…", @"Add…"), self, @selector(addExclusion:), NSMakeRect(273,91,93,31));
    self.removeExclusionButton = PlaceButton(view, OCText(@"Hapus", @"Remove"), self, @selector(removeExclusion:), NSMakeRect(369,91,94,31));
    self.removeExclusionButton.enabled = NO;

    [view addSubview:[[OCSettingsWell alloc] initWithFrame:NSMakeRect(15,40,447,48)]];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16,41,445,46)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"app"];
    column.editable = NO;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [column.dataCell setFont:[NSFont systemFontOfSize:13]];
    [table addTableColumn:column];
    table.headerView = nil;
    table.rowHeight = 22;
    table.backgroundColor = NSColor.clearColor;
    table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    table.allowsEmptySelection = YES;
    table.dataSource = self;
    table.delegate = self;
    [table setAccessibilityLabel:OCText(@"Aplikasi yang dikecualikan", @"Excluded apps")];
    scroll.documentView = table;
    [view addSubview:scroll];
    self.excludedTable = table;

    self.excludedEmpty = PlaceLabel(view, OCText(@"Belum ada pengecualian", @"No exclusions yet"), NSMakeRect(27,56,423,19), YES);
    PlaceLabel(view, OCText(@"Pengecualian mengikuti perkiraan aplikasi sumber.", @"Exclusions use the estimated source app."), NSMakeRect(15,14,447,19), YES);
}

- (void)refreshRecording {
    self.historyStatus.stringValue = self.recorder.status.length ? self.recorder.status : OCText(@"Penyimpanan lokal", @"Local storage");
    self.clipboardPermission.stringValue = [NSString stringWithFormat:OCText(@"Izin clipboard  ·  %@", @"Clipboard access  ·  %@"), self.recorder.policy ?: OCText(@"Ikuti sistem", @"System default")];
    self.clipboardPermission.toolTip = self.clipboardPermission.stringValue;
    BOOL blocked = [self.recorder.status isEqualToString:OCText(@"Akses clipboard dibatasi", @"Clipboard access restricted")];
    self.retryButton.hidden = !blocked;
    self.picker.recordingStatus = self.recorder.status;
}

- (void)refreshPermissions {
    BOOL ready = OCAccessibilityReady();
    self.caretPermission.stringValue = ready ? OCText(@"Accessibility  ·  Diizinkan", @"Accessibility  ·  Allowed") : OCText(@"Accessibility  ·  Perlu izin", @"Accessibility  ·  Permission required");
    self.guideButton.hidden = ready;
    [self refreshRecording];
}

- (void)updateShortcutLabel {
    NSString *label = CurrentShortcutLabel();
    self.shortcutValue.stringValue = label;
    self.picker.shortcutLabel = self.shortcutID >= 0 ? label : nil;
}

- (void)finishCapture {
    if (self.captureMonitor) [NSEvent removeMonitor:self.captureMonitor];
    self.captureMonitor = nil;
    self.shortcutCapture.title = OCText(@"Ubah…", @"Change…");
}

- (void)captureShortcut:(NSButton *)sender {
    if (self.captureMonitor) [self finishCapture];
    sender.title = OCText(@"Tekan tombol…", @"Press a key…");
    self.shortcutFeedback.stringValue = OCText(@"Gunakan ⌘, ⌃, atau ⌥. Esc membatalkan.", @"Use ⌘, ⌃, or ⌥. Press Esc to cancel.");
    __weak OCApplication *weakSelf = self;
    self.captureMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        OCApplication *application = weakSelf;
        if (!application || event.window != application.settings) return event;
        [application finishCapture];
        if (event.keyCode == 53) {
            application.shortcutFeedback.stringValue = @"";
            return nil;
        }
        NSEventModifierFlags incoming = event.modifierFlags;
        uint8_t flags = ((incoming & NSEventModifierFlagControl) ? 1 : 0)
            | ((incoming & NSEventModifierFlagOption) ? 2 : 0)
            | ((incoming & NSEventModifierFlagShift) ? 4 : 0)
            | ((incoming & NSEventModifierFlagCommand) ? 8 : 0);
        NSString *keyLabel = [application labelForKeyEvent:event];
        NSString *label = [NSString stringWithFormat:@"%@%@%@%@%@",
            flags & 1 ? @"⌃" : @"", flags & 2 ? @"⌥" : @"", flags & 4 ? @"⇧" : @"",
            flags & 8 ? @"⌘" : @"", keyLabel];
        [application applyShortcut:event.keyCode flags:flags label:label];
        return nil;
    }];
}

- (NSString *)labelForKeyEvent:(NSEvent *)event {
    NSDictionary *special = @{@36:@"↩", @48:@"⇥", @49:OCText(@"Spasi", @"Space"), @51:@"⌫", @123:@"←",
        @124:@"→", @125:@"↓", @126:@"↑", @122:@"F1", @120:@"F2", @99:@"F3", @118:@"F4",
        @96:@"F5", @97:@"F6", @98:@"F7", @100:@"F8", @101:@"F9", @109:@"F10", @103:@"F11", @111:@"F12"};
    NSString *label = special[@(event.keyCode)] ?: event.charactersIgnoringModifiers.uppercaseString;
    return label.length ? label : [NSString stringWithFormat:@"%hu", event.keyCode];
}

- (void)applyShortcut:(uint16_t)key flags:(uint8_t)flags label:(NSString *)label {
    int64_t identifier = oc_register_shortcut(key, flags);
    if (identifier < 0) {
        self.shortcutFeedback.stringValue = identifier == -2
            ? OCText(@"Kombinasi ini tidak didukung.", @"This key combination is unsupported.") : OCText(@"Shortcut tidak tersedia. Pilih kombinasi lain.", @"The shortcut is unavailable. Choose another combination.");
        return;
    }
    self.shortcutID = identifier;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:key forKey:ShortcutKey];
    [defaults setInteger:flags forKey:ShortcutFlags];
    [defaults setObject:label forKey:ShortcutLabel];
    self.shortcutFeedback.stringValue = OCText(@"Shortcut aktif.", @"Shortcut is active.");
    [self updateShortcutLabel];
}

- (void)resetShortcut:(id)sender {
    [self finishCapture];
    [self applyShortcut:9 flags:12 label:@"⌘⇧V"];
}

- (void)changeMode:(NSButton *)sender {
    for (NSButton *button in self.modeButtons)
        button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setBool:sender.tag == 1 forKey:BottomMode];
}

- (void)toggleLiquidGlass:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                         forKey:OCLiquidGlassPreference];
    [self buildHistoryRetention:self.historyRetentionContainer.superview];
}

- (void)buildHistoryRetention:(NSView *)view {
    [self.historyRetentionContainer removeFromSuperview];
    self.historyRetentionContainer = [[NSView alloc] initWithFrame:NSMakeRect(292,152,171,34)];
    [view addSubview:self.historyRetentionContainer];
    self.historyRetention = OCGlassPopup(self.historyRetentionContainer.bounds, self.historyRetentionContainer);
    for (NSArray *choice in @[@[OCText(@"Tanpa batas", @"Forever"),@0],@[OCText(@"1 hari", @"1 day"),@1],@[OCText(@"7 hari", @"7 days"),@7],
            @[OCText(@"30 hari", @"30 days"),@30],@[OCText(@"90 hari", @"90 days"),@90],@[OCText(@"1 tahun", @"1 year"),@365]]) {
        [self.historyRetention addItemWithTitle:choice[0]];
        self.historyRetention.lastItem.tag = [choice[1] integerValue];
    }
    [self.historyRetention selectItemWithTag:[NSUserDefaults.standardUserDefaults integerForKey:HistoryRetentionDays]];
    self.historyRetention.target = self;
    self.historyRetention.action = @selector(changeRetention:);
    [self.historyRetention setAccessibilityLabel:OCText(@"Durasi simpan klip biasa", @"Keep regular clips for")];
}

- (void)refreshLogin {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginButton.state = (status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval)
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginStatus.stringValue = status == SMAppServiceStatusEnabled ? OCText(@"Aktif", @"On")
        : status == SMAppServiceStatusRequiresApproval ? OCText(@"Perlu persetujuan sistem.", @"System approval required.") : OCText(@"Nonaktif", @"Off");
}

- (void)toggleLogin:(NSButton *)sender {
    NSError *error = nil;
    BOOL succeed = sender.state == NSControlStateValueOn ? [SMAppService.mainAppService registerAndReturnError:&error]
                                                        : [SMAppService.mainAppService unregisterAndReturnError:&error];
    [self refreshLogin];
    if (!succeed && SMAppService.mainAppService.status != SMAppServiceStatusRequiresApproval)
        self.loginStatus.stringValue = OCText(@"Pengaturan login gagal diperbarui.", @"Could not update login settings.");
}

- (void)openLoginSettings:(id)sender { [SMAppService openSystemSettingsLoginItems]; }
- (void)retryClipboard:(id)sender { [self.recorder retry]; }

- (void)requestCaret:(id)sender {
    if (OCAccessibilityReady()) {
        [self refreshPermissions];
        return;
    }
    [self.picker dismissRestoringFocus:NO];
    if (!self.accessibilityGuide) {
        self.accessibilityGuide = [OCAccessibilityGuide new];
        __weak OCApplication *weakSelf = self;
        self.accessibilityGuide.permissionChanged = ^{ [weakSelf refreshPermissions]; };
    }
    [self.accessibilityGuide showFromScreen:self.settings.visible ? self.settings.screen : NSScreen.mainScreen];
    [self refreshPermissions];
}

- (void)openPrivacy:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]];
}

- (void)refreshExcluded {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *app in [NSUserDefaults.standardUserDefaults stringArrayForKey:@"OCExcluded"] ?: @[]) {
        NSURL *location = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:app];
        [rows addObject:@{@"name": location ? location.lastPathComponent.stringByDeletingPathExtension : app,
                          @"bundle": app}];
    }
    self.excludedRows = rows;
    [self.excludedTable reloadData];
    self.excludedEmpty.hidden = rows.count > 0;
    self.removeExclusionButton.enabled = self.excludedTable.selectedRow >= 0;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.excludedRows.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    return row >= 0 && (NSUInteger)row < self.excludedRows.count ? self.excludedRows[(NSUInteger)row][@"name"] : nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    self.removeExclusionButton.enabled = self.excludedTable.selectedRow >= 0;
}

- (void)addExclusion:(id)sender {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowedContentTypes = @[UTTypeApplicationBundle];
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
    panel.prompt = OCText(@"Kecualikan", @"Exclude");
    [panel beginSheetModalForWindow:self.settings completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSString *bundle = [NSBundle bundleWithURL:panel.URL].bundleIdentifier;
        if (!bundle.length) return;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *items = [[defaults stringArrayForKey:@"OCExcluded"] mutableCopy] ?: [NSMutableArray array];
        if (![items containsObject:bundle]) {
            [items addObject:bundle];
            [defaults setObject:items forKey:@"OCExcluded"];
            [self.recorder resetBaseline];
        }
        [self refreshExcluded];
    }];
}

- (void)removeExclusion:(id)sender {
    NSInteger row = self.excludedTable.selectedRow;
    if (row < 0 || (NSUInteger)row >= self.excludedRows.count) return;
    NSString *identifier = self.excludedRows[(NSUInteger)row][@"bundle"];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *items = [[defaults stringArrayForKey:@"OCExcluded"] mutableCopy];
    [items removeObject:identifier];
    [defaults setObject:items forKey:@"OCExcluded"];
    [self.recorder resetBaseline];
    [self refreshExcluded];
}

- (void)changeRetention:(NSPopUpButton *)sender {
    NSInteger days = sender.selectedItem.tag;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (OCSend(@{@"action": @"retention", @"days": @(days)})) {
        [defaults setInteger:days forKey:HistoryRetentionDays];
        self.historyFeedback.stringValue = HistoryStorageNote();
    } else {
        [sender selectItemWithTag:[defaults integerForKey:HistoryRetentionDays]];
        self.historyFeedback.stringValue = OCText(@"Durasi simpan belum diperbarui. Coba lagi.", @"Could not change retention. Try again.");
    }
}

- (void)clearOrdinary:(id)sender { [self confirmClear:NO]; }
- (void)clearAll:(id)sender { [self confirmClear:YES]; }

- (void)confirmClear:(BOOL)all {
    OCConfirmClearHistory(self.settings,all,^{
        if (!OCSend(@{@"action": @"clear", @"all": @(all)}))
            self.historyFeedback.stringValue = OCText(@"Riwayat belum dihapus. Coba lagi.", @"Could not clear history. Try again.");
    });
}

- (void)receiveEvent:(NSDictionary *)event {
    NSString *kind = event[@"kind"];
    if ([kind isEqualToString:@"changed"] || [kind isEqualToString:@"created"]) {
        [self.recorder storageFull:NO];
    } else if ([kind isEqualToString:@"error"]) {
        NSString *reason = event[@"reason"];
        BOOL full = [reason isEqualToString:@"full"];
        if (full) [self.recorder storageFull:YES];
        if (self.settings.visible) self.historyFeedback.stringValue = full
            ? OCText(@"Ruang untuk klip baru tidak cukup.", @"There is no space for new clips.") : OCText(@"Tindakan tidak selesai. Coba lagi.", @"Could not complete the action. Try again.");
    }
    [self.picker receiveEvent:event];
}
@end

void oc_install_delegate(void) {
    applicationDelegate = [OCApplication new];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    NSApp.delegate = applicationDelegate;
}

void oc_shortcut_fired(uint32_t identifier) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(), ^{
        OCApplication *application = applicationDelegate;
        if (application.shortcutID != identifier || application.captureMonitor) return;
        [application.recorder captureNow];
        [application.picker showAtBottom:[NSUserDefaults.standardUserDefaults boolForKey:BottomMode]
                                  started:started];
    });
}

void oc_event(const char *event) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:event length:strlen(event)];
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (message) dispatch_async(dispatch_get_main_queue(), ^{ [applicationDelegate receiveEvent:message]; });
    }
}

void oc_payload(uint64_t ticket, int64_t id, const OCPart *parts, size_t count) {
    @autoreleasepool {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
        for (size_t index = 0; index < count; index++) {
            const OCPart *part = &parts[index];
            NSString *type = [NSString stringWithUTF8String:part->type];
            NSData *data = [NSData dataWithBytes:part->data length:part->length];
            if (type && data) [items addObject:@{@"item": @(part->item), @"type": type, @"data": data}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [applicationDelegate.picker receivePayload:items ticket:ticket id:id];
        });
    }
}

void oc_preview_image(uint64_t ticket, int64_t id, const uint8_t *data, size_t length) {
    @autoreleasepool {
        NSData *image = [NSData dataWithBytes:data length:length];
        dispatch_async(dispatch_get_main_queue(), ^{
            [applicationDelegate.picker receiveThumbnail:image ticket:ticket id:id];
        });
    }
}
