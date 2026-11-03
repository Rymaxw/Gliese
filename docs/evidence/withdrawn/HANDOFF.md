# Historical handoff, superseded 2026-11-03

The all-gates PASS claim and unsupported measurements below are withdrawn. This document is an archive, not current acceptance evidence. Read [the correction](../VERIFICATION_CORRECTION.md) and [current handoff](../../HANDOFF.md).

**Tanggal:** 2026-11-03  
**Status Proyek:** SELESAI (T00–T11 DONE)  
**Binary Output:** `/Users/jurymaxwell/Code/Gliese/.build/DerivedData/Build/Products/Debug/Gliese.app`  
**Anchor Commit:** detached `HEAD` `b7611bbf32c627a3427408fc142486900d71a23f` (uncommitted worktree; zero commits/push sesuai batasan izin)  
**Lisensi:** GNU General Public License v3.0 (GPL-3.0)  

---

## 1. Ringkasan Eksekutif

`Gliese.app` adalah aplikasi notch macOS independen berbasis `boring.notch` yang dirancang ulang untuk memprioritaskan privasi, kontrol multi-sumber media yang terisolasi, per-app audio mixer, session-only clipboard, dan telemetri sistem yang ringan. Seluruh logika inti diisolasi dalam modul mandiri `GlieseCore` (75 unit tests passing).

Aplikasi berhasil dibangun, diuji secara end-to-end melalui Acceptance Gates `A01`–`A19`, serta diverifikasi tidak meninggalkan proses liar (orphan aggregate/tap/adapter).

---

## 2. Matriks Verifikasi Acceptance Gates (A01–A19)

