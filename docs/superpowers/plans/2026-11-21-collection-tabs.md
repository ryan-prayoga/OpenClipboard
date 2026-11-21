# Tab Koleksi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ganti alur Riwayat → daftar koleksi → isi koleksi dengan tab koleksi: strip horizontal di panel bawah, rail vertikal di popup kursor.

**Architecture:** Satu `activeTab` (0 = Riwayat, selain itu id koleksi) menggantikan `browsing`/`collection`/`inlineCollection`. View baru `OCTabs` (Objective-C, digambar manual seperti `OCResults`) dipakai dua orientasi. Logika murni (clamp langkah tab, peta digit, hue titik warna) ada di Rust supaya punya unit test; sisi Rust lain tidak berubah.

**Tech Stack:** Objective-C/AppKit (ARC, macOS 27), Rust 2024 (`cargo test --locked`), `cc` crate untuk native.

**Spec:** `docs/superpowers/specs/2026-11-21-collection-tabs-design.md`

## Global Constraints

- Tidak ada branch baru; kerja di `main`.
- Commit hanya kalau user sudah memintanya. Kalau diminta, akhiri pesan dengan `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Semua teks UI berbahasa Indonesia. Tab pertama berlabel `Riwayat` (cocok dengan teks yang sudah ada; di spec disebut "Clipboard").
- Popup: lebar 520 px kalau `NSWidth(room) >= 520`, selain itu `MIN(432, NSWidth(room))`. Rail 112 px bila lebar panel >= 500, selain itu 96 px.
- Tinggi kontrol bilah atas = `OCToolbarHeight` (36).
- Tab di-clamp di ujung, tidak wrap. Pindah tab mengosongkan pencarian dan pilihan, dan menutup pratinjau.
- `⌘←/→/↑/↓` tidak dicegat saat IME sedang composing; auto-repeat diabaikan.
- Tidak ada perubahan skema SQLite, `Request`/event di `src/worker.rs`, atau `src/history.rs`.
- `ReportMetric("open"/"search")` tetap dilaporkan.

## Review Focus

1. Koleksi aktif terhapus (dari menu atau event `changed`): pindah ke Riwayat, bukan layar kosong.
2. Nama koleksi sangat panjang, emoji, atau non-Latin: terpotong dengan elipsis, tata letak tidak pecah.
3. Banyak koleksi (50+): strip/rail bisa digulir dan tab aktif selalu terlihat.
4. Nol koleksi: hanya `Riwayat` dan `+`; `⌘→` tidak melakukan apa-apa dan tidak crash.
5. Layar sempit (<520 px usable untuk popup, <700 px untuk panel bawah): popup 432/rail 96, pencarian menyusut, strip menggulir.

---

### Task 1: Logika tab murni di Rust

**Files:**
- Create: `src/tabs.rs`
- Modify: `src/main.rs` (tambah `mod tabs;`), `native/Bridge.h` (deklarasi)
- Test: unit test di dalam `src/tabs.rs`

**Interfaces:**
- Produces (Rust, diekspor C): `oc_tab_step(current: i64, count: i64, delta: i64) -> i64`, `oc_tab_for_digit(digit: i64, count: i64) -> i64`, `oc_tab_hue(id: i64) -> f64`. Bridge.h: `int64_t oc_tab_step(int64_t,int64_t,int64_t); int64_t oc_tab_for_digit(int64_t,int64_t); double oc_tab_hue(int64_t);`
- Semantik: indeks tab 0 = Riwayat, 1…n = koleksi urut tampil; `count` = jumlah koleksi + 1.

- [ ] **Step 1: Tulis test yang gagal** di `src/tabs.rs` (`#[cfg(test)] mod tests`):
  - `step_clamps_at_both_ends`: `step(0,3,-1)==0`, `step(2,3,1)==2`, `step(1,3,1)==2`, `step(1,3,-1)==0`, `step(0,3,i64::MAX)==2` (tanpa overflow).
  - `step_with_empty_or_single_tab_is_zero`: `step(0,1,1)==0`, `step(5,0,1)==0`.
  - `digit_maps_to_index_or_minus_one`: `for_digit(1,3)==0`, `for_digit(3,3)==2`, `for_digit(4,3)==-1`, `for_digit(0,3)==-1`, `for_digit(10,20)==-1`.
  - `hue_is_stable_in_unit_range_and_spreads_neighbours`: `hue(7)==hue(7)`, `0.0<=hue(id)<1.0` untuk id -5..200, dan jarak melingkar `hue(i)` ke `hue(i+1)` >= 0.3 untuk i 1..100.
