#import <AppKit/AppKit.h>

typedef NS_ENUM(NSUInteger, OCTabsOrientation) {
    OCTabsHorizontal,
    OCTabsVertical,
};

// Palette keys a collection can use for its dot; an empty key means the automatic colour.
NSArray<NSDictionary *> *OCTabPalette(void);               // @{@"key":NSString,@"title":NSString}
NSColor *OCTabColor(NSString *key, int64_t collectionID);  // unknown or empty key -> automatic hue

// Tab strip (panel bawah) or rail (popup) for Riwayat and the user's collections.
// Tab 0 is Riwayat; the last item is the "+" button.
@interface OCTabs : NSView
@property(nonatomic, readonly) OCTabsOrientation orientation;
@property(nonatomic, copy) NSArray<NSDictionary *> *collections; // @{@"id":NSNumber,@"name":NSString,@"color":NSString}
@property(nonatomic) int64_t selectedID;                          // 0 = Riwayat
@property(nonatomic, copy) void (^onSelect)(int64_t collectionID);
@property(nonatomic, copy) void (^onAdd)(void);
@property(nonatomic, copy) void (^onClickEmpty)(void);
@property(nonatomic, copy) NSMenu *(^onContext)(int64_t collectionID); // not called for 0
// Inline naming: `beginEditingCollectionID:` turns a tab (or a new slot at the end, for id 0) into a text field.
// Return commits, Esc or losing focus cancels. `onCommit` only fires for a non-empty, changed name
// (id 0 = new collection); `onEndEditing` always fires afterwards.
@property(nonatomic, copy) void (^onCommit)(int64_t collectionID, NSString *name);
@property(nonatomic, copy) void (^onEndEditing)(void);
@property(nonatomic, readonly) BOOL editing;
@property(nonatomic, readonly) NSInteger tabCount;                 // collections.count + 1
@property(nonatomic, readonly) NSInteger selectedIndex;
- (instancetype)initWithFrame:(NSRect)frame orientation:(OCTabsOrientation)orientation;
- (int64_t)collectionIDAtIndex:(NSInteger)index;                   // clamps; index 0 returns 0
- (void)scrollSelectedToVisible;
- (void)beginEditingCollectionID:(int64_t)collectionID;
- (void)cancelEditing;
@end
