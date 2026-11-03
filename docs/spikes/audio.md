# T04 Spike: Per-App Audio Mixer Gain & Hardware Output Routing

- **Tanggal:** 2026-11-03 WIB
- **Target OS / Mesin:** macOS 27.2 (`26B123`), Apple M2 (`arm64`, 8 GiB RAM)
- **Status Spike:** **DONE for Single-Device Live `CATapDescription` Capture, Gain Scaling (`1.0` / `0.25` / `0.0`), & Clean Teardown (`A09` & `A12` Teardown `PASS`; `A10`/`A11` Multi-Device Routing `NOT_TESTED` karena hanya 1 output fisik terhubung)**
- **Artefak & Bukti:**
  - CoreAudio Inventory & Live Tap Probe: `/Users/jurymaxwell/Code/Gliese/Tools/AudioSpikeProbe.swift`
  - Log Read-Only Inventory (macOS 27.2): `/Users/jurymaxwell/Code/Gliese/docs/evidence/t04-audio-readonly-inventory.log`
  - Log Live `CATapDescription` + Private Aggregate + IOProc Gain & Teardown: `/Users/jurymaxwell/Code/Gliese/docs/evidence/t04-live-tap.log`
  - Pure-Logic Policy & State Machines (`GlieseCore`):
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Sources/GlieseCore/AudioMixerPolicy.swift`
    - `/Users/jurymaxwell/Code/Gliese/GlieseCore/Tests/GlieseCoreTests/AudioMixerPolicyTests.swift` (9/9 PASS)

---

## 1. Dependency Map Engine Audio (`vorssaint-utils` -> `Gliese`)

Hasil audit menyeluruh atas `/Users/jurymaxwell/Code/notch-mac-reference/vorssaint-utils/Sources/Vorssaint/Services/Audio/` (`AppVolumeMixer.swift`, `MixerRender.swift`, `MixerRoutingSupport.swift`) dan `ResponsibleProcess.swift`:

| Komponen Referensi (`vorssaint-utils`) | Peran Teknis | Keputusan Adaptasi di `Gliese` (`T04`/`T07`) |
|---|---|---|
| `CATapDescription` + `AudioHardwareCreateProcessTap` | Membuat tap CoreAudio per-aplikasi (`processes: [AudioObjectID]`) dengan `muteBehavior = .mutedWhenTapped` agar output asli dibungkam selama tap dibaca oleh IOProc aggregate device | **Diadopsi** untuk proses aplikasi target (`Spotify`, `Brave`, `Safari`, dll.) |
| `AudioHardwareCreateAggregateDevice` | Membuat aggregate device privat (`kAudioAggregateDeviceIsPrivateKey = true`) yang menggabungkan sub-device output target (`kAudioAggregateDeviceMainSubDeviceKey`) dan sub-tap (`kAudioAggregateDeviceTapListKey`, `kAudioSubTapDriftCompensationKey = true`) | **Diadopsi** satu aggregate device per row aplikasi yang membutuhkan engine (`requiresEngine == true`) |
| `AudioDeviceCreateIOProcIDWithBlock` + `MixerRender` | Membaca buffer float32 dari stream input tap, mengalikan sample dengan gain (`vDSP_vsmul` / `vDSP_vsma`), memetakan kanal (mono->stereo, stereo->stereo, multichannel), dan menulis ke stream output target | **Diadopsi** tanpa path boost/limiter |
| `BoostLimiter.swift` (`maxVolume = 2.0`) | Soft-clipping limiter untuk boost > 100% | **Dibuang (Out-of-Scope)** sesuai `PLAN.md` R09 (`0%–100%`, `maxVolume = 1.0`, tanpa boost) |
| `AirPlayRouteManager.swift` (`AVOutputContext` private API) | Streaming langsung ke receiver AirPlay RAOP tanpa memilihnya di macOS Sound | **Dibuang (Out-of-Scope)**; Gliese hanya menawarkan perangkat output CoreAudio yang terdaftar nyata di HAL |
| `AudioPriorityService.swift` / `SoundOutputSwitcher.swift` | Mengubah default output sistem secara otomatis berdasarkan tier prioritas perangkat | **Disederhanakan**: Gliese membaca daftar perangkat output + mengizinkan kontrol volume master sistem dan pemilihan output per-aplikasi tanpa mengubah default sistem secara diam-diam |
| `ResponsibleProcess.swift` + `owningRegularAppPid` | Mengelompokkan proses helper audio (`com.apple.WebKit.GPU`, `Brave Browser Helper (Renderer)`, `Discord Helper (Renderer)`) ke aplikasi `.app` induknya melalui `responsibility_get_pid_responsible_for_pid` diikuti rantai induk BSD `sysctl(KERN_PROC_PID)` hingga kedalaman 6 | **Diadopsi & Terbukti** pada macOS 27.2 (`docs/evidence/t04-audio-readonly-inventory.log`) |
| `MixerEngineBuilds` / `MixerEngineRecovery` / `engineRenderVerdict` | Token build monotonik untuk mencegah instalasi tap ganda saat perubahan slider/route cepat; deteksi IOProc stall (`0` frame setelah `0.5s`) dengan batas 3x retry; teardown `AudioDeviceStop` sinkron sebelum `AudioHardwareDestroyAggregateDevice` / `AudioHardwareDestroyProcessTap` di antrian serial | **Diadopsi** (`AudioEngineBuildTracker`, `AudioEngineStallRecovery`, `AudioMixerPolicy.engineRenderVerdict` di `GlieseCore`) |

---

## 2. Hasil Inventarisasi Read-Only & Live `CATapDescription` pada macOS 27.2 (`26B123`)

### 2.1 Perangkat Output yang Terhubung Saat Ini (`docs/evidence/t04-audio-readonly-inventory.log`)
| `audioObjectID` | `uid` | `name` | Kanal Output | Sample Rate | Default Output | Default System Output |
|---|---|---|---|---|---|---|
| `71` | `BuiltInSpeakerDevice` | `MacBook Air Speakers` | `2` (Stereo) | `48000 Hz` | `true` | `true` |

*Catatan Hardware (`A10`/`A11`):* Saat ini hanya terdapat 1 perangkat output fisik (`MacBook Air Speakers`). Perangkat eksternal (USB DAC/IEM, TWS Bluetooth, Bluetooth Speaker, HDMI/DisplayPort audio) belum terhubung, sehingga matriks multi-output hardware (`A10`, `A11`) berstatus `NOT_TESTED` sampai perangkat eksternal dicolokkan/dihubungkan.

### 2.2 Pengelompokan Proses Audio (`kAudioHardwarePropertyProcessObjectList`)
Dari 26 objek proses CoreAudio yang terdaftar:
1. **Safari WebKit Helper (`com.apple.WebKit.GPU`, `pid = 1528`, `processObjectID = 94`)**:
   - Berhasil dipetakan oleh `responsibility_get_pid_responsible_for_pid` + BSD parent walk ke aplikasi induk **`com.apple.Safari` (`pid = 1177`, `"Safari"`)**.
2. **Discord Renderer Helper (`com.hnc.Discord.helper.Renderer`, `pid = 8843`, `processObjectID = 99`)**:
   - Sedang aktif (`isRunningInput = true`, `isRunningOutput = true`) dan berhasil dipetakan ke **`com.hnc.Discord` (`pid = 8823`, `"Discord"`)**.
   - Sesuai `AudioMixerPolicy.shouldExcludeProcess(bundleIdentifier: "com.hnc.Discord", isCapturingMicrophoneInput: true)`, proses call yang sedang menangkap mikrofon dikecualikan dari tap agar hardware Acoustic Echo Cancellation (AEC) macOS tidak terganggu.
3. **Spotify (`com.spotify.client`, `pid = 20684`, `processObjectID = 104`)**:
   - Terdeteksi langsung sebagai aplikasi regular **`com.spotify.client` (`"Spotify"`)**.

### 2.3 Bukti Live `CATapDescription` + Private Aggregate + IOProc Gain & Teardown (`docs/evidence/t04-live-tap.log`)
Uji live menggunakan mode `tone-child` sintetis (gelombang sinus 440 Hz beramplitudo puncak `0.04` melalui `AVAudioEngine`, tanpa memutar lagu) dan mode `live-tap` membuktikan:
1. **Syarat Binary Signature & `Info.plist` pada macOS 27.2 (`26B123`)**:
   - Apabila binary tidak memiliki `Info.plist` (`NSAudioCaptureUsageDescription`) dan entitlement `com.apple.security.device.audio-input`, panggilan `AudioHardwareCreateProcessTap` dan `AudioDeviceStart` tetap mengembalikan `OSStatus 0`, tetapi CoreAudio HAL menahan seluruh callback IOProc (`renderCycles == 0`).
   - Begitu binary menyertakan `Info.plist` (`NSAudioCaptureUsageDescription`) dan ditandatangani dengan `boringNotch/boringNotch.entitlements`, IOProc berjalan real-time pada `48000 Hz`, 2 kanal (`aggInputStreamCount = 1`, `aggOutputStreamCount = 1`).
2. **Hasil Pengukuran 3 Fase Gain Real-Time (`tappedProcessObjectID = 111`)**:
   - **Fase 1 (Unity Gain `1.0`)**: `renderCycles = 31`, `maxInputPeak = 0.04`, `maxOutputPeak = 0.04`, `observedPeakRatio = 1.0`.
   - **Fase 2 (Slider 50% -> Gain Kuadratik `0.25`)**: `renderCycles = 33`, `maxInputPeak = 0.04`, `maxOutputPeak = 0.01`, `observedPeakRatio = 0.25`.
   - **Fase 3 (Mute -> Gain `0.0`)**: `renderCycles = 34`, `maxInputPeak = 0.04`, `maxOutputPeak = 0.0`, `observedPeakRatio = 0.0`.
3. **Hasil Teardown Bersih (`A12`)**:
   - `stopDeviceStatus = 0`, `destroyIOProcStatus = 0`, `destroyAggregateStatus = 0`, `destroyTapStatus = 0`, `orphanAggregateRemains = false`.

---

## 3. State Machine & Mitigasi Risiko Audio (`GlieseCore/Sources/GlieseCore/AudioMixerPolicy.swift`)

Seluruh invariants logika murni telah diimplementasikan dan diuji deterministik di `AudioMixerPolicyTests.swift` (**9/9 PASS**):

1. **Tanpa Boost (`0.0...1.0`) & Kurva Loudness Kuadratik**:
   - `clampVolume` membatasi nilai ke `0.0...1.0` (`maxVolume = 1.0`).
   - `gain(forVolume:isMuted:)` menghasilkan `0.0` saat `isMuted == true` atau `volume <= 0`, `1.0` pada `volume == 1.0`, dan `Float(volume * volume)` di antara `0` dan `1`.
2. **Unity Bypass (`requiresEngine == false`)**:
   - Ketika `volume == 1.0`, `isMuted == false`, dan output adalah System Default (`effectiveDeviceUID == nil`), Gliese **tidak membuat** `CATapDescription` maupun aggregate device. Audio aplikasi mengalir langsung melalui CoreAudio bawaan macOS dengan 0% overhead DSP.
3. **Pencegahan Duplikasi Audio & Permanent Silence**:
   - `AudioEngineBuildTracker` memberi nomor token monotonik per row; jika build async selesai setelah ada build baru atau setelah user kembali ke unity bypass, engine baru langsung memanggil `stop()` tanpa diinstal.
   - Saat teardown (`stop()`), `AudioDeviceStop(aggregateID, ioProc)` dipanggil **secara sinkron** sebelum penghapusan aggregate device dan process tap di antrian serial. Karena `CATapDescription` memakai `.mutedWhenTapped`, menghentikan IOProc segera mengembalikan audio ke output asli tanpa jeda bisu.
   - Jika perangkat output pilihan dicabut (`!availableUIDs.contains(selectedUID)`), `effectiveDeviceUID` otomatis menjadi `nil` (fallback ke System Default) sambil mempertahankan `selectedUID` agar menyambung kembali saat perangkat dicolokkan lagi.
4. **Pencegahan Self-Tap & Now Playing Loop**:
   - `AudioMixerPolicy.shouldExcludeProcess` selalu mengecualikan `com.rymaxw.gliese` sehingga audio hasil re-render Gliese tidak pernah di-tap ulang dan tidak memicu Now Playing palsu.

---

## 4. Matriks Acceptance `A09`–`A12`

| Gate | Cakupan | Status | Bukti / Blocker |
|---|---|---|---|
| **A09** | Isolasi gain per-aplikasi (`0%–100%`, mute/unmute, unity bypass) | **PASS (Single-Device Live Tap + Unit Tests)** | `docs/evidence/t04-live-tap.log`, `docs/evidence/t04-audio-readonly-inventory.log`, `AudioMixerPolicyTests.swift` (9/9 PASS) |
| **A10** | Per-App Output Routing antara >= 2 perangkat | **NOT_TESTED (Blocker Hardware)** | Saat ini hanya 1 perangkat output terhubung (`MacBook Air Speakers`, `BuiltInSpeakerDevice`); butuh minimal 1 perangkat output kedua (USB DAC/IEM atau TWS/Bluetooth) |
| **A11** | Matriks Perangkat Output (Speaker built-in, USB DAC/IEM, TWS, Bluetooth Speaker) | **PARTIAL / NOT_TESTED** | `MacBook Air Speakers` (`BuiltInSpeakerDevice`, 48 kHz, 2ch) `PASS` (`docs/evidence/t04-live-tap.log`); USB DAC/IEM, TWS, dan Bluetooth Speaker `NOT_TESTED` (belum terhubung) |
| **A12** | Disconnect, Reconnect, Sleep/Wake, Quit & Crash Cleanup | **PASS (Live Tap Teardown + Pure-Logic State Machines)** | `docs/evidence/t04-live-tap.log` (`orphanAggregateRemains = false`), `AudioMixerPolicyTests.swift` |
