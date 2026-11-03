# T05: Peta Arsitektur Aktual & Kontrak Integrasi (`docs/architecture-map.md`)

- **Tanggal:** 2026-11-03 WIB
- **Target OS / Mesin:** macOS 27.2 (`26B123`), Apple M2 (`arm64`, 8 GiB RAM)
- **Status:** **DONE (Dikunci berdasarkan bukti empiris `T02`, `T03`, dan `T04`)**

---

## 1. Pemetaan Modul `ARCHITECTURE.md` ke Path Aktual di `/Users/jurymaxwell/Code/Gliese`

Seluruh pure business logic, state machine, parser, dan policy deterministik ditempatkan di paket SwiftPM lokal `GlieseCore` (`/Users/jurymaxwell/Code/Gliese/GlieseCore`) tanpa impor `AppKit`/`SwiftUI`, sedangkan integrasi OS (`CoreAudio`, `NSPasteboard`, `IOKit`/`Mach`, `NSWorkspace`, `MediaRemote` Perl bridge, dan SwiftUI Notch shell) berada di target aplikasi `boringNotch` (`PRODUCT_NAME = Gliese`, `PRODUCT_BUNDLE_IDENTIFIER = com.rymaxw.gliese`).

| Domain (`ARCHITECTURE.md`) | File Logika Murni (`GlieseCore/Sources/GlieseCore/`) | File Integrasi & UI (`boringNotch/`) | File Unit Test (`GlieseCore/Tests/GlieseCoreTests/`) |
|---|---|---|---|
| **Media & Multi-Source Coordination (`R03`–`R06`)** | `Media/SourceCoordinator.swift`, `Media/PlaybackClock.swift`, `MediaControlPolicy.swift` | `managers/MusicManager.swift`, `MediaControllers/NowPlayingController.swift`, `MediaControllers/SpotifyController.swift`, `Helpers/mediaremote-adapter.pl` | `SourceCoordinatorTests.swift`, `PlaybackClockTests.swift`, `MediaControlPolicyTests.swift` |
| **Lyrics (`R07`)** | `Lyrics/LRCParser.swift`, `Lyrics/LyricsTimeline.swift`, `Lyrics/LyricsMatcher.swift` *(T06)* | `managers/LyricsManager.swift` *(T06)*, `components/Music/LyricsView.swift` *(T06)* | `LRCParserTests.swift`, `LyricsTimelineTests.swift`, `LyricsMatcherTests.swift` *(T06)* |
| **Audio Mixer & Hardware Routing (`R09`–`R12`)** | `AudioMixerPolicy.swift` (`AudioMixerPolicy`, `AudioEngineBuildTracker`, `AudioEngineStallRecovery`) | `managers/VolumeManager.swift`, `managers/AudioMixerManager.swift` *(T07)*, `components/Mixer/AudioMixerView.swift` *(T07)* | `AudioMixerPolicyTests.swift` |
| **Shelf (`R08`)** | `Shelf/ShelfPolicy.swift` *(T08)* | `components/Shelf/Models/ShelfItem.swift`, `components/Shelf/Models/Bookmark.swift`, `components/Shelf/Services/ShelfPersistenceService.swift`, `components/Shelf/ViewModels/ShelfStateViewModel.swift`, `components/Shelf/Views/ShelfView.swift` | `ShelfPolicyTests.swift` *(T08)* |
| **Clipboard Session Memory (`R13`)** | `Clipboard/ClipboardMemoryStore.swift` *(T08)* | `managers/ClipboardManager.swift` *(T08)*, `components/Clipboard/ClipboardView.swift` *(T08)* | `ClipboardMemoryStoreTests.swift` *(T08)* |
| **System Metrics (`R14`)** | `System/SystemMetricsCalculator.swift` *(T09)* | `managers/SystemMetricsManager.swift` *(T09)*, `models/BatteryStatusViewModel.swift`, `components/System/SystemMetricsView.swift` *(T09)* | `SystemMetricsCalculatorTests.swift` *(T09)* |
| **Notch Shell, Settings & Shutdown (`R01`, `R15`–`R19`)** | — | `boringNotchApp.swift`, `ContentView.swift`, `BoringViewCoordinator.swift`, `models/Constants.swift`, `components/Tabs/TabSelectionView.swift`, `components/Settings/SettingsView.swift` | — |

---

## 2. Architecture Decision Records (ADR) dari Temuan Spike `T03` & `T04`

