#import "Native.h"
#import "AccessibilityGuide.h"
#import "Toolbar.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CoreServices/CoreServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const ShortcutHelp = @"Buka riwayat dari aplikasi yang sedang dipakai.";
static NSString *const ShortcutKey = @"OCShortcutKey";
static NSString *const ShortcutFlags = @"OCShortcutFlags";
static NSString *const ShortcutLabel = @"OCShortcutLabel";
static NSString *const BottomMode = @"OCBottomMode";
static NSString *const HistoryLimit = @"OCHistoryLimit";
static NSString *const HistoryRetentionDays = @"OCHistoryRetentionDays";
static NSString *const HistoryStorageNote = @"Riwayat clipboard disimpan di Mac ini.";

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
    alert.messageText = all ? @"Hapus semua klip?" : @"Bersihkan riwayat?";
    alert.informativeText = all
        ? @"Semua klip akan dihapus, termasuk klip sematan dan klip di koleksi."
        : @"Klip sematan dan klip di koleksi akan tetap tersimpan.";
    NSButton *cancel = [alert addButtonWithTitle:@"Batal"];
    cancel.keyEquivalent = @"\e";
    [alert addButtonWithTitle:all ? @"Hapus semua klip" : @"Bersihkan riwayat"].hasDestructiveAction = YES;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) confirm();
    }];
}

@interface OCApplication : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *settings;
@property(nonatomic, strong) NSTabView *settingsPages;
@property(nonatomic, copy) NSArray<NSButton *> *settingsNavigation;
@property(nonatomic, strong) OCPicker *picker;
@property(nonatomic, strong) OCRecorder *recorder;
@property(nonatomic, strong) OCAccessibilityGuide *accessibilityGuide;
@property(nonatomic, strong) NSTextField *shortcutValue;
@property(nonatomic, strong) NSTextField *shortcutFeedback;
@property(nonatomic, strong) NSButton *shortcutCapture;
@property(nonatomic, strong) NSPopUpButton *mode;
@property(nonatomic, strong) NSButton *loginButton;
@property(nonatomic, strong) NSTextField *loginStatus;
@property(nonatomic, strong) NSTextField *historyStatus;
@property(nonatomic, strong) NSTextField *historyFeedback;
@property(nonatomic, strong) NSButton *retryButton;
@property(nonatomic, strong) NSTextField *historyLimit;
@property(nonatomic, strong) NSPopUpButton *historyRetention;
@property(nonatomic, strong) NSTextField *usage;
@property(nonatomic, strong) NSTextField *clipboardPermission;
@property(nonatomic, strong) NSTextField *caretPermission;
@property(nonatomic, strong) NSButton *guideButton;
@property(nonatomic, strong) NSButton *detection;
@property(nonatomic, strong) NSPopUpButton *excluded;
@property(nonatomic, strong) id captureMonitor;
@property(nonatomic) int64_t shortcutID;
@property(nonatomic) BOOL launchedAtLogin;
@property(nonatomic) BOOL didCheckAccessibilityOnOpen;
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
        BottomMode: @NO, @"OCDetectSensitive": @YES, HistoryLimit: @500, HistoryRetentionDays: @0,
    }];

    NSString *testDirectory = [defaults stringForKey:@"OCTestDataDirectory"];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    NSString *directory = testDirectory.length ? testDirectory
        : [support.path stringByAppendingPathComponent:@"OpenClipboard"];
    oc_start_worker([directory stringByAppendingPathComponent:@"history.sqlite3"].fileSystemRepresentation);
    OCSend(@{@"action": @"retention", @"days": @([defaults integerForKey:HistoryRetentionDays])});
    OCSend(@{@"action": @"limit", @"limit": @([defaults integerForKey:HistoryLimit])});

    self.picker = [OCPicker new];
    self.recorder = [OCRecorder new];
    __weak OCApplication *weakSelf = self;
    self.picker.openSettings = ^{ [weakSelf showSettings]; };
    self.picker.openAccessibilityGuide = ^{ [weakSelf requestCaret:nil]; };
    self.picker.didWriteClipboard = ^{ [weakSelf.recorder resetBaseline]; };
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

