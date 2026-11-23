#import "Native.h"
#import "Tabs.h"
#import "Bridge.h"
#import "Toolbar.h"

static const CGFloat PillHeight = 32;
static const CGFloat RailRowHeight = 38;
static const CGFloat ItemGap = 4;
static const CGFloat PillPadding = 12;
static const CGFloat MaxPillWidth = 160;
static const CGFloat AddWidth = 36;
static const CGFloat EditWidth = 150;

// Soft glass pill in the same neutral palette as OCToolbarCapsule (search field, ⋯ button), a bit
// brighter so it reads as selected. The inline name field adds only a faint accent outline.
static void DrawGlass(NSRect rect, BOOL editing) {
    BOOL dark = [[NSAppearance.currentDrawingAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
    BOOL contrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect,0.5,0.5) xRadius:11 yRadius:11];
    CGFloat fillAlpha = dark ? (editing ? 0.20 : 0.15) : (editing ? 0.75 : 0.55);
    [[NSColor.whiteColor colorWithAlphaComponent:fillAlpha] setFill];
    [shape fill];
    NSColor *stroke = editing
        ? [NSColor.controlAccentColor colorWithAlphaComponent:contrast ? 0.9 : 0.45]
        : [(dark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:contrast ? 0.6 : dark ? 0.26 : 0.12];
    [stroke setStroke];
    shape.lineWidth = 1;
    [shape stroke];
}

static NSImage *TintedSymbol(NSString *name, CGFloat size, NSColor *color) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:size
        weight:NSFontWeightSemibold] configurationByApplyingConfiguration:
        [NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    return [image imageWithSymbolConfiguration:config];
}

NSArray<NSDictionary *> *OCTabPalette(void) {
    return @[@{@"key":@"red",@"title":OCText(@"Merah", @"Red")}, @{@"key":@"orange",@"title":OCText(@"Oranye", @"Orange")},
        @{@"key":@"yellow",@"title":OCText(@"Kuning", @"Yellow")}, @{@"key":@"green",@"title":OCText(@"Hijau", @"Green")},
        @{@"key":@"teal",@"title":@"Teal"}, @{@"key":@"blue",@"title":OCText(@"Biru", @"Blue")},
        @{@"key":@"purple",@"title":OCText(@"Ungu", @"Purple")}, @{@"key":@"pink",@"title":OCText(@"Merah muda", @"Pink")},
        @{@"key":@"gray",@"title":OCText(@"Abu-abu", @"Gray")}];
}

NSColor *OCTabColor(NSString *key, int64_t collectionID) {
    NSDictionary<NSString *, NSColor *> *colors = @{
        @"red":NSColor.systemRedColor, @"orange":NSColor.systemOrangeColor, @"yellow":NSColor.systemYellowColor,
        @"green":NSColor.systemGreenColor, @"teal":NSColor.systemTealColor, @"blue":NSColor.systemBlueColor,
        @"purple":NSColor.systemPurpleColor, @"pink":NSColor.systemPinkColor, @"gray":NSColor.systemGrayColor};
    return colors[key ?: @""] ?: [NSColor colorWithHue:oc_tab_hue(collectionID) saturation:0.65 brightness:0.9 alpha:1];
}

@interface OCTabElement : NSAccessibilityElement
@property(nonatomic, copy) void (^press)(void);
@property(nonatomic) BOOL selected;
@end

@implementation OCTabElement
- (BOOL)accessibilityPerformPress {
    if (self.press) self.press();
    return YES;
}
- (id)accessibilityValue { return @(self.selected); }
@end

@interface OCTabs () <NSTextFieldDelegate>
@property(nonatomic) CGFloat offset;
@property(nonatomic, strong) NSTrackingArea *pointerTracking;
@property(nonatomic) BOOL pointerInside;
@property(nonatomic, strong) NSTextField *editor;
@property(nonatomic) int64_t editingID;
@property(nonatomic, copy) NSString *editingInitial;
@end

@implementation OCTabs

