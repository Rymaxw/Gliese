# Player polish, 2026-11-03

Urutan yang disetujui: status lirik, pergantian lagu, feedback tombol, investigasi startup. Kandidat terpasang; penerimaan visual masih terbuka.

## Perubahan dan alasan

1. `boringNotch/private/GlieseLyricsManager.swift`: status inline menjadi “Lyrics unavailable” atau “Unsynced lyrics”. Penjelasan impor, error, dan izin tetap di detail agar inline tidak menjadi petunjuk panjang.
2. `boringNotch/managers/MusicManager.swift`: pemuatan lirik dipanggil langsung dalam update MainActor dengan metadata snapshot, setelah posisi/durasi diperbarui. Menghapus task tertunda yang bisa mencampur judul lama dengan album/durasi baru. Perubahan durasi juga memicu evaluasi query.
3. File yang sama: setiap perubahan konten membuat generation ID baru; callback decode artwork dan warna wajib cocok sebelum diterapkan. Track baru langsung memakai ikon sumber/default sebagai placeholder agar sampul lama tidak menemani judul baru. Snapshot metadata pencocokan diperbarui pada setiap perubahan konten, termasuk lagu berbeda dengan artwork identik. Artwork yang datang terlambat boleh menggantikan placeholder bila generation masih cocok. Ini bukan jaminan kedatangan semua metadata secara atomik dari provider.
4. `GlieseLyricsManager.swift`: tombol Lyrics dan sumber memakai hover background 0.1, pressed 0.18/opacity 0.7, durasi 120 ms, tanpa animasi saat Reduce Motion. Tooltip menyebut Automatic atau Manual beserta sumber. Style dibatasi ke tombol player; isi popover memakai borderless agar ukuran kontrol detail tidak ikut menjadi 28 pt.
5. `boringNotch/components/Shelf/Services/ShareServiceFinder.swift`: discovery memakai `NSSharingService.sharingServices(forItems:)`, mengganti picker yang ditampilkan pada dummy view tanpa window. Tidak ada lagi timeout continuation atau callback discovery bersama.
6. `boringNotch/components/Shelf/Services/QuickShareService.swift`: gambar layanan diraster ke 24×24 sebelum konversi TIFF, menghindari konversi representasi icon tanpa dimensi valid.

## Verifikasi aktual

- `docs/evidence/POLISH_GATES.md` P1: suite core exit 0. Suite core tidak menguji callback AppKit di MusicManager atau visual SwiftUI.
- P2: build terintegrasi exit 0. Setelah pembatasan style popover, build diulang dan exit 0; transcript `player-polish-build.log`.
- `git diff --check`: exit 0.
- Instalasi staging lolos `codesign --verify --deep --strict`; executable build dan instalasi identik SHA-256 `e47d48162890aacdff687a89dbc3c65326b9de307fcf1c8e3669a4efa0c045a1`.
- `/Applications/Gliese.app` dibuka dan PID 43824 ditemukan. Backup `/Applications/Gliese-backup-20261103-100741.app`. Detail `player-polish-install.log`.
- `log show --start '2026-11-03 10:07:41' --style compact --predicate 'process == "Gliese" AND messageType == error'` disimpan di `player-polish-runtime-errors.log`.

## Temuan startup

Log sebelumnya mempunyai ImageIO invalid capacity/finalize dan ShareSheet “view has no window”. Kode discovery benar-benar membuka picker pada view tanpa window. Pada jendela startup kandidat baru, kedua jenis pesan tersebut tidak muncul. Hasil ini dibatasi pada run tersebut, bukan bukti bahwa seluruh jalur sharing bebas error.

AppIntents `NSCocoaErrorDomain Code=4097` untuk `com.apple.linkd.autoShortcut` masih muncul saat registrasi AppKit. Pencarian source Swift repository tidak menemukan deklarasi AppIntent/AppShortcut. Akar penyebab layanan sistem belum dibuktikan; tidak ada perubahan layanan macOS atau penyembunyian log. CoreUI juga melaporkan bundle `com.apple.reminders.sharingextension` tidak ditemukan, serta pesan CFBundle/BaseBoard. Dampak terhadap penggunaan tetap terbuka.

## Delivery review dan handoff

- PASS: status ringkas dengan jalur detail nyata, hover/pressed state pada kode, Reduce Motion dihormati pada feedback baru, build/signature/process smoke check.
- PASS terbatas: guard generation dan metadata snapshot diperiksa pada kode, core regression lulus. Race artwork terintegrasi belum diuji secara otomatis.
- PENDING: pergantian lagu cepat, artwork terlambat, hover/keyboard/focus, interaksi Lyrics/sumber, dan layanan sharing aktual. Accessibility automation sebelumnya tidak tersedia; tidak ada klaim click-through.
- PENDING: diagnosis tuntas AppIntents/CoreUI/CFBundle/BaseBoard. Tidak ada klaim console bersih.

Uji pengguna: ganti beberapa lagu cepat, perhatikan tidak ada sampul/lirik lagu sebelumnya yang kembali; hover dan tekan Lyrics/sumber, pastikan kontrol detail ukurannya normal; cek layanan Shelf masih dapat dibuka pada tindakan share sebenarnya. Tidak ada commit/push.