- (void)openFromLaunch {
    [self showSettings];
    if (self.didCheckAccessibilityOnOpen) return;
    self.didCheckAccessibilityOnOpen = YES;
    if (!OCAccessibilityReady()) [self requestCaret:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self refreshPermissions];
    [self refreshLogin];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    if (self.captureMonitor) {
        [self finishCapture];
        self.shortcutFeedback.stringValue = ShortcutHelp;
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.settings && self.captureMonitor) {
        [self finishCapture];
        self.shortcutFeedback.stringValue = ShortcutHelp;
    }
}

- (void)showSettings {
    [self.picker dismissRestoringFocus:NO];
    if (!self.settings) [self buildSettings];
    [self refreshPermissions];
    [self refreshRecording];
    [self refreshLogin];
    [self refreshExcluded];
    [self requestUsage];
    [NSApp activate];
    [self.settings makeKeyAndOrderFront:nil];
}

- (void)buildSettings {
    self.settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 712, 403)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.settings.title = @"Pengaturan OpenClipboard";
    self.settings.titleVisibility = NSWindowTitleHidden;
    self.settings.titlebarAppearsTransparent = YES;
    self.settings.releasedWhenClosed = NO;
    self.settings.delegate = self;
    [self.settings center];

    NSView *root = self.settings.contentView;
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
    NSArray *sections = @[@"Umum", @"Riwayat", @"Privasi"];
    NSArray *icons = @[@"slider.horizontal.3", @"clock.arrow.circlepath", @"lock.shield"];
    NSMutableArray *navigation = [NSMutableArray array];
    for (NSUInteger i=0; i<sections.count; i++) {
        NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:sections[i]];
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
    [self showSettingsSection:self.settingsNavigation.firstObject];

    NSImage *power = [NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:nil];
    NSButton *quit = [OCSettingsNavButton buttonWithTitle:@"Keluar" image:power target:NSApp action:@selector(terminate:)];
    quit.frame = NSMakeRect(12,14,155,36);
    quit.bordered = NO;
    quit.contentTintColor = NSColor.secondaryLabelColor;
    quit.alignment = NSTextAlignmentLeft;
    quit.imagePosition = NSImageLeading;
    [rail addSubview:quit];

    [self updateShortcutLabel];
    if (self.shortcutID < 0) {
        self.shortcutFeedback.stringValue = @"Shortcut belum aktif. Pilih kombinasi lain.";
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
    SettingsTitle(view, @"Umum");
    SettingsGroup(view,211,76);
    SettingsGroup(view,129,66);
    SettingsGroup(view,31,82);

    PlaceLabel(view, @"Shortcut global", NSMakeRect(15,250,154,20), NO);
    self.shortcutValue = PlaceLabel(view, @"", NSMakeRect(159,249,94,23), NO);
    self.shortcutValue.font = [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightSemibold];
    self.shortcutCapture = PlaceButton(view, @"Ubah…", self, @selector(captureShortcut:), NSMakeRect(244,242,86,32));
    PlaceButton(view, @"Pulihkan bawaan", self, @selector(resetShortcut:), NSMakeRect(336,242,130,32));
    self.shortcutFeedback = PlaceLabel(view, ShortcutHelp, NSMakeRect(15,221,450,18), YES);

    PlaceLabel(view, @"Tampilan clipboard", NSMakeRect(15,151,192,21), NO);
    self.mode = OCGlassPopup(NSMakeRect(237,144,226,36), view);
    [self.mode addItemsWithTitles:@[@"Dekat kursor teks", @"Panel bawah layar"]];
    [self.mode selectItemAtIndex:[NSUserDefaults.standardUserDefaults boolForKey:BottomMode] ? 1 : 0];
    self.mode.target = self;
    self.mode.action = @selector(changeMode:);

    self.loginButton = [NSButton checkboxWithTitle:@"Jalankan saat login" target:self action:@selector(toggleLogin:)];
    self.loginButton.frame = NSMakeRect(15,74,227,24);
    [view addSubview:self.loginButton];
    self.loginStatus = PlaceLabel(view, @"", NSMakeRect(33,48,236,19), YES);
    PlaceButton(view, @"Buka Pengaturan Login", self, @selector(openLoginSettings:), NSMakeRect(261,58,202,30));
}