- (instancetype)initWithFrame:(NSRect)frame orientation:(OCTabsOrientation)orientation {
    self = [super initWithFrame:frame];
    if (self) {
        _orientation = orientation;
        _collections = @[];
        self.focusRingType = NSFocusRingTypeDefault;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)needsPanelToBecomeKey { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; [self noteFocusRingMaskChanged]; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return YES; }

- (NSInteger)tabCount { return (NSInteger)self.collections.count + 1; }
- (BOOL)editing { return self.editor != nil; }

// Index of the item being edited, or -1. A new collection edits a slot after the last tab.
- (NSInteger)editingIndex {
    if (!self.editor) return -1;
    if (self.editingID == 0) return self.tabCount;
    for (NSUInteger i = 0; i < self.collections.count; i++) {
        if ([self.collections[i][@"id"] longLongValue] == self.editingID) return (NSInteger)i + 1;
    }
    return -1;
}

// Index of the "+" item: it moves one slot over while a new collection is being named.
- (NSInteger)plusIndex { return self.tabCount + (self.editor && self.editingID == 0 ? 1 : 0); }

- (int64_t)collectionIDAtIndex:(NSInteger)index {
    if (index <= 0) return 0;
    index = MIN(index, self.tabCount - 1);
    return [self.collections[(NSUInteger)index - 1][@"id"] longLongValue];
}

- (NSInteger)selectedIndex {
    for (NSUInteger i = 0; i < self.collections.count; i++) {
        if ([self.collections[i][@"id"] longLongValue] == self.selectedID) return (NSInteger)i + 1;
    }
    return 0;
}

- (NSString *)titleAtIndex:(NSInteger)index {
    if (index >= self.tabCount) return @"";
    return index == 0 ? OCText(@"Riwayat", @"History") : self.collections[(NSUInteger)index - 1][@"name"] ?: @"";
}

- (void)setCollections:(NSArray<NSDictionary *> *)collections {
    _collections = [collections copy] ?: @[];
    if (self.editor && self.editingIndex < 0) [self endEditingCommit:NO];
    [self clampOffset];
    [self layoutEditor];
    self.needsDisplay = YES;
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}

- (void)setSelectedID:(int64_t)selectedID {
    _selectedID = selectedID;
    self.needsDisplay = YES;
    [self noteFocusRingMaskChanged];
}

#pragma mark Layout

- (NSFont *)font { return [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; }

- (CGFloat)pillWidthAtIndex:(NSInteger)index {
    if (index == self.editingIndex) return EditWidth;
    CGFloat text = ceil([[self titleAtIndex:index] sizeWithAttributes:@{NSFontAttributeName:self.font}].width);
    return MIN(MaxPillWidth, PillPadding*2 + (index == 0 ? 15 : 9) + 7 + text);
}

// Frame of item `index` in content coordinates (before scrolling). `plusIndex` is "+".
- (NSRect)contentFrameAtIndex:(NSInteger)index {
    if (self.orientation == OCTabsVertical) {
        return NSMakeRect(0, 5 + index * RailRowHeight, NSWidth(self.bounds), RailRowHeight);
    }
    CGFloat x = 0;
    for (NSInteger i = 0; i < index && i < self.plusIndex; i++) x += [self pillWidthAtIndex:i] + ItemGap;
    CGFloat width = index == self.plusIndex ? AddWidth : [self pillWidthAtIndex:index];
    return NSMakeRect(x, (NSHeight(self.bounds)-PillHeight)/2, width, PillHeight);
}

- (NSRect)frameAtIndex:(NSInteger)index {
    NSRect frame = [self contentFrameAtIndex:index];
    if (self.orientation == OCTabsVertical) frame.origin.y -= self.offset;
    else frame.origin.x -= self.offset;
    return frame;
}

- (CGFloat)contentLength {
    NSRect last = [self contentFrameAtIndex:self.plusIndex];
    return self.orientation == OCTabsVertical ? NSMaxY(last) + 4 : NSMaxX(last);
}

- (CGFloat)viewportLength {
    return self.orientation == OCTabsVertical ? NSHeight(self.bounds) : NSWidth(self.bounds);
}

- (void)clampOffset {
    self.offset = MAX(0, MIN(self.offset, [self contentLength] - [self viewportLength]));
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self clampOffset];
    [self layoutEditor];
    self.needsDisplay = YES;
}

- (void)scrollSelectedToVisible { [self scrollIndexToVisible:self.selectedIndex]; }

- (void)scrollIndexToVisible:(NSInteger)index {
    NSRect frame = [self contentFrameAtIndex:index];
    BOOL vertical = self.orientation == OCTabsVertical;
    CGFloat start = vertical ? NSMinY(frame) : NSMinX(frame), end = vertical ? NSMaxY(frame) : NSMaxX(frame);
    CGFloat viewport = [self viewportLength];
    if (start < self.offset) self.offset = start;
    else if (end > self.offset + viewport) self.offset = end - viewport;
    [self clampOffset];
    [self layoutEditor];
    self.needsDisplay = YES;
}

- (NSInteger)itemAtPoint:(NSPoint)point {
    for (NSInteger i = 0; i <= self.plusIndex; i++) {
        if (NSPointInRect(point, [self frameAtIndex:i])) return i;
    }
    return -1;
}

#pragma mark Drawing

- (NSRect)selectionRect {
    return NSInsetRect([self frameAtIndex:self.selectedIndex], self.orientation == OCTabsVertical ? 4 : 0,
                       self.orientation == OCTabsVertical ? 2 : 0);
}

- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:[self selectionRect] xRadius:11 yRadius:11] fill];
}
- (NSRect)focusRingMaskBounds { return [self selectionRect]; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.pointerTracking) [self removeTrackingArea:self.pointerTracking];
    self.pointerTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.pointerTracking];
}