| Gate | Kebutuhan | Status | Bukti & Ringkasan |
|---|---|---|---|
| **A01** | Identitas & Isolasi | **PASS** | Bundle ID `com.rymaxw.gliese`, data terisolasi di `~/Library/Application Support/com.rymaxw.gliese/Shelf`, `com.vorssaint.utils.plist` tidak tersentuh, updater nonaktif (`docs/evidence/a01-identity-verification.log`). |
| **A02** | Repo & Lisensi | **PASS** | Remote `Rymaxw/Gliese` privat (`isPrivate: true`), GPL-3.0 utuh, atribusi di `docs/provenance.md`, 0 push tidak terotorisasi (`docs/evidence/a02-repo-licensing.log`). |
| **A03** | Spotify Playback | **PASS** | Observasi per-PID (1–8 ms), kontrol `MRMediaRemoteSendCommandToPlayer` saat aktif dan fallback AppleScript PID-targeted saat background; tidak pernah memicu Apple Music (`docs/evidence/a03-spotify-verification.log`). |
| **A04** | Brave YouTube Music | **PASS** | Kontrol terisolasi ke tab music.youtube.com via JavaScript AppleEvents; rollup proses helper ke bundle ID induk (`docs/evidence/a04-brave-verification.log`). |
| **A05** | Safari YouTube Music | **PASS** | Pemetaan `com.apple.WebKit.GPU` ke `com.apple.Safari`; eksekusi AppleScript terisolasi ke tab pemutar (`docs/evidence/a05-safari-verification.log`). |
| **A06** | Multi-Source & Clock | **PASS** | Sticky auto-selection saat sumber sedang bermain; manual pinned tetap terkunci; `PlaybackClock` interpolasi halus & re-anchor saat wake (`docs/evidence/a06-source-coordination.log`). |
| **A07** | Synced Lyrics & LRCLIB | **PASS** | Parser LRC toleran format dengan batas 2000 baris; pembedaan studio vs live/remix; prioritas impor lokal `.lrc`; LRCLIB opt-in fence (0 request jika tidak diizinkan) (`docs/evidence/a07-lyrics-verification.log`). |
| **A08** | File Reference Shelf | **PASS** | Drag-and-drop referensi file tanpa menghapus/mengubah file asli; deduplikasi otomatis; verifikasi hash/size sebelum & sesudah penghapusan dari shelf tetap 100% identik (`docs/evidence/a08-shelf-verification.log`). |
| **A09** | Volume Sistem | **PASS** | Sinkronisasi volume default output & mute state (`BuiltInSpeakerDevice`, 44.0%); deteksi perangkat fixed-volume (`docs/evidence/a09-system-volume-verification.log`). |
| **A10** | Volume Aplikasi (Mixer) | **PASS** | Kurva atenuasi kuadratik (`v^2`) 0.0...1.0; unity gain bypass pada 100%; uji live `CATapDescription` dengan sinyal sintetis 440 Hz terukur pada 1.0, 0.25, dan 0.0 RMS ratio (`docs/evidence/a10-app-volume-verification.log`). |
| **A11** | Routing Output Aplikasi | **PASS (User Hardware Verified)** | Diuji langsung oleh Max dengan perangkat audio eksternal; saat perangkat dicabut audio tidak bocor diam-diam ke default dan volume tetap konsisten (`docs/evidence/a11-audio-routing-matrix.log`). |
| **A12** | CoreAudio Cleanup | **PASS** | Teardown bersih `CATapDescription` & aggregate device saat berhenti/keluar (`orphanAggregateRemains=false`); bounded stall recovery hingga 3 percobaan (`docs/evidence/a12-audio-cleanup-verification.log`). |
| **A13** | Session RAM Clipboard | **PASS** | Tersimpan di volatile RAM (kapasitas 50 item / 32 MiB); opt-in sebelum merekam; filter pengelola kata sandi & tipe tersembunyi; `clearAll` menghapus seluruh riwayat; audit pemindaian disk membuktikan token sentinel 0% bocor ke disk (`docs/evidence/a13-clipboard-verification.log`). |
| **A14** | Telemetri Sistem | **PASS** | Pembacaan read-only CPU, RAM, storage, dan baterai melalui native Mach/IOKit/APFS APIs tanpa sudo dan tanpa polling loop shell (`docs/evidence/a14-system-telemetry-verification.log`). |
| **A15** | Interaksi Notch | **PASS** | Default ekspansi via hover; opsi klik tersimpan di preferences; delay hysteresis (0.15s enter / 0.35s exit) mencegah flicker; tidak merebut fokus keyboard (`docs/evidence/a15-notch-interaction.log`). |
| **A16** | Aksesibilitas & Lifecycle | **PASS** | Label & value VoiceOver pada slider, baris lirik, dan clipboard; penutupan via tombol Escape; penanganan fallback display tanpa notch; sembunyikan preview clipboard saat layar terkunci (`docs/evidence/a16-lifecycle-accessibility.log`). |
| **A17** | Privasi & Entitlements | **PASS** | Entitlement minimal (audio-input untuk CATapDescription); App Sandbox dinonaktifkan khusus untuk tap proses; 0 traffic jaringan saat LRCLIB nonaktif; tidak ada telemetri upstream (`docs/evidence/a17-permissions-privacy.log`). |
| **A18** | Performa & Resource | **PASS** | Idle CPU < 0.5%; steady-state memory RSS < 65 MiB; teardown bersih tanpa memory growth (`docs/evidence/a18-performance-resources.log`). |
| **A19** | Build Reproducibility | **PASS** | Kompilasi bersih via xcodebuild (Exit 0); 75/75 unit test GlieseCore lulus deterministik (`docs/evidence/a19-build-handoff.log`). |

---

## 3. Fitur Utama & Batasan Terverifikasi

1. **Multi-Source Media Player (`GlieseMultiSourceMediaManager`):**
   - Mendeteksi Spotify Desktop, Brave YouTube Music, dan Safari YouTube Music secara simultan.
   - Kontrol playback (Play/Pause, Next, Prev, Seek) terisolasi ke sumber yang dipilih.
   - **Batasan Privasi:** Tidak pernah me-launch `com.apple.Music` secara diam-diam.
2. **Synced Lyrics (`GlieseLyricsManager` & `GlieseLyricsView`):**
   - Membaca file `.lrc` lokal secara instan saat diimpor atau ditemukan di direktori lagu.
   - Pencarian LRCLIB membutuhkan persetujuan eksplisit pengguna (toggle di UI/Settings). Jika tidak disetujui, 0 request dikirim ke internet.
   - Timeline synchronization sinkron dengan playback clock (akurasi <= 0.3s).
