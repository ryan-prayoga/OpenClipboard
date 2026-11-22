#import "Results.h"

static CGFloat const CardWidth = 224;
static CGFloat const CardStep = 237;
static CGFloat const CardHeight = 208;
static CGFloat const CardVerticalInset = 5;
static CGFloat const PreviewHeight = 120;
static CGFloat const CardInset = 12;
static CGFloat const RowHeight = 47;
static CGFloat const ImageRowHeight = 83;
static CGFloat const RowInset = 5;

static NSString *KindLabel(NSString *kind) {
    return @{@"teks":@"Teks", @"url":@"Tautan", @"json":@"JSON", @"kode":@"Kode",
        @"warna":@"Warna", @"gambar":@"Gambar", @"sensitif":@"Sensitif"}[kind] ?: @"Teks";
}

static NSString *KindIcon(NSString *kind) {
    return @{@"teks":@"text.alignleft", @"url":@"link", @"json":@"curlybraces",
        @"kode":@"chevron.left.forwardslash.chevron.right", @"warna":@"paintpalette",
        @"gambar":@"photo", @"sensitif":@"eye.slash"}[kind] ?: @"text.alignleft";
}

static NSURL *DragImageDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"OpenClipboard.XXXXXXXX"];
    char *name = strdup(path.fileSystemRepresentation);
    NSURL *directory = name && mkdtemp(name)
        ? [NSURL fileURLWithFileSystemRepresentation:name isDirectory:YES relativeToURL:nil] : nil;
    free(name);
    return directory;
}

static void AddDragFile(NSPasteboardItem *item, NSUInteger number, NSURL **directory) {
    NSData *png = [item dataForType:NSPasteboardTypePNG];
    if (!png.length) {
        NSData *tiff = [item dataForType:NSPasteboardTypeTIFF];
        if (tiff.length) {
            NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithData:tiff];
            png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        }
    }
    if (!png.length) return;
    if (!*directory) *directory = DragImageDirectory();
    NSString *name = [NSString stringWithFormat:@"OpenClipboard-%lu.png",(unsigned long)number];
    NSURL *file = [*directory URLByAppendingPathComponent:name isDirectory:NO];
    if (file && [png writeToURL:file options:NSDataWritingAtomic error:nil])
        [item setString:file.absoluteString forType:NSPasteboardTypeFileURL];
}

static NSDictionary *TextAttributes(NSFont *font, NSColor *color) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{NSFontAttributeName:font, NSForegroundColorAttributeName:color,
        NSParagraphStyleAttributeName:paragraph};
}

static void DrawText(NSString *s, NSRect rect, CGFloat size, NSFontWeight weight, NSColor *color) {
    [s drawInRect:rect withAttributes:TextAttributes([NSFont systemFontOfSize:size weight:weight], color)];
}

static BOOL DarkAppearance(void) {
    return [[NSAppearance.currentDrawingAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

static BOOL IncreaseContrast(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
}

// Metadata text switches to the primary label color when Increase Contrast is on.
static NSColor *Secondary(void) {
    return IncreaseContrast() ? NSColor.labelColor : NSColor.secondaryLabelColor;
}

static NSColor *KindColor(NSString *kind) {
    return @{@"teks":NSColor.systemBlueColor, @"url":NSColor.systemTealColor,
        @"gambar":NSColor.systemPurpleColor, @"json":NSColor.systemOrangeColor,
        @"kode":NSColor.systemIndigoColor, @"warna":NSColor.systemPinkColor,
        @"sensitif":NSColor.systemGrayColor}[kind] ?: NSColor.systemBlueColor;
}

static NSBezierPath *Rounded(NSRect rect, CGFloat radius) {
    return [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
}

static NSImage *SymbolTinted(NSString *name, NSColor *tint) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *color = [NSImageSymbolConfiguration
        configurationWithHierarchicalColor:tint];
    return [image imageWithSymbolConfiguration:color];
}

static NSImage *Symbol(NSString *name) {
    return SymbolTinted(name, Secondary());
}

static void DrawImage(NSImage *image, NSRect rect) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) return;
    CGFloat factor = MIN(rect.size.width / image.size.width, rect.size.height / image.size.height);
    NSSize fitted = NSMakeSize(image.size.width * factor, image.size.height * factor);
    [image drawInRect:NSMakeRect(NSMidX(rect) - fitted.width / 2, NSMidY(rect) - fitted.height / 2,
                    fitted.width, fitted.height)
             fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES
                 hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
}

static void DrawMultiline(NSString *text, NSRect rect, NSFont *font, NSColor *color) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    style.lineSpacing = 2;
    [text drawWithRect:rect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
        attributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:color,
            NSParagraphStyleAttributeName:style} context:nil];
}

