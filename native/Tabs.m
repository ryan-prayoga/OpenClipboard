#import "Tabs.h"
#import "Bridge.h"

static const CGFloat PillHeight = 28;
static const CGFloat RailRowHeight = 30;
static const CGFloat ItemGap = 4;
static const CGFloat PillPadding = 12;
static const CGFloat MaxPillWidth = 160;
static const CGFloat AddWidth = 34;

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

@interface OCTabs ()
@property(nonatomic) CGFloat offset;
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
    return index == 0 ? @"Riwayat" : self.collections[(NSUInteger)index - 1][@"name"] ?: @"";
}

- (void)setCollections:(NSArray<NSDictionary *> *)collections {
    _collections = [collections copy] ?: @[];
    [self clampOffset];
    self.needsDisplay = YES;
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}

- (void)setSelectedID:(int64_t)selectedID {
    _selectedID = selectedID;
    self.needsDisplay = YES;
    [self noteFocusRingMaskChanged];
}

#pragma mark Layout

- (NSFont *)font { return [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]; }

- (CGFloat)pillWidthAtIndex:(NSInteger)index {
    CGFloat text = ceil([[self titleAtIndex:index] sizeWithAttributes:@{NSFontAttributeName:self.font}].width);
    return MIN(MaxPillWidth, PillPadding*2 + (index == 0 ? 14 : 8) + 6 + text);
}

// Frame of item `index` in content coordinates (before scrolling). Index tabCount is "+".
- (NSRect)contentFrameAtIndex:(NSInteger)index {
    if (self.orientation == OCTabsVertical) {
        return NSMakeRect(0, index * RailRowHeight, NSWidth(self.bounds), RailRowHeight);
    }
    CGFloat x = 0;
    for (NSInteger i = 0; i < index && i < self.tabCount; i++) x += [self pillWidthAtIndex:i] + ItemGap;
    CGFloat width = index == self.tabCount ? AddWidth : [self pillWidthAtIndex:index];
    return NSMakeRect(x, (NSHeight(self.bounds)-PillHeight)/2, width, PillHeight);
}

- (NSRect)frameAtIndex:(NSInteger)index {
    NSRect frame = [self contentFrameAtIndex:index];
    if (self.orientation == OCTabsVertical) frame.origin.y -= self.offset;
    else frame.origin.x -= self.offset;
    return frame;
}

- (CGFloat)contentLength {
    NSRect last = [self contentFrameAtIndex:self.tabCount];
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
    self.needsDisplay = YES;
}

- (void)scrollSelectedToVisible {
    NSRect frame = [self contentFrameAtIndex:self.selectedIndex];
    BOOL vertical = self.orientation == OCTabsVertical;
    CGFloat start = vertical ? NSMinY(frame) : NSMinX(frame), end = vertical ? NSMaxY(frame) : NSMaxX(frame);
    CGFloat viewport = [self viewportLength];
    if (start < self.offset) self.offset = start;
    else if (end > self.offset + viewport) self.offset = end - viewport;
    [self clampOffset];
    self.needsDisplay = YES;
}

