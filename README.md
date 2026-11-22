# OpenClipboard

OpenClipboard menyimpan riwayat clipboard di Mac. Kalau kamu sudah menyalin hal lain dan ingin mengambil salinan sebelumnya, tekan `⌘⇧V`, cari klipnya, lalu tekan Enter untuk menempelkannya ke aplikasi yang sedang kamu pakai.

## Cara pakai

- Buka riwayat lewat `⌘⇧V` atau ikon OpenClipboard di bar menu. Pintasannya bisa diganti dari Pengaturan.
- Pilih popup dekat kursor teks atau panel di bagian bawah layar.
- Sematkan klip yang sering dipakai dan masukkan klip terkait ke dalam koleksi.
- Aktifkan izin Accessibility dari Pengaturan OpenClipboard agar klip bisa langsung ditempel ke aplikasi asal.

## Riwayat dan privasi

Riwayat tersimpan secara lokal di Mac. Kamu bisa mengatur batas jumlah klip dan lama penyimpanannya, serta mengecualikan aplikasi yang clipboard-nya tidak ingin direkam. Klip yang ditandai sensitif, baik secara manual maupun lewat deteksi pola, hanya disimpan di memori selama aplikasi berjalan.

## Build dari source

Skrip build membuat aplikasi untuk Mac Apple Silicon dengan macOS 27.0 atau lebih baru. Siapkan Rust lewat rustup dan Xcode atau Command Line Tools dengan SDK macOS 27. Versi Rust mengikuti `rust-toolchain.toml`.

```sh
git clone https://github.com/ryan-prayoga/OpenClipboard.git
cd OpenClipboard
./scripts/build-app.sh
open dist/OpenClipboard.app
```
