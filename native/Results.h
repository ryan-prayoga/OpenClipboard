#import "Native.h"

typedef NS_ENUM(NSUInteger, OCResultAction) {
    OCResultSelect,
    OCResultConfirm,
    OCResultExtendSelection,
    OCResultToggleSelection,
};

@interface OCResults : NSView
@property(nonatomic) BOOL horizontal;
@property(nonatomic, copy) NSArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *images;
@property(nonatomic) NSInteger selected;
@property(nonatomic, copy, readonly) NSIndexSet *selectedIndexes;
- (void)showEmptyTitle:(NSString *)title detail:(NSString *)detail announce:(BOOL)announce;
@property(nonatomic, copy) void (^picked)(NSInteger index, OCResultAction action);
@property(nonatomic, copy) NSMenu *(^contextMenu)(NSInteger index);
- (NSRect)rowFrame:(NSInteger)index;
- (void)layoutRows;
- (void)extendSelectionTo:(NSInteger)index;
- (void)toggleSelectionAt:(NSInteger)index;
- (void)replaceRowsPreservingSelection:(NSArray<NSDictionary *> *)rows;
- (NSArray<NSDictionary *> *)visibleRows;
- (BOOL)containsPickerClick:(NSEvent *)event;
@end
