# T03 Spike: Multi-Source Media Observation & Control (Spotify, Brave YTM, Safari YTM)

- **Tanggal:** 2026-11-03 WIB
- **Target OS / Mesin:** macOS 27.2 (`26B123`), Apple M2 (`arm64`, 8 GiB RAM)
- **Status Spike:** **DONE (`A03`, `A04`, `A05`, `A06` Live & Pure-Logic Verification `PASS`)**
- **Artefak & Bukti:**
  - Probe CLI / Dylib: `/Users/jurymaxwell/Code/Gliese/Tools/MediaSpikeProbe.swift` + `/Users/jurymaxwell/Code/Gliese/Tools/media-spike-probe.pl`
  - Log Read-Only Probe (macOS 27.2): `/Users/jurymaxwell/Code/Gliese/docs/evidence/t03-media-readonly-probe.log`
  - Log Live Spotify `A03`: `/Users/jurymaxwell/Code/Gliese/docs/evidence/a03-spotify-live.log`
  - Log Live Browsers & 3-Source Isolation `A04`–`A06`: `/Users/jurymaxwell/Code/Gliese/docs/evidence/a04-a05-a06-browsers-multisource-live.log`
  - Pure-Logic Policy & Tests (`GlieseCore`):
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Sources/GlieseCore/SourceCoordinator.swift`
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Sources/GlieseCore/PlaybackClock.swift`
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Sources/GlieseCore/MediaControlPolicy.swift`
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Tests/GlieseCoreTests/SourceCoordinatorTests.swift` (12/12 PASS)
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Tests/GlieseCoreTests/PlaybackClockTests.swift` (10/10 PASS)
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Tests/GlieseCoreTests/MediaControlPolicyTests.swift` (4/4 PASS)

---

## 1. Temuan Arsitektur Empiris pada macOS 27.2 (`26B123`)

### 1.1 Mengapa `mediaremote-adapter` Upstream (`boring.notch`) Tidak Cukup untuk Multi-Source (`A03`–`A06`)
1. Pada macOS 15.4+ hingga macOS 27.2 (`26B123`), `MediaRemote.framework` memblokir panggilan `MRMediaRemoteGetNowPlayingInfo` langsung dari aplikasi non-Apple kecuali dipanggil dari proses platform binary seperti `/usr/bin/perl`.
2. Adapter vendored upstream (`boringNotch/Helpers/mediaremote-adapter.pl` + `MediaRemoteAdapter.framework`) hanya memanggil fungsi global tunggal (`MRMediaRemoteGetNowPlayingInfo`, `MRMediaRemoteGetNowPlayingApplicationPID`, `MRMediaRemoteSendCommand`). Akibatnya:
   - Saat dua atau tiga sumber hidup bersamaan (`Spotify`, `Brave`, `Safari`), adapter upstream hanya melihat satu global system player (`systemNowPlayingPID`).
   - Saat `systemNowPlayingPID == 0`, mengirim `MRMediaRemoteSendCommand` / `MRMediaRemoteSendCommandToPlayer` menyebabkan `mediaremoted` meluncurkan `Music.app` (`com.apple.Music`).
   - Mengirim `MRMediaRemoteSendCommand` global tanpa validasi pemilik sesi berisiko mengenai player yang salah ketika fokus sesi sistem berpindah.

### 1.2 Temuan Kritis macOS 27.2 (`26B123`) pada `MRMediaRemoteSendCommandToPlayer`
Uji live terhadap ketiga aplikasi wajib (`Spotify` PID `20684`, `Brave` PID `68935`, `Safari` `com.apple.WebKit.GPU` PID `1528`) mengungkap 3 aturan sistem pada macOS 27.2 (`26B123`):
1. **Jangan kirim `kMRMediaRemoteOptionNowPlayingContentItemID` ke player pihak ketiga (`!systemPlayer`)**:
   - Pada macOS 27.2, `Spotify`, `Brave`, dan `Safari` mengisi `kMRMediaRemoteNowPlayingInfoContentItemIdentifier` (mis. UUID pada Spotify/Brave, angka ID pada Safari WebKit).
   - Namun jika opsi `kMRMediaRemoteOptionNowPlayingContentItemID` disertakan pada `MRMediaRemoteSendCommandToPlayer` untuk player non-sistem, panggilan **gagal dengan `error = 7`, `handlerCodes = []`, `delivered = false`**.
   - Ketika `kMRMediaRemoteOptionNowPlayingContentItemID` **dihilangkan** (hanya menyertakan `kMRMediaRemoteOptionPlaybackPosition` saat seek `cmd = 24`), `MRMediaRemoteSendCommandToPlayer` **berhasil (`error = 0, handlerCodes = [0], delivered = true`)** untuk `Spotify`, `Brave`, dan `Safari` (`com.apple.WebKit.GPU`).