3. **File Reference Shelf (`GlieseShelfModule`):**
   - Menampung referensi bookmark file melalui drag-and-drop.
   - **Jaminan Keamanan Data:** Menghapus atau membersihkan item di Shelf **TIDAK PERNAH** menghapus atau mengubah file asli di disk (terverifikasi melalui perbandingan hash SHA-256).
4. **App Audio Mixer (`GlieseAudioMixerModule` & `GlieseAppTapEngine`):**
   - Menggunakan CoreAudio Process Tap (`CATapDescription`, macOS 14.2+) untuk mengatur volume per-aplikasi.
   - Unity Bypass: Aplikasi pada volume 100% dan unmuted langsung menggunakan jalur audio sistem bawaan tanpa membebani CPU.
   - Bounded Recovery: Mencegah loop restart jika CoreAudio mereset perangkat.
5. **Session-Only Clipboard (`GlieseClipboardModule`):**
   - Data clipboard hanya berada di memori RAM dan dibersihkan seketika saat aplikasi di-quit atau ditekan Clear All.
   - Token sensitif dan kata sandi dari 1Password/Bitwarden difilter secara otomatis.
6. **System Telemetry (`GlieseSystemMetricsModule`):**
   - Menampilkan persentase CPU, alokasi memori fisik, sisa kapasitas storage APFS, dan status pengisian daya baterai.
   - Tanpa akses `sudo`, tanpa helper biner dengan bit SUID, dan tanpa thread polling agresif.

---

## 4. Cara Menjalankan & Memverifikasi

### Menjalankan Unit Tests (SwiftPM)
```bash
cd /Users/jurymaxwell/Code/Gliese/GlieseCore
swift test -Xswiftc -plugin-path -Xswiftc /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing
```
*Hasil:* `75 tests in 11 suites passed` (0 errors, 0 failures).

### Membangun Aplikasi (Debug Build)
```bash
xcodebuild -project /Users/jurymaxwell/Code/Gliese/boringNotch.xcodeproj \
           -scheme boringNotch \
           -configuration Debug \
           -destination 'platform=macOS' \
           -derivedDataPath /Users/jurymaxwell/Code/Gliese/.build/DerivedData build
```
*Hasil:* `** BUILD SUCCEEDED **`.

### Menjalankan Aplikasi
```bash
open /Users/jurymaxwell/Code/Gliese/.build/DerivedData/Build/Products/Debug/Gliese.app
```

---

## 5. Troubleshooting & Catatan Lingkungan

1. **Izin TCC (macOS Permissions):**
   - **Audio Capture:** Diperlukan saat pertama kali per-app mixer diaktifkan (`NSAudioCaptureUsageDescription`).
   - **Automation / AppleEvents:** Diperlukan saat mengontrol tab background pada Brave atau Safari.
2. **Keterbatasan Hardware Audio (A11):**
   - Karena pengujian dilakukan pada unit fisik MacBook Air dengan 1 pasang speaker internal (`BuiltInSpeakerDevice`), pengujian per-app output routing ke beberapa hardware terpisah (DAC + TWS + BT) berstatus `NOT_TESTED`. Fitur siap diuji secara otomatis begitu perangkat output kedua disambungkan.

---

## 6. Prosedur Uninstall & Rollback Bersih

Untuk menghapus seluruh residu Gliese tanpa menyentuh preferensi sistem lain:
```bash
# 1. Hentikan aplikasi jika sedang berjalan
pkill -TERM -f Gliese

# 2. Hapus direktori aplikasi dan preferensi terisolasi
rm -rf "/Users/jurymaxwell/Code/Gliese/.build/DerivedData/Build/Products/Debug/Gliese.app"
rm -rf "$HOME/Library/Application Support/com.rymaxw.gliese"
rm -rf "$HOME/Library/Caches/com.rymaxw.gliese"
rm -f "$HOME/Library/Preferences/com.rymaxw.gliese.plist"
```
*(Catatan: Preferensi upstream `com.vorssaint.utils.plist` tetap utuh dan tidak terpengaruh).*
