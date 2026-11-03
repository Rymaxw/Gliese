# Environment Baseline (T00)

Diperiksa ulang langsung pada mesin, 2026-11-02 WIB. Bukan snapshot lama.
Semua perintah di bawah benar-benar dijalankan; hasil ditulis apa adanya.

## Mesin dan OS

| Item | Hasil |
|---|---|
| macOS | 27.2, build 26B123 (`sw_vers`) |
| Arsitektur | arm64 (`uname -m`) |
| CPU | Apple M2, 8 core (`machdep.cpu.brand_string`, `hw.ncpu`) |
| RAM | 8 GiB (`hw.memsize` = 8589934592) |
| Swap | total 2048 MiB, used 1266.88 MiB (tekanan memori ringan) |
| Disk | 330 GiB tersedia pada volume utama (`df -h`) |

Implikasi: 8 GB RAM = maksimal satu build Xcode besar pada satu waktu; tidak paralel dengan pengujian browser + Spotify bersamaan dengan build.

## Toolchain

| Item | Hasil | Implikasi |
|---|---|---|
| Xcode.app | TERPASANG 2026-11-03, v27.2 Build 27B52 (`/Applications/Xcode.app`) | `xcodebuild -checkFirstLaunchStatus` exit 69 (menunggu persetujuan lisensi / first launch) |
| xcode-select | `/Applications/Xcode.app/Contents/Developer` | sudah mengarah ke Xcode penuh |
| `xcodebuild -version` | `Xcode 27.2 Build version 27B52` | T01 baseline build siap dijalankan segera setelah lisensi Xcode disetujui (`sudo xcodebuild -license accept` atau buka Xcode.app) |
| CLT | 27.2.0.0.1792721180 (`pkgutil`) | termasuk SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` |
| Swift | Apple Swift 6.4.2, target arm64-apple-macosx27.2.0 | SwiftPM + swiftc jalan; cocok untuk unit test, probe CLI, dan assembly .app manual untuk kode Gliese sendiri |
| git | 2.54.0 (Apple Git-157) | OK |
| gh CLI | TERPASANG via brew (2.103.3, 2026-11-03) + sudah login sebagai Rymaxw (device flow) | repo private Rymaxw/Gliese dibuat & diverifikasi isPrivate=true; tanpa push |
| ffmpeg/sox | tidak ada | tone uji bisa dibuat via python3 stdlib (WAV) |

## Aplikasi terkait

| Item | Status |
|---|---|
| Brave Browser | Terpasang, v156.1.98.63 |
| Safari | Terpasang (system), macOS 27.2 |
| Spotify desktop | TERPASANG 2026-11-03, v1.3.6.1921 (/Applications/Spotify.app). Akun/login tetap milik Max. |
| Vorssaint | v3.4.3, SEDANG BERJALAN (PID 2067) + watcher now-playing Perl (PID 13816, `/usr/bin/perl .../now-playing.pl ... watch_all`). Tidak dimatikan tanpa izin. Konflik potensial saat spike media/mixer dan pengukuran performa. |

## Perangkat audio saat baseline

`system_profiler SPAudioDataType`:
- Output: MacBook Air Speakers (built-in, 2 ch, default output + default system output).
- Tidak ada DAC/IEM, TWS, atau speaker Bluetooth tersambung saat survey.
- Input: MacBook Air Microphone (built-in).

Implikasi: matriks A11 (per-app route ke DAC/TWS/BT) = NOT_TESTED sampai perangkat dihubungkan oleh Max.

## Checkout source (lihat docs/provenance.md untuk SHA/lisensi)

| Repositori | Lokasi lokal | State |
|---|---|---|
| TheBoredTeam/boring.notch | `/Users/jurymaxwell/Code/Gliese` | clone penuh, checkout pinned b7611bbf32c627a3427408fc142486900d71a23f (detached HEAD, tree bersih), remote `upstream` |
| vorssaint/vorssaint-utils | `/Users/jurymaxwell/Code/notch-mac-reference/vorssaint-utils` | clone penuh; dipakai sebagai referensi terarah, bukan vendor |
| ungive/mediaremote-adapter | `/Users/jurymaxwell/Code/notch-mac-reference/mediaremote-adapter` | clone penuh |

Struktur upstream yang relevan (ditemukan via grep, bukan asumsi):
- `boringNotch/MediaControllers/SpotifyController.swift`: kontrol Spotify desktop via AppleScript `tell application "Spotify"` + DistributedNotification `com.spotify.client.PlaybackStateChanged`.
- `boringNotch/MediaControllers/NowPlayingController.swift`: menjalankan `mediaremote-adapter.pl` + `MediaRemoteAdapter.framework` (prebuilt binary) dari privateFrameworksPath, membaca now playing sistem dan mengirim command.
- `boringNotch/MediaControllers/YouTube Music Controller/`: HTTP client ke `http://localhost:26538` (`/auth/boringNotch` + websocket) = helper/kompanion terpisah; TIDAK ada referensi Brave/Safari/tab. Warning PLAN.md terbukti dari source: controller ini bukan dukungan tab browser.
- Dependency SPM upstream (project.pbxproj): lottie-spm, swift-collections, AsyncXPCConnection, Pow, SkyLightWindow, Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, swiftui-introspect, Sparkle, MacroVisionKit.
- Konfigurasi signing upstream: ad-hoc (`"-"`) pada source tree; detail signing saat setup target (T02).

