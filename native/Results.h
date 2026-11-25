#import "Native.h"

typedef NS_ENUM(NSUInteger, OCResultAction) {
    OCResultSelect,
    OCResultConfirm,
    OCResultExtendSelection,
    OCResultToggleSelection,
};

@interface OCResults : NSView
+ (CGFloat)cardViewportHeight;
+ (CGFloat)compactViewportHeightWithin:(CGFloat)available;
@property(nonatomic) BOOL horizontal;
@property(nonatomic) BOOL actionsSuspended;
@property(nonatomic) BOOL preparingDrag;
@property(nonatomic, copy) NSArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *images;
@property(nonatomic) NSInteger selected;
@property(nonatomic, copy, readonly) NSIndexSet *selectedIndexes;
- (void)showEmptyTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol announce:(BOOL)announce;
@property(nonatomic, copy) void (^picked)(NSInteger index, OCResultAction action);
@property(nonatomic, copy) NSMenu *(^contextMenu)(NSInteger index);
@property(nonatomic, copy) void (^prepareDrag)(NSArray<NSDictionary *> *rows);
- (void)beginPreparedDrag:(NSArray<NSPasteboardItem *> *)items;
- (BOOL)hasPointerGesture;
- (NSRect)rowFrame:(NSInteger)index;
- (void)scrollRowToVisible:(NSInteger)index;
- (void)layoutRows;
- (void)invalidateClip:(NSNumber *)identifier;
- (void)extendSelectionTo:(NSInteger)index;
- (void)toggleSelectionAt:(NSInteger)index;
- (void)replaceRowsPreservingSelection:(NSArray<NSDictionary *> *)rows;
- (NSArray<NSDictionary *> *)visibleRows;
- (BOOL)containsPickerClick:(NSEvent *)event;
@end