- (void)buildHistory:(NSView *)view {
    SettingsTitle(view, @"Riwayat");
    SettingsGroup(view,207,80);
    SettingsGroup(view,64,127);
    SettingsGroup(view,8,46);

    self.historyStatus = PlaceLabel(view, @"", NSMakeRect(15,248,194,21), NO);
    self.historyStatus.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    self.retryButton = PlaceButton(view, @"Coba lagi", self, @selector(retryClipboard:), NSMakeRect(362,242,101,31));
    self.historyFeedback = PlaceLabel(view, HistoryStorageNote, NSMakeRect(15,218,446,22), YES);

    PlaceLabel(view, @"Batas jumlah klip biasa", NSMakeRect(15,159,225,20), NO);
    self.historyLimit = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld",
        (long)[NSUserDefaults.standardUserDefaults integerForKey:HistoryLimit]]];
    self.historyLimit.frame = NSMakeRect(292,157,77,25);
    self.historyLimit.alignment = NSTextAlignmentCenter;
    [view addSubview:self.historyLimit];
    PlaceButton(view, @"Simpan", self, @selector(saveLimit:), NSMakeRect(372,153,91,31));

    PlaceLabel(view, @"Durasi simpan klip biasa", NSMakeRect(15,120,235,21), NO);
    self.historyRetention = OCGlassPopup(NSMakeRect(292,113,171,34),view);
    for (NSArray *choice in @[@[@"Tanpa batas",@0],@[@"1 hari",@1],@[@"7 hari",@7],
            @[@"30 hari",@30],@[@"90 hari",@90],@[@"1 tahun",@365]]) {
        [self.historyRetention addItemWithTitle:choice[0]];
        self.historyRetention.lastItem.tag = [choice[1] integerValue];
    }
    [self.historyRetention selectItemWithTag:[NSUserDefaults.standardUserDefaults integerForKey:HistoryRetentionDays]];
    self.historyRetention.target = self;
    self.historyRetention.action = @selector(changeRetention:);
    [self.historyRetention setAccessibilityLabel:@"Durasi simpan klip biasa"];
    PlaceLabel(view, @"Klip sematan dan klip di koleksi tetap disimpan.", NSMakeRect(15,94,448,18), YES);

    self.usage = PlaceLabel(view, @"", NSMakeRect(15,72,448,19), YES);
    PlaceButton(view, @"Bersihkan riwayat…", self, @selector(clearOrdinary:), NSMakeRect(13,15,178,31));
    NSButton *clear = PlaceButton(view, @"Hapus semua klip…", self, @selector(clearAll:), NSMakeRect(196,15,162,31));
    clear.contentTintColor = NSColor.systemRedColor;
}

- (void)buildPrivacy:(NSView *)view {
    SettingsTitle(view, @"Privasi");
    SettingsGroup(view,193,94);
    SettingsGroup(view,132,45);
    SettingsGroup(view,19,97);

    self.clipboardPermission = PlaceLabel(view, @"", NSMakeRect(15,248,267,20), NO);
    self.caretPermission = PlaceLabel(view, @"", NSMakeRect(15,211,215,20), NO);
    PlaceButton(view, @"Buka Privasi & Keamanan", self, @selector(openPrivacy:), NSMakeRect(245,242,217,31));
    self.guideButton = PlaceButton(view, @"Aktifkan Accessibility…", self,
        @selector(requestCaret:), NSMakeRect(213,204,249,32));
    self.guideButton.toolTip = @"Buka panduan untuk posisi dekat kursor teks dan tempel langsung.";

    self.detection = [NSButton checkboxWithTitle:@"Deteksi pola sensitif" target:self action:@selector(toggleDetection:)];
    self.detection.frame = NSMakeRect(15,142,340,25);
    self.detection.state = [NSUserDefaults.standardUserDefaults boolForKey:@"OCDetectSensitive"] ? NSControlStateValueOn : NSControlStateValueOff;
    [view addSubview:self.detection];

    PlaceLabel(view, @"Aplikasi yang dikecualikan", NSMakeRect(15,88,284,19), NO);
    self.excluded = OCGlassPopup(NSMakeRect(15,51,253,36), view);
    PlaceButton(view, @"Tambah…", self, @selector(addExclusion:), NSMakeRect(273,53,93,31));
    PlaceButton(view, @"Hapus", self, @selector(removeExclusion:), NSMakeRect(369,53,94,31));
    PlaceLabel(view, @"Pengecualian mengikuti perkiraan aplikasi sumber.",
        NSMakeRect(15,26,447,19), YES);
}