## Bukti samping toolchain (bukan spike fungsional)

Probe `mediaremote-adapter.pl get` dijalankan pada macOS 27.2 dengan framework vendored upstream: exit 0, output `null` (idle, tidak ada media playing). Artinya: rantai perl + prebuilt framework dapat mengeksekusi MediaRemote tanpa crash pada 27.2; rintangan entitlement MediaRemote (macOS 15.4+) tidak menutup jalur ini karena adapter memanfaatkan /usr/bin/perl ber-entitlement. Spike T03 tetap wajib (media playing aktual, kontrol, targeting).

## Gap/blocker environment

1. BLOCKED (tinggal 1 langkah): Xcode 27.2 (27B52) sudah terpasang, tetapi `xcodebuild` exit 69 karena lisensi Xcode belum disetujui (`sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch` di Terminal Max, atau buka `/Applications/Xcode.app` sekali lalu klik Agree).
2. Spotify desktop TERPASANG 2026-11-03 oleh Max (v1.3.6.1921). Pengujian A03 menunggu spike + izin Automation.
3. DONE: `gh` terpasang + repo private `Rymaxw/Gliese` dibuat (`isPrivate: true`).
4. NOT_TESTED: per-target audio DAC/IEM, TWS, speaker Bluetooth belum ada di mesin.
5. RISIKO: Vorssaint berjalan sekarang dengan watcher MediaRemote-nya sendiri; saat spike, konsumsi MediaRemote oleh dua aplikasi harus dikelola (minta izin menghentikan Vorssaint sementara, hanya untuk spike/hasil).
6. RISIKO: macOS 27.2 sangat baru; adapter upstream teruji README bagi 27.0; kontrol dan targeting harus diverifikasi sendiri (T03).

## Rute build (status)

- Rute A (disarankan; blocker awal): pasang Xcode; T01 baseline pakai xcodebuild pada scheme yang dibaca dari upstream, DerivedData lokal.
- Rute B (tanpa Xcode, untuk kode Gliese sendiri): SwiftPM package + swiftc/CLT dapat membangun CLI probe (media) dan unit-test harness; assembly .app manual `swiftc -o` + Info.plist mungkin, tetapi bukan jalur utama produksi karena upstream xcodeproj + helper + embedded frameworks memerlukan Xcode.

## Perintah yang sudah dijalankan (ringkas)

```
sw_vers; uname -m; xcode-select -p; xcodebuild -version (GAGAL); swift --version;
git --version; df -h /; sysctl hw.memsize hw.ncpu; pkgutil CLTools;
ls /Applications (+ ~/Applications); mdfind com.spotify.client (kosong);
pgrep boring|vorssaint|mixer (Vorssaint 2067 + watcher 13816);
system_profiler SPAudioDataType;
git clone x3 (boring.notch + vorssaint-utils + mediaremote-adapter);
git checkout b7611bb (boring.notch, pinned, detached HEAD, tree bersih);
mediaremote-adapter.pl get (exit 0, output "null")
```

Tidak ada instalasi besar/sudo/perubahan permission yang dilakukan. Tidak ada proses dihentikan.

## Persetujuan yang dibutuhkan dari Max (status: belum ada)

1. DONE (instalasi) / PENDING (lisensi) 2026-11-03: Xcode 27.2 (27B52) terpasang; butuh Max menyetujui lisensi Xcode (`sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch` atau buka Xcode.app sekali).
2. DONE 2026-11-03: Spotify desktop terpasang oleh Max (v1.3.6.1921).
3. (Saat spike) jalankan aplikasi dengan permission prompt: Automation ke Spotify/Brave/Safari; memutarkan audio uji; mematikan Vorssaint sementara saat spike.
4. DONE 2026-11-03: `brew install gh` + izin create repo (Rymaxw/Gliese, isPrivate=true, tanpa push).