// Today shows the time. Older clips show "Kemarin" or a date, since history can span a year.
static NSString *ActivityTime(NSNumber *timestamp) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue / 1000.0];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if ([calendar isDateInToday:date]) {
        return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterNoStyle
                                              timeStyle:NSDateFormatterShortStyle];
    }
    if ([calendar isDateInYesterday:date]) return @"Kemarin";
    if ([calendar component:NSCalendarUnitYear fromDate:date] != [calendar component:NSCalendarUnitYear fromDate:NSDate.date]) {
        return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle
                                              timeStyle:NSDateFormatterNoStyle];
    }
    static NSDateFormatter *sameYear;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sameYear = [NSDateFormatter new];
        [sameYear setLocalizedDateFormatFromTemplate:@"dMMM"];
    });
    return [sameYear stringFromDate:date];
}

static NSColor *Swatch(NSString *hex) {
    if (![hex hasPrefix:@"#"]) return nil;
    NSString *digits = [hex substringFromIndex:1];
    unsigned value = 0;
    if (![[NSScanner scannerWithString:digits] scanHexInt:&value]) return nil;
    if (digits.length == 3 || digits.length == 4) {
        if (digits.length == 4) value >>= 4;
        return [NSColor colorWithSRGBRed:((value >> 8) & 15) / 15.0 green:((value >> 4) & 15) / 15.0
                                   blue:(value & 15) / 15.0 alpha:1];
    }
    if (digits.length == 8) value >>= 8;
    if (digits.length != 6 && digits.length != 8) return nil;
    return [NSColor colorWithSRGBRed:((value >> 16) & 255) / 255.0 green:((value >> 8) & 255) / 255.0
                               blue:(value & 255) / 255.0 alpha:1];
}

@interface OCRowAccessibility : NSAccessibilityElement
@property(nonatomic, weak) OCResults *results;
@property(nonatomic) NSInteger index;
@end

@implementation OCRowAccessibility
- (BOOL)accessibilityPerformPress {
    if (self.results.actionsSuspended || !self.results.picked) return NO;
    self.results.picked(self.index, OCResultConfirm);
    return YES;
}
- (BOOL)isAccessibilitySelected {
    return [self.results.selectedIndexes containsIndex:(NSUInteger)self.index];
}
@end

@interface OCResults () <NSDraggingSource>
@property(nonatomic, copy) NSData *compactRowOffsets;
@property(nonatomic, copy, readwrite) NSIndexSet *selectedIndexes;
@property(nonatomic) NSInteger selectionAnchor;
@property(nonatomic, copy) NSArray<OCRowAccessibility *> *accessibleRows;
@property(nonatomic, strong) NSTextField *emptyTitle;
@property(nonatomic, strong) NSTextField *emptyDetail;
@property(nonatomic, strong) NSNumber *lastClickID;
@property(nonatomic) NSTimeInterval lastClickAt;
@property(nonatomic) NSPoint lastClickPoint;
@property(nonatomic, strong) NSNumber *pressedClipID;
@property(nonatomic, strong) NSEvent *dragEvent;
@property(nonatomic, strong) NSURL *dragImageDirectory;
@property(nonatomic) NSPoint pressPoint;
@property(nonatomic) OCResultAction deferredClick;
@property(nonatomic) BOOL clickDeferred;
@end

@implementation OCResults
+ (CGFloat)cardViewportHeight {
    return CardHeight + 2*CardVerticalInset;
}