### ADR-01: Observasi Multi-Source Per-PID via `/usr/bin/perl` + Routing Perintah Hybrid (`MediaControlPolicy`)
- **Konteks Empiris (`T03`, macOS 27.2 `26B123`)**:
  1. Proses aplikasi pihak ketiga diblokir dari pembacaan `MediaRemote.framework` secara langsung dan wajib melewati `/usr/bin/perl` sebagai platform binary.
  2. Di dalam `/usr/bin/perl`, fungsi pembacaan per-player (`MRMediaRemoteGetNowPlayingInfoForPlayer`, `MRMediaRemoteGetPlaybackStateForPlayer`, `MRMediaRemoteGetSupportedCommandsForPlayer`) membaca tiap `MRPlayerPath(pid, bundleID)` secara **100% terisolasi** dalam `1–8 ms` untuk `Spotify`, `Brave`, dan `Safari` (`com.apple.WebKit.GPU` dengan `parentBundleID = "com.apple.Safari"`).
  3. Sebaliknya, pada macOS 27.2 (`26B123`), `MRMediaRemoteSendCommandToPlayer` **gagal (`error = 7`)** apabila `kMRMediaRemoteOptionNowPlayingContentItemID` disertakan untuk player non-sistem, dan **dialihkan (`redirected`) oleh `mediaremoted` ke `systemNowPlayingPID`** apabila `target.pid != systemNowPlayingPID`.
- **Keputusan Terkunci**:
  1. **Observasi**: Perluas helper Perl (`boringNotch/Helpers/mediaremote-adapter.pl`) atau bridge multi-source di `MusicManager` agar melakukan enumerasi `MRMediaRemoteGetNowPlayingClients` untuk tiga target wajib (`com.spotify.client`, `com.brave.Browser`, `com.apple.Safari` / `com.apple.WebKit.GPU`) dan mengirim snapshot per-sumber ke `SourceCoordinator`.
  2. **Kontrol Saat `target.pid == systemNowPlayingPID`**: Gunakan `MRMediaRemoteSendCommandToPlayer` **tanpa** `kMRMediaRemoteOptionNowPlayingContentItemID` (dan dengan `kMRMediaRemoteOptionPlaybackPosition` untuk seek `cmd = 24`). Terbukti berhasil (`error = 0`) pada Spotify, Brave YTM, dan Safari YTM.
  3. **Kontrol Saat `target.pid != systemNowPlayingPID` (Sumber Background Pilihan Manual)**:
     - `com.spotify.client`: Gunakan AppleEvents (`Spotify.sdef`: `play`, `pause`, `playpause`, `next track`, `previous track`, `player position`).
     - `com.brave.Browser`: Gunakan tab-targeted AppleEvents (`execute t javascript ...` pada tab `music.youtube.com`).
     - `com.apple.Safari`: Gunakan tab-targeted AppleEvents (`do JavaScript` pada tab `music.youtube.com`) bila `Allow JavaScript from Apple Events` aktif; bila tidak aktif (`error 8`), `MediaControlPolicy` menolak perintah dan menampilkan alasan eksplisit di UI tanpa pernah mengirim fallback ke `MRMediaRemoteSendCommandToPlayer` (agar tidak mengenai Spotify/Brave).
  4. **Perlindungan Non-Apple-Music**: Tidak pernah memanggil `MRMediaRemoteSendCommand` ketika `systemNowPlayingPID == 0`, dan `AppleMusicController` tidak diaktifkan sebagai default.

### ADR-02: CoreAudio Process Tap (`CATapDescription`) + Private Aggregate Device Tanpa Boost/AirPlay
- **Konteks Empiris (`T04`, macOS 27.2 `26B123`)**:
  1. `AudioHardwareCreateProcessTap` membutuhkan `NSAudioCaptureUsageDescription` di `Info.plist` dan `com.apple.security.device.audio-input = true` di entitlements agar IOProc menerima buffer audio (`renderCycles > 0`). Kedua konfigurasi ini sudah terpasang pada `Gliese.app` sejak `T02`.
  2. `CATapDescription(stereoMixdownOfProcesses:)` dengan `muteBehavior = .mutedWhenTapped` dan `isPrivate = true`, dikombinasikan dengan private aggregate device (`kAudioAggregateDeviceIsPrivateKey = true`, `kAudioSubTapDriftCompensationKey = true`), terbukti memproses gain real-time (`1.0`, `0.25`, `0.0`) pada `48000 Hz` dan melakukan teardown bersih (`orphanAggregateRemains = false`).