- (NSInteger)itemAtPoint:(NSPoint)point {
    for (NSInteger i = 0; i <= self.tabCount; i++) {
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
    [[NSBezierPath bezierPathWithRoundedRect:[self selectionRect] xRadius:9 yRadius:9] fill];
}
- (NSRect)focusRingMaskBounds { return [self selectionRect]; }

- (void)drawRect:(NSRect)dirtyRect {
    BOOL vertical = self.orientation == OCTabsVertical;
    BOOL contrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    NSInteger selected = self.selectedIndex;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;

    if (vertical) {
        [[NSColor.separatorColor colorWithAlphaComponent:contrast ? 1 : 0.6] setFill];
        NSRectFill(NSMakeRect(NSWidth(self.bounds)-1, 0, 1, NSHeight(self.bounds)));
    }
    for (NSInteger i = 0; i < self.tabCount; i++) {
        NSRect frame = [self frameAtIndex:i];
        if (!NSIntersectsRect(frame, dirtyRect)) continue;
        BOOL active = i == selected;
        NSRect pill = vertical ? NSInsetRect(frame, 4, 2) : frame;
        if (active) {
            NSColor *fill = vertical ? NSColor.controlAccentColor
                : [NSColor.labelColor colorWithAlphaComponent:contrast ? 0.22 : 0.12];
            [fill setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:9 yRadius:9] fill];
        }
        NSColor *textColor = active && vertical ? NSColor.alternateSelectedControlTextColor
            : active ? NSColor.labelColor : NSColor.secondaryLabelColor;
        CGFloat left = NSMinX(pill) + (vertical ? 10 : PillPadding);
        if (i == 0) {
            NSImage *clock = [NSImage imageWithSystemSymbolName:@"clock" accessibilityDescription:nil];
            NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:11
                weight:NSFontWeightSemibold];
            NSImage *symbol = [clock imageWithSymbolConfiguration:config];
            NSSize size = symbol.size;
            [symbol drawInRect:NSMakeRect(left, NSMidY(pill)-size.height/2, size.width, size.height)
                fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:active ? 1 : 0.75
                respectFlipped:YES hints:nil];
            left += 14 + 6;
        } else {
            int64_t identifier = [self.collections[(NSUInteger)i-1][@"id"] longLongValue];
            NSColor *dot = [NSColor colorWithHue:oc_tab_hue(identifier) saturation:0.65 brightness:0.9 alpha:1];
            [dot setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(left, NSMidY(pill)-4, 8, 8)] fill];
            left += 8 + 6;
        }
        NSRect textRect = NSMakeRect(left, NSMidY(pill)-8, MAX(0, NSMaxX(pill) - left - (vertical ? 8 : PillPadding)), 16);
        [[self titleAtIndex:i] drawWithRect:textRect
            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:@{NSFontAttributeName:self.font, NSForegroundColorAttributeName:textColor,
                NSParagraphStyleAttributeName:style}];
    }

    NSRect add = [self frameAtIndex:self.tabCount];
    if (NSIntersectsRect(add, dirtyRect)) {
        NSImage *plus = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];
        NSImage *symbol = [plus imageWithSymbolConfiguration:[NSImageSymbolConfiguration
            configurationWithPointSize:12 weight:NSFontWeightSemibold]];
        NSSize size = symbol.size;
        NSRect target = vertical
            ? NSMakeRect(NSMinX(add)+14, NSMidY(add)-size.height/2, size.width, size.height)
            : NSMakeRect(NSMidX(add)-size.width/2, NSMidY(add)-size.height/2, size.width, size.height);
        [symbol drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:0.8 respectFlipped:YES hints:nil];
    }
}

#pragma mark Input

- (void)mouseDown:(NSEvent *)event {
    NSInteger index = [self itemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index < 0) return;
    [self.window makeFirstResponder:self];
    if (index == self.tabCount) { if (self.onAdd) self.onAdd(); return; }
    if (self.onSelect) self.onSelect([self collectionIDAtIndex:index]);
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSInteger index = [self itemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index <= 0 || index >= self.tabCount || !self.onContext) return nil;
    return self.onContext([self collectionIDAtIndex:index]);
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat dx = event.scrollingDeltaX, dy = event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas) { dx *= 10; dy *= 10; }
    CGFloat delta = self.orientation == OCTabsVertical ? dy : (fabs(dx) > fabs(dy) ? dx : dy);
    self.offset -= delta;
    [self clampOffset];
    self.needsDisplay = YES;
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTabGroupRole; }
- (NSString *)accessibilityLabel { return @"Koleksi"; }

- (NSArray *)accessibilityChildren {
    NSMutableArray *elements = [NSMutableArray array];
    __weak OCTabs *weakSelf = self;
    for (NSInteger i = 0; i <= self.tabCount; i++) {
        BOOL add = i == self.tabCount;
        NSRect screen = [self.window convertRectToScreen:[self convertRect:[self frameAtIndex:i] toView:nil]];
        OCTabElement *element = [OCTabElement accessibilityElementWithRole:NSAccessibilityRadioButtonRole
            frame:screen label:add ? @"Tambah koleksi" : i == 0 ? @"Riwayat"
                : [NSString stringWithFormat:@"Koleksi %@",[self titleAtIndex:i]] parent:self];
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