+ (CGFloat)compactViewportHeightWithin:(CGFloat)available {
    CGFloat rows = MIN(7,floor((available-RowInset)/RowHeight));
    return rows > 0 ? RowInset + rows*RowHeight : available;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _rows = @[];
        _selected = -1;
        _selectionAnchor = -1;
        _selectedIndexes = [NSIndexSet indexSet];
        _emptyTitle = OCLabel(@"",14,NSFontWeightMedium);
        _emptyTitle.hidden = YES;
        [self addSubview:_emptyTitle];
        _emptyDetail = [NSTextField wrappingLabelWithString:@""];
        _emptyDetail.font = [NSFont systemFontOfSize:12];
        _emptyDetail.textColor = Secondary();
        _emptyDetail.hidden = YES;
        [self addSubview:_emptyDetail];
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityGroupRole];
        [self setAccessibilityLabel:@"Hasil clipboard"];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setRows:(NSArray<NSDictionary *> *)rows {
    _rows = [rows copy];
    NSMutableData *offsets = [NSMutableData dataWithLength:(_rows.count + 1) * sizeof(CGFloat)];
    CGFloat *positions = offsets.mutableBytes;
    positions[0] = RowInset;
    for (NSUInteger index = 0; index < _rows.count; index++) {
        BOOL image = [_rows[index][@"kind"] isEqualToString:@"gambar"];
        positions[index + 1] = positions[index] + (image ? ImageRowHeight : RowHeight);
    }
    self.compactRowOffsets = offsets;
}

- (NSInteger)compactRowIndexAtY:(CGFloat)y {
    const CGFloat *positions = self.compactRowOffsets.bytes;
    NSUInteger first = 0, end = self.rows.count;
    while (first < end) {
        NSUInteger mid = first + (end - first) / 2;
        if (positions[mid + 1] <= y) first = mid + 1;
        else end = mid;
    }
    return (NSInteger)first;
}

- (NSRect)rowFrame:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.rows.count) return NSZeroRect;
    if (self.horizontal) return NSMakeRect(3 + index * CardStep, CardVerticalInset, CardWidth, CardHeight);
    const CGFloat *positions = self.compactRowOffsets.bytes;
    CGFloat top = positions[index];
    return NSMakeRect(3, top, MAX(0, self.bounds.size.width - 6), positions[index + 1] - top - 3);
}

- (void)layoutRows {
    NSSize viewport = self.enclosingScrollView.contentSize;
    if (viewport.width < 1) return;
    CGFloat height = self.rows.count ? NSMaxY([self rowFrame:(NSInteger)self.rows.count - 1]) + 8 : 60;
    CGFloat width = self.horizontal ? 4 + self.rows.count * CardStep : viewport.width;
    [self setFrameSize:NSMakeSize(MAX(viewport.width,width), MAX(viewport.height,height))];
    CGFloat textWidth = MAX(0,viewport.width - 32);
    self.emptyTitle.frame = NSMakeRect(16,7,textWidth,20);
    self.emptyDetail.frame = NSMakeRect(16,28,textWidth,MAX(0,viewport.height - 30));
    self.emptyTitle.hidden = self.rows.count || !self.emptyTitle.stringValue.length;
    self.emptyDetail.hidden = self.rows.count || !self.emptyDetail.stringValue.length;
    self.needsDisplay = YES;
}

- (void)showEmptyTitle:(NSString *)title detail:(NSString *)detail announce:(BOOL)announce {
    NSString *message = title ?: @"";
    BOOL changed = self.emptyTitle.hidden || ![message isEqualToString:self.emptyTitle.stringValue];
    self.emptyTitle.stringValue = message;
    self.emptyDetail.stringValue = detail ?: @"";
    if (announce && changed && !self.rows.count && message.length) {
        NSAccessibilityPostNotificationWithUserInfo(self.window,NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey:message,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityMedium)});
    }
}

- (void)invalidateClip:(NSNumber *)identifier {
    if (!identifier) return;
    NSUInteger index = [self.rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, __unused NSUInteger index, __unused BOOL *stop) {
        return [row[@"id"] isEqual:identifier];
    }];
    if (index != NSNotFound) [self setNeedsDisplayInRect:[self rowFrame:(NSInteger)index]];
}

- (void)setActionsSuspended:(BOOL)actionsSuspended {
    if (_actionsSuspended == actionsSuspended) return;
    _actionsSuspended = actionsSuspended;
    self.lastClickID = nil;
    if (actionsSuspended) {
        self.pressedClipID = nil;
        self.dragEvent = nil;
        self.clickDeferred = NO;
        NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
    }
}

- (void)setPreparingDrag:(BOOL)preparingDrag {
    if (_preparingDrag == preparingDrag) return;
    _preparingDrag = preparingDrag;
    [self invalidateClip:self.pressedClipID];
}

