# OpenClipboard

OpenClipboard adalah pengelola clipboard macOS untuk pemakaian pribadi. Tekan satu shortcut global dari aplikasi yang sedang dipakai, lalu cari atau pilih klip di popup dekat kursor teks atau di panel bawah layar. Tekan Enter atau klik ganda klip untuk menempelkannya langsung ke aplikasi asal. OpenClipboard berjalan di background tanpa ikon menu bar atau Dock dan menyimpan riwayat secara lokal.

Target pengujian pertama adalah Mac Apple Silicon dengan macOS 27.2.1. Bundle `.app` memakai identitas yang tetap agar izin macOS bisa diuji dari build ke build. Pertimbangkan dukungan macOS 26 setelah alur utama lolos pengujian di Mac ini.

## Pengalaman pengguna

### Pengaturan clipboard

**⋯ → Pengaturan…** membuka jendela pengaturan dari kedua tampilan. Membuka `OpenClipboard.app` dari Finder atau Spotlight juga menampilkan jendela ini, termasuk saat aplikasi sudah berjalan atau shortcut gagal didaftarkan. Satu jendela dan satu proses perekam dipakai untuk setiap sesi pengguna.

| Bagian | Kontrol |
| --- | --- |
| **Umum** | **Shortcut global**, **Tampilan clipboard**, dan **Jalankan saat login**. |
| **Riwayat** | Status perekaman, batas klip riwayat biasa, penggunaan penyimpanan, **Bersihkan riwayat…**, dan **Hapus semua klip…**. |
| **Privasi** | Daftar aplikasi yang dikecualikan, **Deteksi pola sensitif**, serta status dan aksi untuk izin clipboard dan Accessibility. |

**Shortcut global** bawaan **`⌘⇧V` (Command–Shift–V)** membuka tampilan clipboard yang dipilih. Klik **Ubah…** dan tekan kombinasi baru, atau gunakan **Pulihkan bawaan** untuk memilih `⌘⇧V` lagi. Jika kombinasinya berubah, daftarkan kombinasi baru sebelum melepas kombinasi lama dan simpan perubahan setelah pendaftaran berhasil. Saat pendaftaran gagal, tampilkan pesan di Pengaturan, pertahankan kombinasi yang masih aktif, dan beri jalan untuk memilih kombinasi lain. Saat aplikasi dibuka tanpa shortcut aktif, pengaturan shortcut menjadi bagian yang langsung terlihat pada pembukaan manual.

**Tampilan clipboard** disimpan dan dipakai setiap kali shortcut global membuka OpenClipboard.

| Pilihan | Perilaku |
| --- | --- |
| **Dekat kursor teks** (bawaan) | Buka daftar ringkas dekat caret. Gunakan posisi pointer saat posisi caret tidak tersedia. |
| **Panel bawah layar** | Buka panel selebar layar di tepi bawah monitor tempat pointer berada. Tampilkan klip sebagai deretan kartu yang dapat digulir horizontal. |