- **Keputusan Terkunci**:
  1. Gunakan `AudioMixerPolicy` (`0.0...1.0`, kurva kuadratik `v * v`, tanpa boost/limiter, unity bypass `requiresEngine == false` saat `volume == 1.0 && !isMuted && effectiveDeviceUID == nil`).
  2. Kelompokkan proses helper (`com.apple.WebKit.GPU`, `Brave Browser Helper (Renderer)`) ke `.app` induknya melalui `responsibility_get_pid_responsible_for_pid` + BSD `sysctl(KERN_PROC_PID)` hingga kedalaman 6.
  3. Kecualikan `com.rymaxw.gliese` (mencegah self-tap / Now Playing loop) dan aplikasi komunikasi yang sedang aktif menangkap mikrofon (`isRunningInput == true` seperti `com.hnc.Discord` saat voice call).
  4. Pada `applicationWillTerminate` / `SIGTERM` / `SIGINT`, panggil `AudioDeviceStop` secara sinkron diikuti penghapusan IOProc, aggregate device, dan process tap milik Gliese.

### ADR-03: Identitas, Privasi, dan Lifecycle Fitur Non-Scope Upstream
- **Identitas & Penyimpanan**:
  - Bundle ID: `com.rymaxw.gliese` (`Gliese.app`), Helper: `com.rymaxw.gliese.XPCHelper` (`GlieseXPCHelper`).
  - Shelf Persistence: `~/Library/Application Support/com.rymaxw.gliese/Shelf` (hanya menyimpan `Security-Scoped Bookmark` + metadata ringkas; tidak pernah menghapus file asli di Finder).
  - Lyrics Cache: `~/Library/Caches/com.rymaxw.gliese/Lyrics` (bounded LRU, aktif hanya setelah user memberi consent online LRCLIB; import `.lrc` lokal selalu tersedia tanpa jaringan).
  - Clipboard History: **100% RAM (`ClipboardMemoryStore`)**, opt-in, maksimum 50 item / 32 MiB total / 5 MiB per gambar / 1 MiB per teks, menyaring tipe `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`, bertahan saat panel notch ditutup, dan dikosongkan total saat `Quit`.
- **Deaktivasi Fitur Upstream di Luar Cakupan**:
  - `Sparkle` updater, `WebcamManager` (Camera Mirror), `CalendarManager` (EventKit Calendar/Reminders), dan `DownloadView` dinonaktifkan dari runtime dan tab UI Gliese serta tidak meminta permission sistem.

---

## 3. Matriks Kapabilitas yang Telah Dibuktikan vs Blocker Hardware

| Kapabilitas | Status Bukti | Referensi Log Bukti |
|---|---|---|
| Build & isolasi identitas `Gliese.app` (`com.rymaxw.gliese`) + clean exit tanpa proses yatim (`A01`, `A02`) | **PROVEN (`PASS`)** | `docs/evidence/a01-plist-codesign.log`, `docs/evidence/a01-identity-lifecycle.log` |
| Observasi & kontrol penuh Spotify Desktop (`A03`) | **PROVEN (`PASS`)** | `docs/evidence/a03-spotify-live.log` |
| Observasi & kontrol penuh YouTube Music di Brave (`A04`) | **PROVEN (`PASS`)** | `docs/evidence/a04-a05-a06-browsers-multisource-live.log` |
| Observasi & kontrol penuh YouTube Music di Safari (`A05`) | **PROVEN (`PASS`)** | `docs/evidence/a04-a05-a06-browsers-multisource-live.log` |
| Isolasi 3 sumber simultan (`Spotify` + `Brave YTM` + `Safari YTM`) tanpa salah sasaran (`A06`) | **PROVEN (`PASS`)** | `docs/evidence/a04-a05-a06-browsers-multisource-live.log` |
| Live CoreAudio `CATapDescription` + private aggregate + gain scaling (`1.0`, `0.25`, `0.0`) + clean teardown (`A09`, `A12`) | **PROVEN (`PASS`)** | `docs/evidence/t04-live-tap.log`, `docs/evidence/t04-audio-readonly-inventory.log` |
| Routing fisik antar >= 2 perangkat output eksternal (`A10`, `A11`: USB DAC/IEM, TWS, Bluetooth Speaker) | **HARDWARE BLOCKER (`NOT_TESTED`)** | Hanya 1 output (`MacBook Air Speakers`, `BuiltInSpeakerDevice`) yang terhubung saat ini (`docs/evidence/t04-audio-readonly-inventory.log`) |
