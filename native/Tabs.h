#import <AppKit/AppKit.h>

typedef NS_ENUM(NSUInteger, OCTabsOrientation) {
    OCTabsHorizontal,
    OCTabsVertical,
};

// Tab strip (panel bawah) or rail (popup) for Riwayat and the user's collections.
// Tab 0 is Riwayat; the last item is the "+" button.
@interface OCTabs : NSView
@property(nonatomic, readonly) OCTabsOrientation orientation;
@property(nonatomic, copy) NSArray<NSDictionary *> *collections; // @{@"id":NSNumber,@"name":NSString}
@property(nonatomic) int64_t selectedID;                          // 0 = Riwayat
@property(nonatomic, copy) void (^onSelect)(int64_t collectionID);
@property(nonatomic, copy) void (^onAdd)(void);
@property(nonatomic, copy) NSMenu *(^onContext)(int64_t collectionID); // not called for 0
@property(nonatomic, readonly) NSInteger tabCount;                 // collections.count + 1
@property(nonatomic, readonly) NSInteger selectedIndex;
- (instancetype)initWithFrame:(NSRect)frame orientation:(OCTabsOrientation)orientation;
- (int64_t)collectionIDAtIndex:(NSInteger)index;                   // clamps; index 0 returns 0
- (void)scrollSelectedToVisible;
@end