- [ ] **Step 2: Jalankan dan pastikan gagal.** Run: `cargo test --locked tabs` → gagal kompilasi (fungsi belum ada).
- [ ] **Step 3: Implementasi** `pub fn step`, `pub fn for_digit`, `pub fn hue` (hue = `(id as f64 * 0.618033988749895).rem_euclid(1.0)`) dan tiga pembungkus `#[unsafe(no_mangle)] extern "C"` dengan nama di atas. Gaya ekspor sama seperti `oc_send` di `src/worker.rs:121`. Tambah `mod tabs;` di `src/main.rs` dan deklarasi di `native/Bridge.h`.
- [ ] **Step 4: Jalankan test.** Run: `cargo test --locked` → semua lulus (termasuk 14 test lama). `cargo fmt --check` bersih.
- [ ] **Step 5: Checkpoint commit** `feat: add pure tab navigation helpers` (`src/tabs.rs src/main.rs native/Bridge.h`).

---

### Task 2: View `OCTabs`

**Files:**
- Create: `native/Tabs.h`, `native/Tabs.m`
- Modify: `build.rs` (tambah `"native/Tabs.m"` ke daftar file `cc`)

**Interfaces:**
- Consumes: `oc_tab_hue` (Task 1), `OCToolbarHeight` dari `native/Toolbar.h`.
- Produces (`native/Tabs.h`):
```objc
typedef NS_ENUM(NSUInteger, OCTabsOrientation) { OCTabsHorizontal, OCTabsVertical };
@interface OCTabs : NSView
@property(nonatomic) OCTabsOrientation orientation;
@property(nonatomic, copy) NSArray<NSDictionary *> *collections; // @{@"id":NSNumber,@"name":NSString}, tanpa Riwayat
@property(nonatomic) int64_t selectedID;                          // 0 = Riwayat
@property(nonatomic, copy) void (^onSelect)(int64_t collectionID);
@property(nonatomic, copy) void (^onAdd)(void);
@property(nonatomic, copy) NSMenu *(^onContext)(int64_t collectionID); // tidak dipanggil untuk 0
@property(nonatomic, readonly) NSInteger tabCount;                 // collections.count + 1
@property(nonatomic, readonly) NSInteger selectedIndex;
- (instancetype)initWithFrame:(NSRect)frame orientation:(OCTabsOrientation)orientation;
- (int64_t)collectionIDAtIndex:(NSInteger)index;                   // 0 → 0
- (void)scrollSelectedToVisible;
@end
```

- [ ] **Step 1: Tulis `OCTabs`.** Menggambar manual (pola `OCResults`): item `Riwayat` (ikon SF `clock`), lalu tiap koleksi (titik warna dari `NSColor colorWithHue:oc_tab_hue(id) saturation:0.65 brightness:0.9 alpha:1` + nama terpotong elipsis), lalu item `+`. Horizontal: tinggi `OCToolbarHeight`, item pil, tab aktif berlatar pil `NSColor.labelColor` alpha ~0.12; digulir horizontal (offset sendiri, `scrollWheel:` + `scrollSelectedToVisible`). Vertikal: item tinggi 30, tab aktif berwarna `NSColor.controlAccentColor`, garis pemisah tipis di tepi kanan, digulir vertikal, `+` item terakhir. Klik kiri → `onSelect`/`onAdd`; klik kanan pada koleksi → `onContext` lalu `popUpMenuPositioningItem`.
- [ ] **Step 2: Fokus & aksesibilitas.** `acceptsFirstResponder = YES`, `needsPanelToBecomeKey = YES`. Role `NSAccessibilityTabGroupRole`; tiap tab adalah `NSAccessibilityElement` role radio button, label `Riwayat`/`Koleksi <nama>`, nilai terpilih, aksi press memanggil `onSelect`. `+` berlabel `Tambah koleksi`. Hormati `accessibilityDisplayShouldIncreaseContrast` dan Reduce Transparency seperti `OCToolbarCapsule`.
- [ ] **Step 3: Daftarkan di `build.rs` dan bangun.** Run: `cargo build --locked 2>&1 | tail -30` → selesai tanpa error maupun warning dari `Tabs.m`.
- [ ] **Step 4: Checkpoint commit** `feat: add OCTabs view for horizontal strip and vertical rail`.

