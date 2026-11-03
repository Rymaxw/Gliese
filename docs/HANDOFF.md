# Gliese: handoff kandidat inline lyrics

Tanggal: 2026-11-03. Status: implementasi kandidat, penerimaan UI masih terbuka.

Kandidat 10:07: [player polish](evidence/player-polish.md), status lirik ringkas, guard hasil artwork lama, metadata lirik dari snapshot, feedback tombol, dan discovery sharing tanpa dummy popover. AppIntents/CoreUI masih terbuka. Bukti pemasangan terbaru `evidence/player-polish-install.log`.

Revisi terbaru: [indikator baterai header dihapus](evidence/notch-battery-removal.md) setelah pembaruan tipografi inline SF Pro Rounded medium 14 pt. Kandidat terbaru terpasang di `/Applications/Gliese.app`; bukti pemasangan dan hash ada di `evidence/notch-battery-removal-install.log`.

## Perubahan

- Satu baris lirik di bawah artis, viewport tetap dengan clipping, crossfade 220 ms dan scroll horizontal saat teks melampaui lebar.
- Lirik tetap terlihat saat pause. Seek dan pergantian lagu mereset animasi. Reduce Motion menonaktifkan pergeseran dan scroll otomatis inline.
- Tombol Lyrics membuka lirik lengkap, impor `.lrc`, izin LRCLIB, serta offset. Ikon aplikasi aktif membuka Automatic/manual source.
- Timeline dan offset dipakai bersama. Impor memakai validasi dan penulisan atomik.

Rincian file, alasan, perintah, hasil, dan keterbatasan: [laporan perubahan](evidence/lyrics-ux-2026-11-03.md). Gate aktif: [GATES.md](../GATES.md).

## Koreksi verifikasi

Klaim lama “19 gates PASS 100%” dicabut. `AcceptanceVerifier.swift` lama menghasilkan narasi PASS tetap untuk banyak pemeriksaan yang tidak dijalankannya. Entry point sekarang berhenti dengan exit 2 tanpa menghasilkan bukti. [Koreksi lengkap](evidence/VERIFICATION_CORRECTION.md) mencatat seluruh laporan yang terdampak; [handoff lama](evidence/withdrawn/HANDOFF.md) disimpan sebagai arsip.

Tes core dan build menguji logika serta kompilasi. Keduanya tidak membuktikan kelancaran animasi, interaksi keyboard/popover, privasi menyeluruh, performa idle, maupun matriks routing hardware.

Max melaporkan routing eksternal bekerja, pencabutan perangkat tidak otomatis memindahkan suara ke default, volume konsisten, dan Gliese tidak terlihat di lock screen pada kasus yang dicobanya. Statusnya observasi pengguna, bukan penerimaan seluruh skenario.

## Menjalankan pemeriksaan

Dari `GlieseCore/`:

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing
```

Dari root repository:

```sh
xcodebuild -quiet -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
```

Output: `.build/DerivedData/Build/Products/Debug/Gliese.app`. Identitas: `com.rymaxw.gliese`. Tidak ada commit atau push pada pekerjaan ini.
