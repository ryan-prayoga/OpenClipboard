# Tab koleksi (strip horizontal + rail vertikal)

Tanggal: 2026-11-21. Status: menunggu persetujuan.

## Maksud

Sekarang koleksi dua langkah: Riwayat → daftar koleksi (kartu) → isi koleksi. Di popup, isi koleksi
terbuka di panel samping. Pengguna mau seperti Paste: koleksi adalah tab, pindah tab langsung
menampilkan klipnya, tanpa daftar perantara.

Alasan: lebih sedikit langkah, dan keyboard bisa dipakai konsisten di kedua layout.

## Tujuan

- Panel bawah: strip tab horizontal di bilah atas (`Clipboard`, tiap koleksi, `+`).
- Popup kursor: rail tab vertikal di kiri area klip.
- Pindah tab langsung memuat klip tab itu.
- Sumbu tombol = sumbu tab: `⌘←/→` di panel bawah, `⌘↑/↓` di popup.

## Bukan tujuan

- Mengubah skema SQLite, protokol Rust, atau worker. `catalog` sudah menerima id koleksi dan
  mengembalikan daftar koleksi.
- Drag klip ke tab, reorder tab, atau warna tab. Belum diminta.
- Mengubah aturan privasi, pratinjau, atau hapus/urungkan klip.

## Anti-tujuan

- Dua cara untuk hal yang sama: tidak boleh tersisa panel samping, mode kartu koleksi, atau
  `inlineCollection` di samping tab.
- `↑/↓` polos di popup tetap memindah klip, bukan tab.

## Pendekatan

1. **Ganti state machine dengan `activeTab` (dipilih).** `browsing`, `collection`,
   `inlineCollection` hilang; satu view `OCTabs` dipakai horizontal dan vertikal.
2. Tempel tab di atas state lama: diff kecil, tapi panel samping dan mode kartu tetap hidup dan
   bertabrakan dengan konsep tab. Ditolak.

## Desain

### State

- `int64_t activeTab` (0 = Clipboard/Riwayat, selain itu id koleksi). Menggantikan `browsing`,
  `collection`, `inlineCollection`, `collectionRow`, `collectionName`.
- `fetchCatalog` selalu kirim `collection: activeTab`. Cabang "daftar koleksi" dihapus.
- Event `catalog` memperbarui `self.collections` dan strip tab. Kalau `activeTab` tidak ada lagi di
  daftar (koleksi dihapus), pindah ke Clipboard.
- Pindah tab: tutup pratinjau, kosongkan pencarian, reset pilihan, `fetchCatalog`, fokus ke hasil.
- Placeholder pencarian: `Cari klip` di Clipboard, `Cari di <nama>` di koleksi.
- Judul kosong: `Koleksi masih kosong` di koleksi, `Belum ada klip` di Clipboard (sudah ada).

### Tampilan

- **Panel bawah.** Strip menggantikan tombol navigasi dan `+` di bilah atas, di antara pencarian
  dan `⋯`. Tiap tab: titik warna + nama, terpotong dengan elipsis; tab aktif diberi latar pil.
  Strip bisa digulir horizontal kalau tab banyak dan menggulir tab aktif ke terlihat. `+` tetap di
  ujung strip.
- **Popup.** Lebar 520 px kalau area layar cukup, selain itu 432 px. Rail 112 px (96 px di mode
  432) di kiri area klip, pemisah garis tipis. Rail menampilkan titik warna + nama, tab aktif pakai
  warna aksen sistem. `+` di dasar rail. Bilah atas jadi pencarian + `⋯` saja.
- Warna titik: warna turunan dari id koleksi, tetap per koleksi. Clipboard memakai ikon jam.
- VoiceOver: strip/rail berperan sebagai grup tab; tiap tab berlabel `Koleksi <nama>` dan status
  terpilih.

### Keyboard

| Tombol | Perilaku |
| --- | --- |
| `⌘←` / `⌘→` | Tab sebelumnya/berikutnya (panel bawah). Clamp, tidak wrap. |
| `⌘↑` / `⌘↓` | Tab sebelumnya/berikutnya (popup). |
| `⌘1`…`⌘9` | Lompat ke tab ke-n (1 = Clipboard). Menggantikan `⌘1`/`⌘2` lama. |
| Sumbu lain | Alias: `⌘↑/↓` bekerja di panel bawah, `⌘←/→` di popup. |
| `⌥←` / `⌥→` | Lompat hari, tetap di panel bawah. |
| `→` / `←` polos di popup | Hanya menggerakkan caret; tidak lagi membuka/menutup koleksi. |
| `Esc` | Tutup pratinjau, lalu tutup panel. Tidak ada level koleksi lagi. |
| `Tab` | search → hasil → strip/rail (satu perhentian) → `+` → `⋯`. |

Semua `⌘`-arrow dicegat sebelum pengetikan, dengan pengecualian saat IME sedang composing (seperti
kode sekarang).

### Aksi koleksi

- `+` membuat koleksi dan langsung berpindah ke tab barunya.
- Klik kanan pada tab (dan menu `⋯` untuk tab aktif): **Ubah nama…**, **Hapus koleksi…**. Hapus
  hanya menghapus keanggotaan, perilaku lama dipertahankan. Setelah hapus, pindah ke Clipboard.
- Menu **Tambahkan ke koleksi** pada klip tidak berubah.
- Menu `⋯`: item **Riwayat**/**Koleksi** dihapus, diganti daftar tab dengan `⌘1…⌘9`.

### Yang dihapus

- `openCollection:` (cabang panel samping), `backToCollections:`, `closeCollection`, properti
  `side*`, `backButton`, `sideUndoButton`, dan `activePanel/activeResults/activeSearch` yang
  bercabang ke `side` (jadi alias langsung ke `panel/results/search`).
- `renderCollections`, `navigateTo:`, `toggleNavigation:`, dan tombol `navigation`.
- Mode `OCResults.collections` beserta gambar kartu koleksi (`Results.m`) dan petunjuk
  `↵ Buka koleksi`.

### Pembaruan dokumen

`PLAN.md`: tulis ulang bagian Panel bawah layar, Aksi bersama dan koleksi, dan tabel tombol sesuai
desain ini.

## Batasan

- Objective-C/AppKit murni; konstruksi view manual seperti `OCToolbarSurface`. Tinggi kontrol
  `OCToolbarHeight` = 36.
- Rail harus tetap terbaca di popup 432 px; hasil klip minimal sekitar 300 px lebar.
- Metrik `ReportMetric` untuk `open` dan `search` tetap dilaporkan.
- Tidak ada branch baru; kerja di `main`.

## Diserahkan ke pembangun

- Bentuk persis `OCTabs` (satu kelas dengan orientasi, atau dua subkelas).
- Rumus warna titik dari id koleksi, asal kontrasnya cukup di mode terang dan gelap.
- Animasi pindah tab (disarankan tanpa animasi, atau fade ≤120 ms dengan Reduce Motion dihormati).
- Pengujian: tidak ada target uji native; verifikasi lewat `./scripts/build-app.sh` dan menjalankan
  aplikasi, ditambah `cargo test --locked` bila Rust tersentuh (seharusnya tidak).

## Pilihan yang diambil Claude (bisa dikoreksi)

- Clamp, bukan wrap, di ujung tab.
- Pindah tab mengosongkan pencarian.
- `⌘1…⌘9`, alias sumbu lain, dan lebar rail 112/96 px.
- `+` langsung memindah ke tab baru.
- `←/→` polos di popup tidak lagi punya arti koleksi.