- (void)refreshRecording {
    self.historyStatus.stringValue = self.recorder.status.length ? self.recorder.status : @"Penyimpanan lokal";
    self.clipboardPermission.stringValue = [NSString stringWithFormat:@"Izin clipboard  ·  %@", self.recorder.policy ?: @"Ikuti pengaturan sistem"];
    BOOL blocked = [self.recorder.status isEqualToString:@"Akses clipboard dibatasi"];
    self.retryButton.hidden = !blocked;
    self.picker.recordingStatus = self.recorder.status;
}

- (void)refreshPermissions {
    BOOL ready = OCAccessibilityReady();
    self.caretPermission.stringValue = ready ? @"Accessibility  ·  Diizinkan" : @"Accessibility  ·  Perlu izin";
    self.guideButton.hidden = ready;
    [self refreshRecording];
}

- (void)updateShortcutLabel {
    NSString *label = [NSUserDefaults.standardUserDefaults stringForKey:ShortcutLabel] ?: @"⌘⇧V";
    self.shortcutValue.stringValue = label;
    self.picker.shortcutLabel = self.shortcutID >= 0 ? label : nil;
}

- (void)finishCapture {
    if (self.captureMonitor) [NSEvent removeMonitor:self.captureMonitor];
    self.captureMonitor = nil;
    self.shortcutCapture.title = @"Ubah…";
}

- (void)captureShortcut:(NSButton *)sender {
    if (self.captureMonitor) [self finishCapture];
    sender.title = @"Tekan tombol…";
    self.shortcutFeedback.stringValue = @"Gunakan ⌘, ⌃, atau ⌥. Esc membatalkan.";
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
    NSDictionary *special = @{@36:@"↩", @48:@"⇥", @49:@"Spasi", @51:@"⌫", @123:@"←",
        @124:@"→", @125:@"↓", @126:@"↑", @122:@"F1", @120:@"F2", @99:@"F3", @118:@"F4",
        @96:@"F5", @97:@"F6", @98:@"F7", @100:@"F8", @101:@"F9", @109:@"F10", @103:@"F11", @111:@"F12"};
    NSString *label = special[@(event.keyCode)] ?: event.charactersIgnoringModifiers.uppercaseString;
    return label.length ? label : [NSString stringWithFormat:@"%hu", event.keyCode];
}

- (void)applyShortcut:(uint16_t)key flags:(uint8_t)flags label:(NSString *)label {
    int64_t identifier = oc_register_shortcut(key, flags);
    if (identifier < 0) {
        self.shortcutFeedback.stringValue = identifier == -2
            ? @"Kombinasi ini tidak didukung." : @"Shortcut tidak tersedia. Pilih kombinasi lain.";
        return;
    }
    self.shortcutID = identifier;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:key forKey:ShortcutKey];
    [defaults setInteger:flags forKey:ShortcutFlags];
    [defaults setObject:label forKey:ShortcutLabel];
    self.shortcutFeedback.stringValue = @"Shortcut aktif.";
    [self updateShortcutLabel];
}

- (void)resetShortcut:(id)sender {
    [self finishCapture];
    [self applyShortcut:9 flags:12 label:@"⌘⇧V"];
}

- (void)changeMode:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.indexOfSelectedItem == 1 forKey:BottomMode];
}

- (void)refreshLogin {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginButton.state = (status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval)
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginStatus.stringValue = status == SMAppServiceStatusEnabled ? @"Aktif"
        : status == SMAppServiceStatusRequiresApproval ? @"Perlu persetujuan di Pengaturan Sistem." : @"Nonaktif";
}

- (void)toggleLogin:(NSButton *)sender {
    NSError *error = nil;
    BOOL succeed = sender.state == NSControlStateValueOn ? [SMAppService.mainAppService registerAndReturnError:&error]
                                                        : [SMAppService.mainAppService unregisterAndReturnError:&error];
    [self refreshLogin];
    if (!succeed && SMAppService.mainAppService.status != SMAppServiceStatusRequiresApproval)
        self.loginStatus.stringValue = @"Pengaturan login gagal diperbarui.";
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

- (void)toggleDetection:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:@"OCDetectSensitive"];
}