**Jalankan saat login** awalnya nonaktif. Tampilkan status pendaftaran dari macOS dan tautan ke pengaturan login jika perlu persetujuan. Saat dimulai oleh login, aplikasi berjalan di latar belakang. Saat dibuka secara manual, tampilkan Pengaturan untuk pemulihan dan perubahan preferensi. Gunakan `SMAppService.mainApp` dan uji pembukaan ulang lewat siklus AppKit. [Login item Apple](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) · [Siklus AppKit](https://developer.apple.com/documentation/appkit/nsapplicationdelegate)

### Perekaman dan izin

- Perekaman clipboard otomatis selama aplikasi berjalan dan menyimpan riwayat di Mac ini. Klip yang sudah berada di clipboard menjadi titik awal pengamatan dan dilewati saat aplikasi dibuka. Panel dan Pengaturan menampilkan pemberitahuan jika akses clipboard dibatasi atau penyimpanan penuh.
- Tampilkan izin clipboard dan Accessibility secara terpisah. Untuk clipboard, tampilkan kebijakan yang dilaporkan sistem dan hasil pembacaan terakhir jika tersedia. Bila akses dibatasi, hentikan pembacaan, tampilkan cara membuka Pengaturan Sistem, dan sediakan **Coba lagi** setelah pengguna memperbarui izin.
- Buka halaman izin Accessibility di Pengaturan Sistem dan tampilkan panduan animasi saat pengguna memilih **Aktifkan Accessibility…** atau pertama kali mencoba menempel langsung tanpa izin. Saat izin terdeteksi, perbarui status di panduan dan di Pengaturan. Jika akses posisi belum tersedia, popup dibuka dekat pointer. Perekaman mengikuti izin clipboard.

### Popup di dekat kursor teks

- Shortcut global yang bisa diubah membuka panel Liquid Glass dan langsung memfokuskan hasil. Panel muncul di bawah caret, berpindah ke atas kalau ruangnya sempit, dan tetap di area layar yang bisa dipakai.
- Ambil posisi dari kolom teks yang sedang aktif sebelum popup mengambil fokus. Gunakan posisi karakter di sekitar caret untuk menyelaraskan baris dan sejajarkan awal teks pencarian dengan caret. Jika posisi teks tidak tersedia, gunakan pointer.
- Riwayat mengurutkan klip berdasarkan waktu salin atau tempel terakhir. Klip sematan tetap menampilkan ikon pin dan mengikuti urutan yang sama.
- Gunakan satu cuplikan ringkas per klip, tinggi daftar yang dibatasi, dan garis pemisah antarbagian. Item terpilih pakai warna aksen sistem.

### Panel bawah layar

- Rentangkan panel Liquid Glass selebar monitor tempat pointer berada, dengan jarak vertikal dari Dock. Material native mengambil warna dan memburamkan jendela di belakang, sementara tepi kaca memakai gaya Clear. Saat pengurangan transparansi aktif, gunakan latar padat.
- Bilah atas memuat pencarian, tombol **Koleksi** di sampingnya, dan menu **⋯**. Tombol **Koleksi** membuka daftar yang bisa dicari. Pilih nama koleksi untuk menampilkan isinya dalam panel yang sama.
- Isi kartu menyesuaikan jenis klip, misalnya pratinjau gambar, cuplikan teks, atau swatch warna. Tampilkan jenis dan waktu salin sebagai metadata ringkas. Kartu terpilih memakai indikator warna aksen sistem dan otomatis masuk ke area terlihat saat pengguna berpindah dengan keyboard.
- Roda mouse biasa dan gestur horizontal trackpad dapat menggulir deretan kartu. Saat panel terbuka, `←` dan `→` langsung berpindah kartu. Bila pencarian memiliki fokus dan berisi teks, tekan `Tab` untuk kembali memfokuskan deretan kartu.

### Aksi bersama dan koleksi buatan pengguna

Kedua tampilan memakai riwayat, koleksi, status sematan, dan aturan privasi yang sama. Menu **⋯** memberi akses ke **Pengaturan…**, **Keluar**, dan **Panduan Accessibility…** saat izin diperlukan.

Gunakan **+** di daftar Koleksi untuk menambahkan koleksi. Untuk koleksi yang dipilih, menu **⋯** dan klik kanan menyediakan **Ubah nama…** dan **Hapus koleksi…**. Penghapusan koleksi menghapus keanggotaannya saja, sehingga klip tetap ada di Riwayat dan koleksi lain. Dari Riwayat, gunakan **Tambahkan ke koleksi** untuk menaruh klip ke satu atau beberapa koleksi. Klip bisa dikeluarkan dari koleksi tanpa menghapus riwayatnya.

Di popup dekat kursor teks, tampilan **Koleksi** menampilkan daftar koleksi bernama. Buka maksimal satu submenu sekaligus, sejajar dengan baris koleksi aktif. Submenu muncul ke kanan dan berpindah ke kiri kalau ruang di kanan kurang. Kalau kedua sisi terlalu sempit, tampilkan isi koleksi di panel utama dengan jalur kembali. Grup koleksi tetap di posisi yang sama ketika submenu ditutup.

Pencarian berlaku pada tampilan aktif. Saat panel dibuka atau kueri maupun tampilan berubah, pilih hasil pertama jika tersedia. Jika ada pembaruan riwayat saat panel terbuka, pertahankan pilihan berdasarkan ID klip selama klip tersebut masih tampil. Tampilkan keadaan kosong saat riwayat atau koleksi kosong, dan keadaan tanpa hasil saat pencarian tidak cocok.

Saat panel dibuka, fokus dimulai di hasil dan klip pertama terpilih jika tersedia. Ketikan langsung memfokuskan pencarian dan menambahkan karakter pertama ke kueri. `Tab` berputar antara pencarian, hasil yang tersedia, tombol Koleksi atau Kembali, dan menu tindakan. Saat pengguna mengetik, tombol arah horizontal menggerakkan caret.

| Tombol | Perilaku |
| --- | --- |
| `Tab` / `⇧Tab` | Pindah antarbagian ke depan atau ke belakang. |
| `↑` / `↓` | Pindah pilihan di daftar atau deretan kartu. `↓` dari kolom pencarian langsung memilih hasil berikutnya dengan satu tekanan. |
| `⇧↑` / `⇧↓` atau Shift+klik | Pilih klip di antara titik awal dan posisi terakhir, termasuk kedua ujung rentang. |
| `⌘` + klik | Tambahkan atau lepas klip satu per satu, termasuk klip yang letaknya berjauhan. |
| `⌘1` / `⌘2` | Buka Riwayat atau daftar Koleksi. |
| `⌘→` / `⌘←` | Di panel bawah, maju dari Riwayat ke daftar Koleksi lalu ke koleksi terpilih, atau kembali satu tingkat. |
| `Delete` / `⌫` | Hapus klip terpilih saat hasil memiliki fokus. Di kolom pencarian, tombol ini menghapus teks. |
| **Urungkan** / `⌘Z` | Pulihkan penghapusan klip terakhir dalam 10 detik. Pintasan berlaku saat hasil memiliki fokus. |
| `→` | Di popup dekat kursor, buka daftar Koleksi dari akhir kueri atau hasil Riwayat, dan buka koleksi terpilih dari daftar Koleksi. Di panel bawah, pilih kartu berikutnya saat pencarian kosong atau fokus ada di kartu. |
| `←` | Di submenu popup, kembali ke koleksi yang tadi dipilih, termasuk saat submenu digambar ke kiri. Di panel bawah, pilih kartu sebelumnya saat pencarian kosong atau fokus ada di kartu. |
| `Enter` atau klik ganda klip | Tempel klip terpilih langsung ke aplikasi asal atau buka koleksi terpilih. Saat fokus pada kontrol, `Enter` menjalankan aksi kontrol tersebut. |
| `Spasi` | Buka atau tutup pratinjau klip. Pintasan berlaku saat hasil menerima fokus atau pencarian masih kosong. Spasi tetap bisa dipakai untuk mengetik kueri beberapa kata. |
| `Esc` | Tutup pratinjau, kembali dari isi koleksi ke daftar koleksi, atau tutup panel. |

Simpan aplikasi asal saat shortcut dipicu. Setelah klip disiapkan di clipboard, tutup panel dan kirim pintasan tempel ke proses asal setelah fokus kembali. Batalkan pengiriman jika fokus atau isi clipboard berubah. `Esc` memulihkan fokus, sedangkan klik di luar atau pindah aplikasi mengikuti fokus yang dipilih pengguna.

### Format clipboard

| Jenis | Tampilan dan perilaku |
| --- | --- |
| Teks | Cuplikan satu baris. Simpan teks utuh, termasuk baris baru dan spasi. |
| URL | Ikon tautan dengan domain dan potongan URL. Cari berdasarkan URL lengkap. |
| Gambar | Thumbnail kecil dan dimensi gambar. Simpan PNG atau TIFF asli yang didukung. Muat gambar penuh saat pratinjau atau penyalinan ulang. |
| JSON | Validasi dengan parser dan tampilkan cuplikan monospace. Pratinjau bisa dirapikan, sedangkan penyalinan ulang mengembalikan teks asli. |
| Kode | Cuplikan monospace. Gunakan label kode kalau deteksinya cukup yakin. Sisanya tetap tampil sebagai teks. |
| Warna | Swatch dan nilai asli seperti HEX, RGB, atau HSL. Pertahankan representasi warna native jika tersedia. |

Satu tindakan salin menjadi satu klip, termasuk jika pasteboard menyediakan beberapa representasi atau beberapa item. Simpan jenis data yang bisa dikembalikan ke pasteboard melalui daftar format yang didukung. Rich text, beberapa file dari Finder, dan OCR bisa diuji setelah versi awal dipakai. Format file Finder perlu mempertahankan pengelompokan dan mereferensikan file yang dipilih. [Format pasteboard Apple](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype)

### Batas dan penghapusan riwayat

- Mulai dari **500 klip biasa** dan izinkan batas **50–2.000** klip dari Pengaturan. Klip yang disematkan atau berada di koleksi dikecualikan dari hitungan klip biasa. Saat batas terlampaui, pangkas klip biasa paling lama berdasarkan waktu salin terakhir.
- Di **Pengaturan → Riwayat**, pilih **Tanpa batas**, **1 hari**, **7 hari**, **30 hari**, **90 hari**, atau **1 tahun** sebagai durasi simpan klip biasa. Saat durasi terlampaui berdasarkan waktu salin terakhir, hapus klip biasa secara otomatis. Klip sematan dan klip di koleksi dikecualikan.
- Tetapkan batas **1 MiB** per klip yang hanya berisi teks dan **25 MiB** per klip yang memuat gambar. Periksa ukuran payload sebelum dekode penuh. Sebelum penyimpanan, periksa batas total **256 MiB** untuk semua muatan klip dan thumbnail, termasuk klip yang disematkan atau dimasukkan ke koleksi. Ukuran file SQLite juga dipengaruhi metadata dan halaman database. Bila ruang hasil pemangkasan klip biasa masih kurang, lewati salinan baru dan tampilkan status **Penyimpanan penuh**. Klip sensitif memakai batas sesi terpisah sebesar **50 klip dan 25 MiB**. Lewati tangkapan sensitif baru jika tangkapan itu akan melampaui salah satu batas sesi.
- **Bersihkan riwayat…** tersedia di menu **⋯** Riwayat dan Pengaturan. Aksi ini menghapus klip yang tidak disematkan dan berada di luar semua koleksi, termasuk klip sesi dengan status tersebut. **Hapus semua klip…** menghapus seluruh klip dan thumbnail serta mengosongkan semua koleksi. Kedua aksi menampilkan konfirmasi dan berlaku pada data OpenClipboard. `Delete` pada klip terpilih menghapus klip dan keanggotaannya di setiap koleksi dengan kesempatan mengurungkan penghapusan selama 10 detik. **Keluarkan dari koleksi** hanya menghapus hubungan dengan koleksi aktif.

### Pengecualian aplikasi

- Pilih aplikasi yang dikecualikan dan simpan berdasarkan bundle ID. Perubahan daftar berlaku untuk tangkapan berikutnya. Periksa penanda di seluruh item pasteboard sebelum menyimpan payload. Lewati salinan yang ditandai rahasia, sementara, atau otomatis, seperti `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, dan `org.nspasteboard.AutoGeneratedType`. [Konvensi tipe pasteboard](https://nspasteboard.org/)
- Lacak aplikasi depan dan pergantiannya di antara dua pemeriksaan `changeCount`. Gunakan `org.nspasteboard.source` dari penulis sebagai petunjuk tambahan jika tersedia. Lewati salinan jika salah satu petunjuk mengarah ke aplikasi yang dikecualikan. Saat daftar pengecualian berisi aplikasi, lewati juga tangkapan yang ambigu, misalnya aplikasi depan berganti dalam interval pemeriksaan, identitasnya tidak tersedia, angka perubahan meloncat, atau metadata sumber bertentangan. Periksa lagi `changeCount` setelah membaca dan buang tangkapan jika pasteboard berubah di tengah baca. [Change count Apple](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) · [Aplikasi depan](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
- Jelaskan di Pengaturan bahwa pengecualian berbasis aplikasi memakai perkiraan sumber dan penulis di latar belakang kadang sulit dikenali. Uji pindah cepat dari dan ke aplikasi yang dikecualikan, penulisan dari latar belakang dengan penanda sumber, dan perubahan pasteboard berturut-turut.

### Item sensitif

- Pengguna bisa menandai klip secara manual. **Deteksi pola sensitif** aktif secara bawaan dan memeriksa pola lokal untuk beberapa token atau private key sebelum payload klip ditulis. Pengaturan ini mengendalikan deteksi pola saja. Uji kualitasnya dengan contoh palsu, termasuk teks biasa yang mirip token.
- Klip sensitif yang ditangkap hanya bertahan di memori selama sesi aplikasi. Tampilkan label **Item sensitif**, ikon mata dicoret, dan placeholder blur dengan panjang tetap. Saat tertutup, UI dan label aksesibilitas hanya menerima placeholder. Keluarkan isi sensitif dari pencarian, thumbnail, dan log.
- **Lepas tanda sensitif** mengembalikan klip yang ditandai manual ke riwayat lokal bersama sematan dan koleksinya.
- `Spasi` menampilkan klip terpilih. Tutup lagi saat pindah pilihan atau tab, tutup panel, atau aplikasi kehilangan fokus. Untuk klip sensitif yang masih tertutup, percobaan tempel menampilkan petunjuk `Spasi`. Setelah dibuka, tandai isi clipboard dengan `org.nspasteboard.ConcealedType` saat klip ditempel. Status sensitif mengikuti klip di setiap koleksi. Sematan dan keanggotaan klip sensitif berakhir bersama sesi.
- Jika klip yang sudah tersimpan ditandai sensitif, pastikan ada ruang sesi, hapus payload, thumbnail, dan indeks aplikasi dalam transaksi, lalu tampilkan klip sebagai item sesi. Jika langkah gagal, tampilkan status kegagalan dan tawarkan hapus klip. Aktifkan `PRAGMA secure_delete=ON` untuk mengurangi jejak pada halaman SQLite yang dikelola aplikasi. Dokumentasikan bahwa salinan lama mungkin masih ada di snapshot atau cadangan sistem. [SQLite secure_delete](https://sqlite.org/pragma.html#pragma_secure_delete)

## Arsitektur awal

- **UI native.** Rust menjalankan `NSApplication` lewat `objc2` dan `objc2-app-kit` di main thread. Delegate, tampilan, dan akses pasteboard memakai AppKit Objective-C melalui antarmuka C. Worker riwayat serta aturan penyimpanan dan klasifikasi ada di Rust. Panel Liquid Glass memakai `NSPanel` nonaktivasi agar papan ketik bisa masuk ke popup sementara aplikasi asal tetap di depan. Bundle memakai `LSUIElement`. [Binding AppKit](https://docs.rs/objc2-app-kit/latest/objc2_app_kit/) · [Liquid Glass AppKit](https://developer.apple.com/documentation/appkit/nsglasseffectview) · [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- **Shortcut dan posisi.** Daftarkan shortcut dengan `global-hotkey`. Pilihan tampilan menentukan posisi sebelum panel mengambil fokus. Untuk popup dekat caret, ambil elemen fokus dan `kAXSelectedTextRangeAttribute`, lalu coba baca `kAXBoundsForRangeParameterizedAttribute`. Batasi waktu panggilan Accessibility dan validasi koordinat terhadap layar aktif. Minta izin Accessibility untuk posisi berbasis caret. Panel bawah memakai lebar penuh monitor tempat pointer berada dan bisa dibuka saat izin Accessibility ditolak. [Global hotkey](https://docs.rs/global-hotkey/latest/global_hotkey/) · [Apple Accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h) · [Bounds for range](https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute)
- **Perekaman.** Cek `NSPasteboard.changeCount` tiap 125 ms dan baca data hanya saat berubah. Catat perubahan yang dibuat app saat mengembalikan klip untuk mencegah perekaman ulang. Polling bisa melewatkan klip yang langsung tertimpa sebelum pemeriksaan berikutnya. Kirim tangkapan yang lolos aturan perekaman, pengecualian, dan klasifikasi sensitif ke penyimpanan yang sesuai. [Change count Apple](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) · [Izin pasteboard](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default)
- **Penyimpanan.** Gunakan SQLite lewat `rusqlite`, dengan satu worker database dan rollback journal mode `DELETE` sebagai titik awal. Simpan metadata klip, data format asli, thumbnail, koleksi, dan relasi klip–koleksi. Terapkan penambahan dan pemangkasan klip dalam satu transaksi. Urutan item, jenis representasi, dan byte asli menentukan duplikat. Saat pengguna menyalin ulang payload identik dari aplikasi sumber, perbarui waktu pada entri yang sama dan pertahankan sematan serta koleksinya. Jika payload cocok dengan klip yang ditandai sensitif pada sesi aktif, tangkapan mengikuti kebijakan penyimpanan sesi. [Dokumentasi rusqlite](https://docs.rs/rusqlite/latest/rusqlite/) · [SQLite journal mode](https://sqlite.org/pragma.html#pragma_journal_mode)
- **Responsivitas.** Kerjakan operasi SQLite dan pembuatan thumbnail di luar main thread. Muat metadata serta thumbnail yang sedang terlihat. Mulai dari pencarian substring dengan data terbatas. Ukur sebelum menambah indeks pencarian khusus.

## Build dan instalasi prototipe

1. Gunakan toolchain Rust stabil yang dipatok di `rust-toolchain.toml`, dependensi yang dikunci di `Cargo.lock`, dan macOS SDK yang mendukung `NSGlassEffectView`. Target pertama `aarch64-apple-darwin`.
2. Sediakan `./scripts/build-app.sh` sebagai perintah build lokal. Skrip menjalankan build Cargo mode release dengan lockfile, membentuk `dist/OpenClipboard.app` dengan `Info.plist`, memberi tanda tangan, dan memverifikasi hasilnya dengan `codesign --verify --strict`. Gunakan bundle ID `dev.ryanprayoga.openclipboard`, nama executable `OpenClipboard`, dan `LSUIElement` aktif. Build bertanda tangan ad hoc dapat dipakai untuk uji UI lokal. Untuk uji izin lintas build, gunakan identitas tanda tangan pengembangan yang sama pada kedua build.
3. Pasang hasil build ke `~/Applications/OpenClipboard.app`, buka dari Finder atau Spotlight, lalu uji shortcut. Saat mengganti build, keluar dari aplikasi sebelum mengganti bundle di lokasi tersebut. Solusi untuk uji izin lintas build dianggap lolos setelah izin yang diberikan pada build pertama diperiksa kembali pada build kedua dengan identitas dan lokasi yang sama.
4. Simpan preferensi di `UserDefaults` dengan domain bundle dan riwayat di `~/Library/Application Support/OpenClipboard/history.sqlite3`. Gunakan direktori sementara tersendiri untuk fixture pengujian. Catat versi macOS, SDK, dan Rust yang dipakai pada build yang diuji.

## Tahapan pengerjaan

Jalankan `cargo fmt --check` dan `cargo test --locked` setelah proyek Cargo tersedia. Uji aturan perekaman, deduplikasi, pemangkasan, dan penghapusan dengan data palsu serta database sementara. Gunakan bundel `.app` terpasang untuk pengujian manual shortcut, fokus, dan izin macOS.

### 1. Bundel `.app` dan pembukaan Pengaturan

- [x] Siapkan proyek Cargo di folder ini. Lakukan build kecil yang menginisialisasi `NSApplication`, memuat `NSGlassEffectView`, dan memverifikasi dependensi yang bisa dibangun dengan target arm64. Patok toolchain dari hasil build yang berhasil. Mac target saat ini punya SDK 27.2 dan Rust/Cargo 1.90.0. [Binding Liquid Glass](https://docs.rs/crate/objc2-app-kit/latest/features#NSGlassEffectView)
- [x] Buat skrip build dan `Info.plist` sesuai bagian instalasi. Gunakan tanda tangan ad hoc untuk prototipe lokal. Pemeriksaan awal keychain menemukan nol identitas penandatanganan valid, sehingga bukti persistensi izin antar-build dijadwalkan di tahap 6. [Persyaratan penandatanganan Apple](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)
- [x] Tangani pembukaan pertama dan pembukaan ulang dari Finder atau Spotlight. Tampilkan satu jendela Pengaturan dan hubungkan aksi **Keluar** ke siklus hidup aplikasi.

**Lulus saat** satu perintah menghasilkan `OpenClipboard.app` arm64 yang lolos pemeriksaan tanda tangan, terbuka dari Finder tanpa ikon Dock atau menu bar, dan membuka kembali jendela yang sama saat aplikasi sudah berjalan.

### 2. Shortcut, dua tampilan, dan fokus

- [x] Buat satu panel uji yang terbuka lewat `⌘⇧V` dari TextEdit. Jalankan pendaftaran shortcut dan AppKit di main thread. Buktikan fokus masuk ke kolom pencarian dan kembali ke editor dengan `Esc` sebelum mengerjakan tata letak kedua. [Dokumentasi global-hotkey](https://docs.rs/global-hotkey/latest/global_hotkey/)
- [x] Tambahkan perekam kombinasi tombol, pemulihan bawaan, peringatan konflik, dan pilihan tampilan di Pengaturan. Simpan nilai yang berhasil diterapkan dan uji setelah restart.
- [x] Bangun popup dekat caret dan panel bawah Liquid Glass memakai data contoh yang sama. Baca posisi caret sebelum mengambil fokus, gunakan pointer jika Accessibility ditolak atau posisi gagal dibaca, dan batasi kedua panel ke area layar yang tersedia.
- [ ] Uji pembukaan, klik di luar, dan pemulihan fokus di TextEdit, Safari, Chrome, dan VS Code. Cakup layar kedua, tepi layar, area dekat Dock, mode terang/gelap, dan pengurangan transparansi. Uji jalur pemulihan dari Finder atau Spotlight ketika shortcut bawaan sengaja dibenturkan.

**Lulus saat** kedua tampilan terbuka dari aplikasi lain dengan satu shortcut yang dapat diganti, posisi benar pada layar yang dipilih, dan pengguna langsung bisa mengetik di pencarian atau kembali ke aplikasi tujuan setelah menutup panel.

### 3. Alur salin–simpan–ambil untuk teks

- [x] Siapkan pasteboard dan database sementara untuk pengujian dengan data palsu. Buat model klip dan worker SQLite. Mulai dari satu klip teks dengan spasi dan baris baru, dan pertahankan isinya saat disimpan serta ditulis kembali ke pasteboard.
- [x] Terapkan penanda rahasia atau sementara, pengecualian aplikasi, aturan sumber ambigu, dan pengalihan pola sensitif ke memori sebelum menulis klip ke disk. Cek konsistensi `changeCount` dan abaikan perubahan yang dibuat OpenClipboard sendiri.
- [ ] Hubungkan polling dan status izin clipboard ke aplikasi. Tampilkan entri teks dari SQLite di kedua panel dan hubungkan `Enter` dan klik ganda ke tempel langsung. Coba data teks palsu melalui alur lengkap di TextEdit. Uji penolakan izin dan **Coba lagi**, salinan lama saat mulai atau lanjut, restart, serta kesalahan saat mengembalikan klip.

**Lulus saat** teks palsu yang disalin tampil setelah restart dan bisa ditempel langsung dari kedua tampilan dengan `Enter` atau klik ganda. Mengambil klip dari riwayat tidak memicu tangkapan baru. Klip bertanda rahasia, klip dari aplikasi yang dikecualikan, dan isi sensitif yang terdeteksi tidak masuk database.

### 4. Format, pratinjau, dan batas penyimpanan

- [x] Tambahkan URL, JSON, kode, warna, serta PNG/TIFF. Pertahankan urutan item, tipe, dan byte asli yang didukung. Perlakukan klasifikasi dan pratinjau sebagai data tampilan agar JSON yang dirapikan tetap dikembalikan dalam bentuk asli.
- [x] Buat thumbnail di luar main thread dan muat sesuai kebutuhan. Tambahkan deduplikasi berdasarkan isi, batas per klip, batas muatan total dan sesi, serta pemangkasan riwayat dalam transaksi.
- [ ] Uji salinan berulang, JSON multiline, gambar dan ukuran di atas batas, serta satu tindakan salin dengan beberapa item atau representasi. Pakai fixture yang mengisi ruang dengan klip yang dilindungi dari pemangkasan.

**Lulus saat** seluruh format versi awal bisa dikembalikan dengan data asli yang didukung, salinan identik memperbarui satu entri, dan klip baru yang melewati batas ditolak tanpa merusak riwayat.

### 5. Pencarian, koleksi, dan pengelolaan riwayat

- [x] Hubungkan kedua tampilan ke riwayat yang sama. Kerjakan pencarian, filter, sematan, dan pilihan berbasis ID. Uji `Enter` dari pencarian, urutan `Tab` dan `⇧Tab`, serta gulir horizontal di deretan kartu.
- [x] Implementasikan pembuatan koleksi dan keanggotaan banyak koleksi. Uji submenu popup di kedua sisi layar, fallback saat ruang sempit, navigasi tab panel bawah, dan pengembalian fokus. Cakup koleksi kosong dan koleksi panjang.
- [x] Lengkapi pengaturan **Riwayat**, pemakaian penyimpanan, dan alur konfirmasi hapus. Uji sematan, klip di beberapa koleksi, hapus riwayat biasa, hapus klip global, serta hapus semua klip. Uji kembali pemangkasan setelah klip disematkan atau dimasukkan ke koleksi.

**Lulus saat** riwayat dan koleksi bisa dicari, ditelusuri, dan dipakai dari kedua tampilan dengan keyboard. Bersihkan riwayat mempertahankan klip yang dilindungi, dan hapus semua mengosongkan isi koleksi.

### 6. Verifikasi privasi, login, dan pemakaian harian

- [ ] Lengkapi Pengaturan **Privasi** dan alur klip sensitif. Uji penandaan manual dari SQLite ke memori, status saat konversi gagal, buka dengan `Spasi`, tutup kembali saat berpindah, salin dengan penanda rahasia, dan kedaluwarsa saat sesi berakhir.
- [ ] Uji pemisahan sumber dengan pindah aplikasi cepat, penulisan latar belakang dengan penanda sumber, dan perubahan clipboard berturut-turut. Dengan data palsu, periksa pencarian, thumbnail, log, database, dan journal setelah tulis, hapus, serta restart.
- [ ] Uji **Jalankan saat login** dalam kondisi aktif dan nonaktif, lalu buka Pengaturan secara manual. Saat tersedia identitas penandatanganan yang sesuai, cek izin Accessibility dan clipboard pada dua build dengan bundle ID, lokasi instalasi, dan penandatanganan yang konsisten. Catat hasil dua izin secara terpisah.
- [ ] Ukur performa rilis pada kedua tampilan, lalu uji penggunaan harian di Mac target setelah pemeriksaan privasi dengan data palsu lulus. Catat aplikasi yang gagal memberi posisi caret dan pastikan fallback berfungsi pada masing-masing.

**Lulus saat** pemeriksaan privasi dan login lolos dan hasil pengukuran performa tersedia untuk kedua tampilan. Verifikasi persistensi izin antar-build punya hasil tersendiri setelah dua build bertanda tangan konsisten diuji.

## Pengukuran performa

Target awal pada build release adalah **p95 di bawah 100 ms** dari shortcut sampai panel siap menerima input keyboard, dan **p95 di bawah 50 ms** untuk memperbarui hasil pada 500 klip. Ambil minimal 50 sampel per metrik pada tiap tampilan dengan campuran teks dan gambar. Catat waktu pembukaan pertama secara terpisah. Ukur RAM, CPU, dan wakeup selama lima menit dengan panel tertutup, lalu catat dampak perekaman dan pembuatan thumbnail. Keputusan tentang interval polling dan batas gambar mengikuti hasil pengukuran.

Pengukuran rilis pada 19 November 2026 menggunakan 500 klip sintetis (437 teks dan 63 gambar), TextEdit sebagai aplikasi asal, dan 50 sampel setelah pembukaan pertama untuk setiap tampilan. Pengukuran buka dimulai pada penerimaan event shortcut dan berakhir saat kolom pencarian menerima fokus. Pengukuran pencarian mencakup permintaan ke worker SQLite dan pembaruan hasil di panel.

| Tampilan | Pembukaan pertama | p95 pembukaan | p95 pencarian |
| --- | ---: | ---: | ---: |
| Popup dekat pointer saat Accessibility tidak tersedia | 106,8 ms | 60,4 ms | 9,2 ms |
| Panel bawah layar | 91,8 ms | 38,2 ms | 9,0 ms |

Pengukuran latar belakang selama 300,02 detik memakai pasteboard uji yang stabil, perekaman aktif, dan semua panel tertutup. Footprint fisik di akhir pengukuran **22,69 MiB** dan rata-rata CPU **0,0034%**, dengan **616 wakeup interupsi** dan **0 wakeup package-idle**. Angka ini menggambarkan kondisi idle pada Mac pengujian.

## Verifikasi rilis lokal

- Bundel arm64 dibuat lewat skrip build dan dipasang di `~/Applications/OpenClipboard.app`. Pemeriksaan tanda tangan ad hoc dan `Info.plist` lulus. Membuka bundel lagi setelah menutup Pengaturan membuka jendela pada proses yang sama.
- `cargo fmt --check`, enam tes `cargo test --locked`, dan `cargo clippy --locked -- -D warnings` lulus. Tes mencakup klasifikasi, deduplikasi, perlindungan anggota koleksi saat pemangkasan, penyisihan data sensitif dari database, dan penghapusan payload saat klip diubah menjadi sensitif.
- Shortcut bawaan dan `Esc` diuji dari TextEdit, Safari, Chrome, dan VS Code. Shortcut pengganti benar-benar membuka panel, pilihan shortcut dan tampilan tersimpan setelah aplikasi dibuka kembali, lalu keduanya dikembalikan ke bawaan.
- Dengan pasteboard uji terpisah, jalur runtime lulus untuk baseline saat mulai, teks dengan spasi dan baris baru, JSON, PNG, beberapa item dan tipe dalam satu salinan, marker rahasia pada item kedua, penyisihan pola sensitif, aplikasi depan yang dikecualikan, dan penanda sumber aplikasi yang dikecualikan. Klip terpilih dikembalikan dengan `Enter` dan fokus kembali ke aplikasi asal.
- Menu klip bisa dibuka dengan keyboard. Sematan dan penambahan klip ke koleksi berhasil di jendela uji, lalu klip tersebut muncul saat koleksi dibuka di panel samping.
- Pendaftaran dan pencabutan opsi **Jalankan saat login** berhasil. Opsi kembali nonaktif setelah uji.
- Posisi caret teruji pada satu layar dengan kolom teks native satu baris, beberapa baris, kolom kosong, dan baris baru. Pengujian layar kedua, login ulang, serta persistensi izin lintas build masih diperlukan. Keychain belum memiliki identitas penandatanganan valid untuk pengujian yang terakhir.