---

### Task 3: Picker memakai `activeTab`

**Files:**
- Modify: `native/Picker.m` (properti 184–218, `showAtBottom:` 249, `buildMain:` 304, `dismissRestoringFocus:` ~470, `fetchCatalog` 515, `controlTextDidChange:` 530, `receiveEvent:` 543, `pick:` 724, bagian 642–833, `presentStatus:` 884, `useSelected:` 960, `actions:` 1340, `deleteCollection:` 1416, `contextFor:` 1440, `deleteSelected` 1497, `refreshSelectionHint:` 632, `handleKey:` 1190)

**Interfaces:**
- Consumes: `OCTabs` (Task 2).
- Produces (di `OCPicker`):
```objc
@property(nonatomic, strong) OCTabs *tabs;
@property(nonatomic) int64_t activeTab;                 // 0 = Riwayat
- (void)selectTab:(int64_t)collectionID;                // 0 untuk Riwayat
- (void)selectTabAtIndex:(NSInteger)index;              // clamp ke 0…tabs.tabCount-1
- (void)stepTab:(NSInteger)delta;                       // pakai oc_tab_step
```

- [ ] **Step 1: Hapus state lama.** Buang properti `side`, `sideSearch`, `sideStatus`, `sideResults`, `sideScroll`, `sideScrollObserver`, `sideUndoButton`, `backButton`, `navigation`, `addCollection`, `collectionName`, `browsing`, `inlineCollection`, `collection`, `collectionRow`; tambah `tabs` dan `activeTab`. Hapus `openCollection:`, `backToCollections:`, `closeCollection`, `renderCollections`, `navigateTo:`, `toggleNavigation:`, `makeNavigationInView:frame:`, `refreshNavigation`, `removeSideScrollObserver`. `activeResults/activeSearch/activePanel` tetap ada sebagai metode, kini langsung mengembalikan `results/search/panel`. Bersihkan semua rujukan `side*` (`installMonitors`, `dismissRestoringFocus:`, `refreshUndoControls`, `presentStatus:`, `handleKey:`). Di `handleKey:` buang sementara cabang ⌘1/⌘2, ⌘←/→ lama, `→`/`←` polos untuk koleksi, level koleksi di `Esc`, dan urutan Tab lama (diganti Step 6); keyboard tab baru ditambah di Task 4.
- [ ] **Step 2: Tata letak `buildMain:`.** Panel bawah: bilah atas = pencarian (lebar `MIN(260, 0.4 × bilah)`), `OCTabs` horizontal mengisi sisa ruang sampai 8 px sebelum `⋯`. Popup: bilah atas = pencarian melebar + `⋯`; di bawahnya `OCTabs` vertikal selebar rail (aturan lebar di Global Constraints) dari `resultsBottom` sampai `resultsTop`, dan `scroll` hasil digeser ke kanan selebar rail + 6 px. Hapus tombol `+` terpisah. Di `showAtBottom:` set `activeTab = 0` dan terapkan lebar popup 520/432.
- [ ] **Step 3: Alur data.** `fetchCatalog`: satu jalur, selalu kirim `@"collection":@(self.activeTab)` dan `query` dari `search`. Event `catalog`: set `self.collections`, `tabs.collections`, `tabs.selectedID`; bila `activeTab != 0` dan id-nya tidak ada di daftar → `[self selectTab:0]` dan `return`. Judul kosong: `Koleksi masih kosong` bila `activeTab`, selain itu `Belum ada klip`. `controlTextDidChange:` kehilangan cabang daftar koleksi. Event `created`: `[self selectTab:[event[@"id"] longLongValue]]` lalu `setMessage:@"Koleksi dibuat."`.
- [ ] **Step 4: Implement `selectTab:`, `selectTabAtIndex:`, `stepTab:`.** `selectTab:` bila id sama → return; `clearPreview`; set `activeTab`; kosongkan `search.stringValue` dan `results.selected = -1`, `results.rows = @[]`; placeholder `Cari klip` (Riwayat) atau `Cari di <nama>`; `tabs.selectedID` + `scrollSelectedToVisible`; `makeFirstResponder:results`; `fetchCatalog`. `selectTabAtIndex:` memakai `tabs collectionIDAtIndex:`. `stepTab:` memakai `oc_tab_step(tabs.selectedIndex, tabs.tabCount, delta)`.
- [ ] **Step 5: Menu & aksi koleksi.** Hubungkan `tabs.onSelect = selectTab:`, `tabs.onAdd = createCollection:`, `tabs.onContext` → `[self contextFor:@{@"id":…,@"title":nama,@"kind":@"koleksi"}]`. Menu `⋯` (`actions:`): ganti item Riwayat/Koleksi dengan satu item per tab (`navigateMenu:` → `selectTabAtIndex:`, kunci `⌘1…⌘9` untuk 9 pertama), lalu `Tambah koleksi…`; bila `activeTab != 0` tambahkan `addCollectionActionsFor:` untuk tab aktif; cabang `results.collections` dibuang. `deleteCollection:` memanggil `[self selectTab:0]` bila yang dihapus = `activeTab`. `contextFor:` memakai `self.activeTab` pada item `Keluarkan dari koleksi`. `pick:`, `useSelected:`, `deleteSelected`, `refreshSelectionHint:` kehilangan cabang `collections`.
- [ ] **Step 6: Urutan Tab fokus.** `Tab`/`⇧Tab` berputar: pencarian → hasil (bila ada baris) → `tabs` → `⋯` → Urungkan (bila terlihat).
- [ ] **Step 7: Bangun.** Run: `cargo build --locked 2>&1 | tail -30` → sukses tanpa warning baru. Run: `grep -nE 'browsing|inlineCollection|collectionRow|sideResults|backButton|\.collections *=' native/Picker.m` → tidak ada sisa selain `self.collections` (daftar koleksi) dan `results.collections` yang dihapus di Task 5.
- [ ] **Step 8: Checkpoint commit** `feat: replace collection drill-down with active tab state`.