- (void)mouseEntered:(NSEvent *)event { self.pointerInside = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { self.pointerInside = NO; self.needsDisplay = YES; }
- (void)mouseMoved:(NSEvent *)event { self.pointerInside = YES; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirtyRect {
    BOOL vertical = self.orientation == OCTabsVertical;
    BOOL contrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    NSInteger selected = self.selectedIndex;
    NSInteger hovered = self.pointerInside && self.window.isKeyWindow
        ? [self itemAtPoint:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]] : -1;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;

    NSInteger editing = self.editingIndex;
    for (NSInteger i = 0; i < self.tabCount; i++) {
        NSRect frame = [self frameAtIndex:i];
        if (!NSIntersectsRect(frame, dirtyRect) || i == editing) continue;
        // While naming a collection only the name field looks active.
        BOOL active = i == selected && editing < 0;
        NSRect pill = vertical ? NSInsetRect(frame, 4, 2) : frame;
        if (active) DrawGlass(pill, NO);
        else if (i == hovered) {
            [[NSColor.labelColor colorWithAlphaComponent:contrast ? 0.16 : 0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:11 yRadius:11] fill];
        }
        NSColor *textColor = active || contrast ? NSColor.labelColor : NSColor.secondaryLabelColor;
        CGFloat left = NSMinX(pill) + (vertical ? 10 : PillPadding);
        if (i == 0) {
            NSImage *symbol = TintedSymbol(@"clock", 12, textColor);
            NSSize size = symbol.size;
            [symbol drawInRect:NSMakeRect(left, NSMidY(pill)-size.height/2, size.width, size.height)
                fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                respectFlipped:YES hints:nil];
            left += 15 + 7;
        } else {
            NSDictionary *collection = self.collections[(NSUInteger)i-1];
            [OCTabColor(collection[@"color"], [collection[@"id"] longLongValue]) setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(left, NSMidY(pill)-4.5, 9, 9)] fill];
            left += 9 + 7;
        }
        NSRect textRect = NSMakeRect(left, NSMidY(pill)-9, MAX(0, NSMaxX(pill) - left - (vertical ? 8 : PillPadding)), 18);
        [[self titleAtIndex:i] drawWithRect:textRect
            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:@{NSFontAttributeName:self.font, NSForegroundColorAttributeName:textColor,
                NSParagraphStyleAttributeName:style}];
    }

    if (editing >= 0) {
        NSRect frame = [self frameAtIndex:editing];
        NSRect pill = vertical ? NSInsetRect(frame, 4, 2) : frame;
        DrawGlass(pill, YES);
    }

    NSRect add = [self frameAtIndex:self.plusIndex];
    if (NSIntersectsRect(add, dirtyRect)) {
        BOOL addHovered = hovered == self.plusIndex;
        if (addHovered) {
            NSRect pill = vertical ? NSInsetRect(add, 4, 2) : add;
            [[NSColor.labelColor colorWithAlphaComponent:contrast ? 0.16 : 0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:11 yRadius:11] fill];
        }
        NSImage *symbol = TintedSymbol(@"plus", 13, addHovered ? NSColor.labelColor : NSColor.secondaryLabelColor);
        NSSize size = symbol.size;
        NSRect target = vertical
            ? NSMakeRect(NSMinX(add)+14, NSMidY(add)-size.height/2, size.width, size.height)
            : NSMakeRect(NSMidX(add)-size.width/2, NSMidY(add)-size.height/2, size.width, size.height);
        [symbol drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:1 respectFlipped:YES hints:nil];
    }
}

#pragma mark Input

- (void)mouseDown:(NSEvent *)event {
    NSInteger index = [self itemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index < 0) {
        if (self.onClickEmpty) self.onClickEmpty();
        return;
    }
    [self.window makeFirstResponder:self];
    if (index == self.plusIndex) { if (self.onAdd) self.onAdd(); return; }
    if (index == self.editingIndex) return;
    if (self.onSelect) self.onSelect([self collectionIDAtIndex:index]);
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSInteger index = [self itemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index <= 0 || index >= self.tabCount || index == self.editingIndex || !self.onContext) return nil;
    return self.onContext([self collectionIDAtIndex:index]);
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat dx = event.scrollingDeltaX, dy = event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas) { dx *= 10; dy *= 10; }
    CGFloat delta = self.orientation == OCTabsVertical ? dy : (fabs(dx) > fabs(dy) ? dx : dy);
    self.offset -= delta;
    [self clampOffset];
    [self layoutEditor];
    self.needsDisplay = YES;
}