- (NSArray<NSDictionary *> *)visibleRows {
    NSRect visible = self.visibleRect;
    if (!self.horizontal) {
        NSInteger first = [self compactRowIndexAtY:NSMinY(visible)];
        NSMutableArray *visibleRows = [NSMutableArray array];
        for (NSInteger i = first; (NSUInteger)i < self.rows.count; i++) {
            NSRect rect = [self rowFrame:i];
            if (NSMinY(rect) > NSMaxY(visible)) break;
            if (NSIntersectsRect(rect, visible)) [visibleRows addObject:self.rows[(NSUInteger)i]];
        }
        return visibleRows;
    }
    NSUInteger start = MAX(0, (NSInteger)floor(visible.origin.x / CardStep));
    NSUInteger end = MIN(self.rows.count, (NSUInteger)ceil(NSMaxX(visible) / CardStep) + 1);
    if (start >= end) return @[];
    return [self.rows subarrayWithRange:NSMakeRange(start, end - start)];
}

- (void)setSelected:(NSInteger)selected {
    if (selected < 0 || (NSUInteger)selected >= self.rows.count) selected = -1;
    NSIndexSet *indexes = selected < 0 ? [NSIndexSet indexSet] : [NSIndexSet indexSetWithIndex:(NSUInteger)selected];
    [self setSelection:indexes lead:selected anchor:selected];
}

- (void)setSelection:(NSIndexSet *)indexes lead:(NSInteger)lead anchor:(NSInteger)anchor {
    BOOL changed = _selected != lead || ![_selectedIndexes isEqualToIndexSet:indexes];
    _selected = lead;
    self.selectionAnchor = anchor;
    self.selectedIndexes = indexes;
    if (changed) {
        self.needsDisplay = YES;
        NSAccessibilityPostNotification(self,NSAccessibilitySelectedChildrenChangedNotification);
    }
}

- (void)extendSelectionTo:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.rows.count) return;
    if (self.selectionAnchor < 0) {
        self.selected = index;
        return;
    }
    NSUInteger first = (NSUInteger)MIN(index,self.selectionAnchor);
    NSUInteger last = (NSUInteger)MAX(index,self.selectionAnchor);
    [self setSelection:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(first,last-first+1)]
                  lead:index anchor:self.selectionAnchor];
}

- (void)toggleSelectionAt:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.rows.count) return;
    NSUInteger position = (NSUInteger)index;
    NSMutableIndexSet *indexes = [self.selectedIndexes mutableCopy];
    if (![indexes containsIndex:position]) {
        [indexes addIndex:position];
        [self setSelection:indexes lead:index anchor:index];
        return;
    }

    [indexes removeIndex:position];
    NSInteger lead = self.selected;
    if (lead == index) {
        NSUInteger previous = [indexes indexLessThanIndex:position];
        NSUInteger remaining = previous == NSNotFound ? indexes.firstIndex : previous;
        lead = remaining == NSNotFound ? -1 : (NSInteger)remaining;
    }
    [self setSelection:indexes lead:lead anchor:lead < 0 ? index : lead];
}

- (NSNumber *)identifierAtIndex:(NSInteger)index {
    return index >= 0 && (NSUInteger)index < self.rows.count ? self.rows[(NSUInteger)index][@"id"] : nil;
}