---

### Task 4: Keyboard tab

**Files:**
- Modify: `native/Picker.m` (`handleKey:` 1190–1331)

**Interfaces:**
- Consumes: `selectTabAtIndex:`, `stepTab:`, `tabs` (Task 3), `oc_tab_for_digit` (Task 1).

- [ ] **Step 1: ⌘-panah.** Saat `flags == NSEventModifierFlagCommand`, bukan `composing`, bukan `isARepeat`, dan window = `panel`: `kVK_LeftArrow`/`kVK_UpArrow` → `stepTab:-1`, `kVK_RightArrow`/`kVK_DownArrow` → `stepTab:+1`; `return nil`. Keempat panah aktif di kedua layout (sumbu utama + alias). Auto-repeat dan saat composing: `return event`/`nil` sesuai pola lama.
- [ ] **Step 2: ⌘1…⌘9.** Peta `kVK_ANSI_1…9` (tidak berurutan) ke digit 1…9; `idx = oc_tab_for_digit(digit, tabs.tabCount)`; bila `idx >= 0` → `selectTabAtIndex:idx`; selalu `return nil` supaya tidak bocor ke menu.
- [ ] **Step 3: Fokus di `tabs`.** Saat `focused == self.tabs` dan `!flags`: panah searah sumbu orientasi (←/→ horizontal, ↑/↓ vertikal) memanggil `stepTab:`; `Return` tidak melakukan apa-apa (hindari jatuh ke `pick:`).
- [ ] **Step 4: Pastikan yang tetap.** `⌥←/→` lompat hari, `⌘Z`, Spasi, Delete, `⇧↑/↓` tidak berubah. Tanpa `⌘`, `←/→` polos di popup hanya menggerakkan caret (tidak ada cabang koleksi). `Esc`: tutup pratinjau lalu tutup panel.
- [ ] **Step 5: Bangun.** Run: `cargo build --locked 2>&1 | tail -30` → sukses.
- [ ] **Step 6: Checkpoint commit** `feat: switch collection tabs with command-arrows and command-digits`.