2. **Pengalihan (`redirect`) oleh `mediaremoted` ketika `target.pid != systemNowPlayingPID`**:
   - Meskipun `MRMediaRemoteGetNowPlayingInfoForPlayer`, `MRMediaRemoteGetPlaybackStateForPlayer`, dan `MRMediaRemoteGetSupportedCommandsForPlayer` membaca tiap `MRPlayerPath(pid, bundleID)` secara **100% terisolasi** dalam `1–8 ms`, panggilan `MRMediaRemoteSendCommandToPlayer`, `MRMediaRemoteSendCommandToClient`, maupun `MRMediaRemoteSetNowPlayingPlayer` dari `/usr/bin/perl` tetap dialihkan oleh `mediaremoted` ke `systemNowPlayingPID` jika `target.pid != systemNowPlayingPID`.
3. **Kontrol Terisolasi Sumber Background (`target.pid != systemNowPlayingPID`)**:
   - Oleh karena itu, `MediaControlPolicy.resolveDispatchRoute` **melarang** pengiriman `MRMediaRemoteSendCommandToPlayer` jika `target.pid != systemNowPlayingPID`.
   - Untuk mengontrol sumber background yang dipilih manual tanpa menyentuh pemilik `systemNowPlayingPID`:
     - **Spotify (`com.spotify.client`)**: Menggunakan PID-targeted AppleEvents (`Spotify.sdef`: `play`, `pause`, `playpause`, `next track`, `previous track`, `player position`). Terbukti mengontrol Spotify di background tanpa menyentuh Brave maupun Safari (`docs/evidence/a04-a05-a06-browsers-multisource-live.log` Bagian 3).
     - **Brave (`com.brave.Browser`)**: Menggunakan tab-targeted AppleEvents (`tell application "Brave Browser"` -> `tabs of windows where URL contains "music.youtube.com"` -> `execute t javascript ...`). Terbukti mengontrol YouTube Music di Brave (seek `75.0s`, play, pause) tanpa menyentuh Spotify maupun Safari, serta otomatis mempromosikan Brave menjadi `systemNowPlayingPID` saat mulai memutar (`docs/evidence/a04-a05-a06-browsers-multisource-live.log` Bagian 4).
     - **Safari (`com.apple.Safari` / `com.apple.WebKit.GPU`)**: Saat `com.apple.WebKit.GPU` memegang `systemNowPlayingPID`, `MRMediaRemoteSendCommandToPlayer` mengontrol Play (`0`), Pause (`1`), Next (`4`), Previous (`5`), dan Seek (`24`) secara langsung tanpa pengaturan tambahan (`docs/evidence/a04-a05-a06-browsers-multisource-live.log` TEST 3). Saat Safari bukan `systemNowPlayingPID`, kontrol background menggunakan `do JavaScript` pada tab `music.youtube.com` bila `Allow JavaScript from Apple Events` diaktifkan di Safari; bila tidak aktif (error `8`), `MediaControlPolicy` menolak fallback ke `MRMediaRemoteSendCommandToPlayer` sehingga tidak pernah mengenai Spotify atau Brave.

---

## 2. Matriks Acceptance `A03`–`A06`

| Gate | Cakupan | Status | Bukti |
|---|---|---|---|
| **A03** | Spotify Desktop (`com.spotify.client`): metadata, artwork, play/pause, next/prev, seek (`90.0s` & `55.0s`), isolasi non-Apple-Music | **PASS** | `docs/evidence/a03-spotify-live.log`, `docs/evidence/a04-a05-a06-browsers-multisource-live.log` |
| **A04** | YouTube Music di Brave (`com.brave.Browser`): active/background tab, metadata, play/pause/seek (`42.0s` via MediaRemote & `75.0s` via tab JS) | **PASS** | `docs/evidence/a04-a05-a06-browsers-multisource-live.log` (Bagian 2 & 4) |
| **A05** | YouTube Music di Safari (`com.apple.Safari` / `com.apple.WebKit.GPU` PID `1528`): resolusi `parentBundleID = "com.apple.Safari"`, metadata, play/pause/seek (`45.0s`) via MediaRemote | **PASS** | `docs/evidence/a04-a05-a06-browsers-multisource-live.log` (TEST 3) |
| **A06** | Koordinasi Multi-Source (`SourceCoordinator` Auto/Manual + isolasi 3 sumber simultan `Spotify` + `Brave YTM` + `Safari YTM`) | **PASS** | `docs/evidence/a04-a05-a06-browsers-multisource-live.log` (Bagian 1–4), `SourceCoordinatorTests.swift` (12/12 PASS), `MediaControlPolicyTests.swift` (4/4 PASS) |