- (void)replaceRowsPreservingSelection:(NSArray<NSDictionary *> *)rows {
    NSNumber *leadID = [self identifierAtIndex:self.selected];
    NSNumber *anchorID = [self identifierAtIndex:self.selectionAnchor];
    NSMutableSet<NSNumber *> *selectedIDs = [NSMutableSet set];
    [self.selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger index, __unused BOOL *stop) {
        NSNumber *identifier = [self identifierAtIndex:(NSInteger)index];
        if (identifier) [selectedIDs addObject:identifier];
    }];
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    NSInteger lead = -1, anchor = -1;
    for (NSUInteger index = 0; index < rows.count; index++) {
        NSNumber *identifier = rows[index][@"id"];
        if ([selectedIDs containsObject:identifier]) [indexes addIndex:index];
        if ([identifier isEqual:leadID]) lead = (NSInteger)index;
        if ([identifier isEqual:anchorID]) anchor = (NSInteger)index;
    }
    NSInteger oldLead = self.selected;
    self.rows = rows;
    if (oldLead < 0 && anchorID && rows.count) {
        // Refreshing the history should preserve an intentionally empty selection.
        if (anchor < 0) anchor = MIN(self.selectionAnchor,(NSInteger)rows.count-1);
        [self setSelection:indexes lead:-1 anchor:anchor];
        return;
    }
    if (!indexes.count) {
        self.selected = rows.count ? MAX(0,MIN(oldLead,(NSInteger)rows.count-1)) : -1;
        return;
    }
    if (lead < 0) lead = (NSInteger)indexes.firstIndex;
    [self setSelection:indexes lead:lead anchor:anchor < 0 ? lead : anchor];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSInteger first = self.horizontal ? MAX(0, (NSInteger)floor((NSMinX(dirtyRect) - 3) / CardStep) - 1)
                                      : [self compactRowIndexAtY:NSMinY(dirtyRect)];
    for (NSInteger index = first; (NSUInteger)index < self.rows.count; index++) {
        NSRect rect = [self rowFrame:index];
        if ((self.horizontal && NSMinX(rect) > NSMaxX(dirtyRect)) ||
            (!self.horizontal && NSMinY(rect) > NSMaxY(dirtyRect))) break;
        if (!NSIntersectsRect(rect, dirtyRect)) continue;
        [self drawEntry:self.rows[(NSUInteger)index] rect:rect selected:[self.selectedIndexes containsIndex:(NSUInteger)index]
                lead:index == self.selected];
        if (self.preparingDrag && [self.rows[(NSUInteger)index][@"id"] isEqual:self.pressedClipID]) {
            NSBezierPath *outline = Rounded(NSInsetRect(rect,1,1), self.horizontal ? 17 : 11);
            [[NSColor.controlAccentColor colorWithAlphaComponent:IncreaseContrast() ? 0.95 : 0.65] setStroke];
            outline.lineWidth = 2;
            [outline stroke];
        }
    }
}