---

### Task 5: Bersihkan mode kartu koleksi di `OCResults`

**Files:**
- Modify: `native/Results.h`, `native/Results.m` (rujukan `collections` di ~251, 262, 383–421, 507–518, 549; default `@"koleksi"` di ~332)

- [ ] **Step 1: Hapus** properti `collections` dari `Results.h` dan semua cabangnya di `Results.m`, termasuk gambar kartu koleksi (`Buka koleksi`, `chevron.right`) dan default `kind ?: @"koleksi"` (ganti ke jenis klip yang valid atau hapus bila tak terpakai). Hapus entri `koleksi`/`folder` di tabel ikon/label hanya bila tidak dipakai di tempat lain (cek `grep -n koleksi native/*.m`).
- [ ] **Step 2: Bangun & bersihkan.** Run: `cargo build --locked 2>&1 | tail -30` → sukses. Run: `grep -n 'collections' native/Results.* native/Picker.m` → hanya `self.collections` (daftar) di `Picker.m`.
- [ ] **Step 3: Checkpoint commit** `refactor: remove collection card mode from OCResults`.

---

### Task 6: Dokumen dan verifikasi di aplikasi

**Files:**
- Modify: `PLAN.md` (bagian "Panel bawah layar", "Aksi bersama dan koleksi buatan pengguna", tabel tombol)

- [ ] **Step 1: Perbarui `PLAN.md`** sesuai spec: strip/rail tab, tombol `+`, klik kanan Ubah nama/Hapus, tabel tombol baru (`⌘←/→`, `⌘↑/↓`, `⌘1…⌘9`, `←/→` polos di popup hanya caret, `Esc`), hapus deskripsi daftar Koleksi/submenu/panel samping.
- [ ] **Step 2: Lulus otomatis.** Run: `cargo fmt --check && cargo test --locked` → bersih dan lulus. Run: `./scripts/build-app.sh` → menghasilkan `dist/OpenClipboard.app` tanpa error codesign.
- [ ] **Step 3: Jalankan dan periksa manual** (`open dist/OpenClipboard.app`, buka panel bawah dan popup). Semua harus benar:
  - Panel bawah: strip menampilkan Riwayat + koleksi + `+`; `⌘→` pindah tab dan klip langsung muncul; `⌘←` kembali; ⌘↑/↓ juga bekerja.
  - Popup: lebar 520 (432 bila sempit), rail di kiri; `⌘↓/⌘↑` pindah tab; `←/→` polos menggerakkan caret di pencarian.
  - `⌘1` ke Riwayat, `⌘3` ke koleksi kedua; `⌘9` tanpa tab ke-9 tidak melakukan apa-apa.
  - `+` membuat koleksi dan langsung berpindah ke tab itu; klik kanan tab → Ubah nama… dan Hapus koleksi…; hapus tab aktif → kembali ke Riwayat.
  - Nol koleksi: hanya Riwayat dan `+`, `⌘→` aman. 50+ koleksi: strip/rail bisa digulir, tab aktif terlihat. Nama panjang/emoji terpotong rapi.
  - Pencarian di koleksi hanya mencari isi koleksi itu; pindah tab mengosongkan pencarian; `Esc` menutup panel (tidak ada level koleksi).
  - VoiceOver membacakan `Koleksi <nama>` dan status terpilih; mode Increase Contrast dan Reduce Transparency terbaca.
- [ ] **Step 4: Checkpoint commit** `docs: describe collection tabs in PLAN`.