- (void)refreshExcluded {
    [self.excluded removeAllItems];
    for (NSString *app in [NSUserDefaults.standardUserDefaults stringArrayForKey:@"OCExcluded"] ?: @[]) {
        NSURL *location = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:app];
        [self.excluded addItemWithTitle:location ? location.lastPathComponent.stringByDeletingPathExtension : app];
        self.excluded.lastItem.representedObject = app;
    }
    if (!self.excluded.numberOfItems) [self.excluded addItemWithTitle:@"Belum ada pengecualian"];
}

- (void)addExclusion:(id)sender {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowedContentTypes = @[UTTypeApplicationBundle];
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
    panel.prompt = @"Kecualikan";
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
    NSString *identifier = self.excluded.selectedItem.representedObject;
    if (!identifier) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *items = [[defaults stringArrayForKey:@"OCExcluded"] mutableCopy];
    [items removeObject:identifier];
    [defaults setObject:items forKey:@"OCExcluded"];
    [self.recorder resetBaseline];
    [self refreshExcluded];
}

- (void)saveLimit:(id)sender {
    NSInteger value = self.historyLimit.integerValue;
    if (value < 50 || value > 2000) {
        self.historyFeedback.stringValue = @"Masukkan angka dari 50 sampai 2.000.";
        return;
    }
    if (!OCSend(@{@"action": @"limit", @"limit": @(value)}))
        self.historyFeedback.stringValue = @"Pengaturan belum tersimpan. Coba lagi.";
}

- (void)changeRetention:(NSPopUpButton *)sender {
    NSInteger days = sender.selectedItem.tag;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (OCSend(@{@"action": @"retention", @"days": @(days)})) {
        [defaults setInteger:days forKey:HistoryRetentionDays];
        self.historyFeedback.stringValue = HistoryStorageNote;
    } else {
        [sender selectItemWithTag:[defaults integerForKey:HistoryRetentionDays]];
        self.historyFeedback.stringValue = @"Durasi simpan belum diperbarui. Coba lagi.";
    }
}

- (void)clearOrdinary:(id)sender { [self confirmClear:NO]; }
- (void)clearAll:(id)sender { [self confirmClear:YES]; }

- (void)confirmClear:(BOOL)all {
    OCConfirmClearHistory(self.settings,all,^{
        if (!OCSend(@{@"action": @"clear", @"all": @(all)}))
            self.historyFeedback.stringValue = @"Riwayat belum dihapus. Coba lagi.";
    });
}

- (void)requestUsage {
    if (self.settings.visible) OCSend(@{@"action": @"catalog", @"ticket": @0,
        @"query": @"", @"kind": @"", @"collection": @0});
}

- (void)receiveEvent:(NSDictionary *)event {
    NSString *kind = event[@"kind"];
    if ([kind isEqualToString:@"catalog"]) {
        NSNumber *bytes = event[@"catalog"][@"usage"];
        NSString *value = [NSByteCountFormatter stringFromByteCount:bytes.longLongValue countStyle:NSByteCountFormatterCountStyleBinary];
        self.usage.stringValue = [NSString stringWithFormat:@"Muatan tersimpan  ·  %@ / 256 MiB", value];
    } else if ([kind isEqualToString:@"changed"] || [kind isEqualToString:@"created"]) {
        [self.recorder storageFull:NO];
        [self requestUsage];
    } else if ([kind isEqualToString:@"limit"]) {
        [NSUserDefaults.standardUserDefaults setObject:event[@"value"] forKey:HistoryLimit];
        self.historyLimit.stringValue = [event[@"value"] stringValue];
        self.historyFeedback.stringValue = HistoryStorageNote;
    } else if ([kind isEqualToString:@"error"]) {
        NSString *reason = event[@"reason"];
        BOOL full = [reason isEqualToString:@"full"];
        if (full) [self.recorder storageFull:YES];
        if (self.settings.visible) self.historyFeedback.stringValue = full
            ? @"Ruang untuk klip baru tidak cukup." : @"Tindakan tidak selesai. Coba lagi.";
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

void oc_payload(uint64_t ticket, int64_t id, bool sensitive, const OCPart *parts, size_t count) {
    @autoreleasepool {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
        for (size_t index = 0; index < count; index++) {
            const OCPart *part = &parts[index];
            NSString *type = [NSString stringWithUTF8String:part->type];
            NSData *data = [NSData dataWithBytes:part->data length:part->length];
            if (type && data) [items addObject:@{@"item": @(part->item), @"type": type, @"data": data}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [applicationDelegate.picker receivePayload:items ticket:ticket id:id sensitive:sensitive];
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