- (void)drawEntry:(NSDictionary *)entry rect:(NSRect)rect selected:(BOOL)selected lead:(BOOL)lead {
    NSString *kind = entry[@"kind"] ?: @"teks";
    NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"(Teks kosong)";
    NSImage *thumbnail = self.images[entry[@"id"]];
    NSColor *tint = KindColor(kind);
    NSColor *swatch = Swatch(entry[@"color"]);
    NSColor *accent = NSColor.controlAccentColor;
    BOOL dark = DarkAppearance();
    BOOL sensitive = [entry[@"sensitive"] boolValue];
    BOOL pinned = [entry[@"pinned"] boolValue];
    BOOL imageKind = [kind isEqualToString:@"gambar"];
    NSString *host = [kind isEqualToString:@"url"] ? [NSURL URLWithString:title].host : nil;
    NSString *imageSize = imageKind ? [NSString stringWithFormat:@"%@ × %@",entry[@"width"],entry[@"height"]] : nil;

    NSBezierPath *outline = Rounded(NSInsetRect(rect,0.5,0.5), self.horizontal ? 17 : 11);
    if (self.horizontal || selected) {
        BOOL contrast = IncreaseContrast();
        NSColor *neutral = dark ? [NSColor colorWithWhite:0.12 alpha:contrast ? 0.8 : 0.42]
                                : [NSColor colorWithWhite:0.98 alpha:contrast ? 0.85 : 0.39];
        // Selection uses the same soft neutral glass as the tabs and toolbar; accent only for Increase Contrast.
        NSColor *fill = selected ? [NSColor.whiteColor colorWithAlphaComponent:dark ? 0.16 : 0.60] : neutral;
        [fill setFill];
        [outline fill];
        NSColor *selectedStroke = contrast ? [accent colorWithAlphaComponent:lead ? 0.92 : 0.55]
            : [(dark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:
                lead ? (dark ? 0.42 : 0.22) : (dark ? 0.22 : 0.10)];
        NSColor *stroke = selected ? selectedStroke
            : [(dark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:
                contrast ? 0.55 : dark ? 0.15 : 0.10];
        [stroke setStroke];
        outline.lineWidth = 1;
        [outline stroke];
    }

    if (self.horizontal) {
        [self drawCard:rect entry:entry kind:kind title:title host:host tint:tint swatch:swatch thumbnail:thumbnail
              imageSize:imageSize sensitive:sensitive pinned:pinned];
        return;
    }

    CGFloat left = NSMinX(rect)+10, center = NSMidY(rect), right = NSMaxX(rect)-11;
    NSSize tileSize = imageKind ? NSMakeSize(132,64) : NSMakeSize(28,28);
    NSRect tile = NSMakeRect(left,center-tileSize.height/2,tileSize.width,tileSize.height);
    if (imageKind) {
        [[NSColor.labelColor colorWithAlphaComponent:0.06] setFill];
        [Rounded(tile,7) fill];
        [NSGraphicsContext saveGraphicsState];
        [Rounded(tile,7) addClip];
        if (thumbnail) DrawImage(thumbnail,tile);
        else DrawImage(SymbolTinted(KindIcon(kind),tint),
                       NSMakeRect(NSMidX(tile)-9,center-9,18,18));
        [NSGraphicsContext restoreGraphicsState];
    } else {
        NSColor *tileColor = swatch ?: [tint colorWithAlphaComponent:dark ? 0.20 : 0.12];
        [tileColor setFill];
        [Rounded(tile,7) fill];
        if (!swatch) DrawImage(SymbolTinted(KindIcon(kind),tint), NSInsetRect(tile,7,7));
    }

    CGFloat textLeft = NSMaxX(tile)+11, textWidth = MAX(0,right-textLeft-56);
    DrawText(imageKind ? @"Gambar" : title,NSMakeRect(textLeft,center-16,textWidth,18),13,
             NSFontWeightSemibold,NSColor.labelColor);
    NSString *detail = imageSize ?: (host.length ? host : sensitive ? @"Spasi untuk membuka" : KindLabel(kind));
    DrawText(detail,NSMakeRect(textLeft,center+2,textWidth,16),11.5,
             NSFontWeightMedium,Secondary());
    CGFloat timeTop = pinned ? center-15 : center-7;
    NSRect timeRect = NSMakeRect(right-56,timeTop,56,16);
    if (pinned) {
        CGFloat pinTop = sensitive ? center-5.5 : NSMaxY(timeRect)+3;
        DrawImage(Symbol(@"pin"),NSMakeRect(right-11,pinTop,11,11));
    }
    if (!sensitive) {
        NSMutableParagraphStyle *align = [NSMutableParagraphStyle new];
        align.alignment = NSTextAlignmentRight;
        [ActivityTime(entry[@"last_used"]) drawInRect:timeRect
            withAttributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName:Secondary(), NSParagraphStyleAttributeName:align}];
    }
}

- (void)drawCard:(NSRect)rect entry:(NSDictionary *)entry kind:(NSString *)kind title:(NSString *)title
            host:(NSString *)host tint:(NSColor *)tint swatch:(NSColor *)swatch thumbnail:(NSImage *)thumbnail
       imageSize:(NSString *)imageSize sensitive:(BOOL)sensitive pinned:(BOOL)pinned {
    CGFloat left = NSMinX(rect)+CardInset, top = NSMinY(rect), right = NSMaxX(rect)-CardInset;
    NSRect tile = NSMakeRect(left,top+11,26,26);
    [[tint colorWithAlphaComponent:0.17] setFill];
    [Rounded(tile,8) fill];
    DrawImage(SymbolTinted(KindIcon(kind),tint),NSInsetRect(tile,6,6));
    DrawText(KindLabel(kind),NSMakeRect(left+35,top+15,right-left-57,18),12,
             NSFontWeightSemibold,NSColor.labelColor);
    if (pinned) DrawImage(Symbol(@"pin"),NSMakeRect(right-13,top+16,13,13));

    NSRect body = NSMakeRect(left,top+46,right-left,PreviewHeight);
    NSBezierPath *preview = Rounded(body,11);
    [[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
    [preview fill];
    [NSGraphicsContext saveGraphicsState];
    [preview addClip];

    if (imageSize) {
        if (thumbnail) DrawImage(thumbnail, body);
        else DrawImage(Symbol(@"photo"),NSInsetRect(body,(NSWidth(body)-28)/2,(NSHeight(body)-28)/2));
    } else if (sensitive) {
        DrawImage(Symbol(@"eye.slash"),NSMakeRect(left+11,NSMinY(body)+11,19,19));
        DrawText(@"Item sensitif",NSMakeRect(left+11,NSMinY(body)+42,NSWidth(body)-22,22),15,
                 NSFontWeightSemibold,NSColor.labelColor);
        DrawText(@"••••••••••••",NSMakeRect(left+11,NSMinY(body)+70,NSWidth(body)-22,26),20,
                 NSFontWeightMedium,NSColor.tertiaryLabelColor);
    } else if (swatch && [kind isEqualToString:@"warna"]) {
        NSGradient *shade = [[NSGradient alloc] initWithStartingColor:[swatch highlightWithLevel:0.16]
            endingColor:[swatch shadowWithLevel:0.13]];
        [shade drawInBezierPath:preview angle:35];
        NSFont *font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
        CGFloat tagWidth = MIN(NSWidth(body)-18,
            ceil([title sizeWithAttributes:@{NSFontAttributeName:font}].width)+16);
        NSRect tag = NSMakeRect(left+9,NSMaxY(body)-33,tagWidth,24);
        [[NSColor.blackColor colorWithAlphaComponent:0.62] setFill];
        [Rounded(tag,7) fill];
        [title drawInRect:NSInsetRect(tag,8,4) withAttributes:TextAttributes(font,NSColor.whiteColor)];
    } else if (host.length) {
        DrawText(host,NSMakeRect(left+11,NSMinY(body)+11,NSWidth(body)-22,25),16,
                 NSFontWeightSemibold,NSColor.labelColor);
        NSRange domain = [title rangeOfString:host options:NSCaseInsensitiveSearch];
        NSString *path = domain.location == NSNotFound ? title : [title substringFromIndex:NSMaxRange(domain)];
        if (path.length) {
            DrawMultiline(path,NSMakeRect(left+11,NSMinY(body)+42,NSWidth(body)-22,65),
                          [NSFont systemFontOfSize:12], Secondary());
        }
    } else {
        BOOL mono = [kind isEqualToString:@"json"] || [kind isEqualToString:@"kode"];
        NSFont *font = mono ? [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium]
            : [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
        DrawMultiline(title,NSInsetRect(body,11,11),font,NSColor.labelColor);
    }
    [NSGraphicsContext restoreGraphicsState];

    NSString *caption = sensitive ? @"Spasi untuk membuka" : imageSize;
    if (caption.length) {
        DrawText(caption,NSMakeRect(left,top+184,right-left-47,15),11.5,
                 NSFontWeightMedium,Secondary());
    }
    if (!sensitive) {
        NSMutableParagraphStyle *align = [NSMutableParagraphStyle new];
        align.alignment = NSTextAlignmentRight;
        [ActivityTime(entry[@"last_used"]) drawInRect:NSMakeRect(right-56,top+184,56,15)
            withAttributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName:Secondary(), NSParagraphStyleAttributeName:align}];
    }
}

- (NSInteger)indexAt:(NSPoint)point {
    if (!self.rows.count) return -1;
    NSInteger index = self.horizontal ? (NSInteger)floor((point.x-3)/CardStep)
                                      : [self compactRowIndexAtY:point.y];
    return NSPointInRect(point,[self rowFrame:index]) ? index : -1;
}

- (BOOL)containsPickerClick:(NSEvent *)event {
    NSView *content = self.window.contentView;
    NSView *hit = [content hitTest:[content convertPoint:event.locationInWindow fromView:nil]];
    return hit == self || [hit isDescendantOf:self];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.actionsSuspended) return;
    self.pressedClipID = nil;
    self.dragEvent = nil;
    self.clickDeferred = NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = [self indexAt:point];
    if (index < 0 || !self.picked) {
        self.lastClickID = nil;
        return;
    }

    NSNumber *identifier = self.rows[(NSUInteger)index][@"id"];
    BOOL extend = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    BOOL toggle = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // A nonactivating panel can receive both mouse-downs without a combined click count.
    BOOL sameClip = [identifier isEqual:self.lastClickID];
    BOOL repeated = sameClip &&
        now-self.lastClickAt <= NSEvent.doubleClickInterval &&
        fabs(point.x-self.lastClickPoint.x) <= 5 && fabs(point.y-self.lastClickPoint.y) <= 5;
    OCResultAction action = OCResultSelect;
    if (extend) action = OCResultExtendSelection;
    else if (toggle) action = OCResultToggleSelection;
    else if (repeated || (sameClip && event.clickCount == 2)) action = OCResultConfirm;
    self.lastClickID = action == OCResultSelect ? identifier : nil;
    self.lastClickAt = now;
    self.lastClickPoint = point;

    [self.window makeFirstResponder:self];
    if (!extend && !toggle) {
        self.pressedClipID = identifier;
        self.pressPoint = point;
        if (action == OCResultConfirm || [self.selectedIndexes containsIndex:(NSUInteger)index]) {
            self.deferredClick = action;
            self.clickDeferred = YES;
            return;
        }
    }
    self.picked(index,action);
}

- (BOOL)hasPointerGesture {
    return self.pressedClipID != nil;
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.actionsSuspended || !self.pressedClipID || !self.prepareDrag) return;
    if (self.dragEvent) {
        self.dragEvent = event;
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (hypot(point.x-self.pressPoint.x,point.y-self.pressPoint.y) < 5) return;
    self.clickDeferred = NO;
    self.lastClickID = nil;
    self.dragEvent = event;
    NSMutableArray<NSDictionary *> *selection = [NSMutableArray array];
    [self.selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger index, __unused BOOL *stop) {
        if (index < self.rows.count) [selection addObject:self.rows[index]];
    }];
    for (NSDictionary *row in selection) {
        if ([row[@"id"] isEqual:self.pressedClipID]) {
            self.prepareDrag(selection);
            return;
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSNumber *identifier = self.pressedClipID;
    self.pressedClipID = nil;
    self.dragEvent = nil;
    if (!self.clickDeferred) return;
    self.clickDeferred = NO;
    if (!event || self.actionsSuspended) return;
    NSInteger index = [self indexAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index >= 0 && [identifier isEqual:self.rows[(NSUInteger)index][@"id"]])
        self.picked(index,self.deferredClick);
}

- (void)beginPreparedDrag:(NSArray<NSPasteboardItem *> *)items {
    NSEvent *event = self.dragEvent;
    if (!event || !self.window || !items.count || !(NSEvent.pressedMouseButtons & 1)) return;
    self.dragEvent = nil;
    self.pressedClipID = nil;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSImage *icon = Symbol(@"doc.on.doc");
    NSMutableArray<NSDraggingItem *> *dragItems = [NSMutableArray arrayWithCapacity:items.count];
    NSURL *directory = nil;
    for (NSPasteboardItem *item in items) {
        AddDragFile(item,dragItems.count+1,&directory);
        NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
        [dragItem setDraggingFrame:NSMakeRect(point.x-12,point.y-12,24,24)
            contents:dragItems.count ? nil : icon];
        [dragItems addObject:dragItem];
    }
    self.dragImageDirectory = directory;
    NSDraggingSession *session = [self beginDraggingSessionWithItems:dragItems event:event source:self];
    session.draggingFormation = NSDraggingFormationNone;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextOutsideApplication ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    // An accepting app can read the image asynchronously after the drop.
    if (operation == NSDragOperationNone && self.dragImageDirectory)
        [NSFileManager.defaultManager removeItemAtURL:self.dragImageDirectory error:nil];
    self.dragImageDirectory = nil;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (self.actionsSuspended) return nil;
    NSInteger index = [self indexAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index < 0 || !self.contextMenu) return nil;
    [self.window makeFirstResponder:self];
    if (self.picked) self.picked(index, OCResultSelect);
    return self.contextMenu(index);
}

- (NSArray *)accessibilityChildren {
    if (!self.rows.count || self.actionsSuspended) {
        self.accessibleRows = nil;
        return self.rows.count ? @[] : [super accessibilityChildren];
    }
    NSMutableArray *children = [NSMutableArray array];
    NSRect visible = self.visibleRect;
    for (NSUInteger index = 0; index < self.rows.count; index++) {
        NSRect rect = [self rowFrame:(NSInteger)index];
        if (!NSIntersectsRect(rect, visible)) continue;
        NSDictionary *entry = self.rows[index];
        BOOL sensitive = [entry[@"sensitive"] boolValue];
        NSString *title = sensitive ? @"Item sensitif" : entry[@"title"];
        NSString *label = title.length ? title : @"Teks kosong";
        if (!sensitive) {
            // Kind, pin state, and time are shown visually, so VoiceOver gets them too.
            label = [NSString stringWithFormat:@"%@, %@%@, %@", label, KindLabel(entry[@"kind"]),
                [entry[@"pinned"] boolValue] ? @", disematkan" : @"", ActivityTime(entry[@"last_used"])];
        }
        NSRect screen = [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
        OCRowAccessibility *item = [OCRowAccessibility accessibilityElementWithRole:NSAccessibilityButtonRole
                frame:screen label:label parent:self];
        [item setAccessibilityElement:YES];
        [item setAccessibilityEnabled:YES];
        item.results = self;
        item.index = (NSInteger)index;
        [children addObject:item];
    }
    self.accessibleRows = children;
    return self.accessibleRows;
}
@end