#pragma mark Inline editing

- (void)layoutEditor {
    NSInteger index = self.editingIndex;
    if (!self.editor || index < 0) return;
    BOOL vertical = self.orientation == OCTabsVertical;
    NSRect frame = [self frameAtIndex:index];
    NSRect pill = vertical ? NSInsetRect(frame, 4, 2) : frame;
    CGFloat inset = vertical ? 10 : PillPadding;
    self.editor.frame = NSMakeRect(NSMinX(pill)+inset, NSMidY(pill)-9, MAX(20,NSWidth(pill)-2*inset), 18);
}

- (void)beginEditingCollectionID:(int64_t)collectionID {
    if (self.editor) [self endEditingCommit:NO];
    NSString *initial = @"";
    if (collectionID) {
        initial = nil;
        for (NSDictionary *collection in self.collections) {
            if ([collection[@"id"] longLongValue] == collectionID) initial = collection[@"name"] ?: @"";
        }
        if (!initial) return;
    }
    self.editingID = collectionID;
    self.editingInitial = initial;
    NSTextField *field = [OCEditableTextField textFieldWithString:initial];
    field.placeholderString = self.orientation == OCTabsVertical ? OCText(@"Nama baru", @"New name") : OCText(@"Nama koleksi", @"Collection name");
    field.font = self.font;
    field.bordered = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.usesSingleLineMode = YES;
    field.delegate = self;
    [field setAccessibilityLabel:collectionID ? OCText(@"Ubah nama koleksi", @"Rename collection") : OCText(@"Nama koleksi baru", @"New collection name")];
    self.editor = field;
    [self addSubview:field];
    [self scrollIndexToVisible:self.editingIndex];
    [self.window makeFirstResponder:field];
    // Not -selectText:, which ends editing and would cancel the field right away.
    NSText *editor = field.currentEditor;
    editor.selectedRange = NSMakeRange(0,editor.string.length);
    self.needsDisplay = YES;
}

- (void)cancelEditing { [self endEditingCommit:NO]; }

- (void)endEditingCommit:(BOOL)commit {
    NSTextField *field = self.editor;
    if (!field) return;
    NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    int64_t identifier = self.editingID;
    BOOL changed = name.length && ![name isEqualToString:self.editingInitial];
    self.editor = nil;
    field.delegate = nil;
    if (field.window.firstResponder == field.currentEditor || field.window.firstResponder == field)
        [self.window makeFirstResponder:self];
    [field removeFromSuperview];
    [self clampOffset];
    self.needsDisplay = YES;
    if (commit && changed && self.onCommit) self.onCommit(identifier,name);
    if (self.onEndEditing) self.onEndEditing();
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (control != self.editor) return NO;
    if (selector == @selector(insertNewline:)) { [self endEditingCommit:YES]; return YES; }
    if (selector == @selector(cancelOperation:)) { [self endEditingCommit:NO]; return YES; }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.editor) [self endEditingCommit:NO];
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTabGroupRole; }
- (NSString *)accessibilityLabel { return OCText(@"Koleksi", @"Collections"); }

- (NSArray *)accessibilityChildren {
    NSMutableArray *elements = [NSMutableArray array];
    __weak OCTabs *weakSelf = self;
    for (NSInteger i = 0; i <= self.tabCount; i++) {
        BOOL add = i == self.tabCount;
        NSRect screen = [self.window convertRectToScreen:[self convertRect:[self frameAtIndex:add ? self.plusIndex : i]
                                                                    toView:nil]];
        OCTabElement *element = [OCTabElement accessibilityElementWithRole:NSAccessibilityRadioButtonRole
            frame:screen label:add ? OCText(@"Tambah koleksi", @"Add collection") : i == 0 ? OCText(@"Riwayat", @"History")
                : [NSString stringWithFormat:OCText(@"Koleksi %@", @"Collection %@"),[self titleAtIndex:i]] parent:self];
        element.selected = !add && i == self.selectedIndex;
        element.press = ^{
            OCTabs *tabs = weakSelf;
            if (!tabs) return;
            if (add) { if (tabs.onAdd) tabs.onAdd(); }
            else if (tabs.onSelect) tabs.onSelect([tabs collectionIDAtIndex:i]);
        };
        [elements addObject:element];
    }
    return elements;
}

- (NSArray *)accessibilityTabs {
    NSArray *children = [self accessibilityChildren];
    return [children subarrayWithRange:NSMakeRange(0, children.count - 1)];
}

@end
