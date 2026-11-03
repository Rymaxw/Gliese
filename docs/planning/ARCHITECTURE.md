# Gliese: Arsitektur dan Kontrak Modul

Induk: [PLAN.md](PLAN.md). Pengujian: [ACCEPTANCE.md](ACCEPTANCE.md).
Status: rancangan implementasi. Nama tipe/path adalah usulan yang dipetakan ke upstream pada T05, bukan klaim simbol tersebut sudah tersedia.

## 1. Prinsip struktur

Pertahankan proyek native Swift/SwiftUI/AppKit upstream. Tidak memerlukan Electron, web backend, database server atau framework state management baru. Reuse controller yang memenuhi kontrak, jangan menulis ulang demi keseragaman nama.

Struktur logis yang disarankan di bawah source root aktual:

    GlieseCore/
      Media/         provider, source coordinator, playback clock
      Lyrics/        parser, matcher, API client, cache, timeline
      Audio/         device registry, process grouping, gain/routing engine
      Shelf/         file references dan drag/drop
      Clipboard/     memory store, pasteboard observer, privacy filter
      System/        metric samplers dan snapshot
      Settings/      schema, migration, permission state
    GlieseUI/
      Music/ Shelf/ Mixer/ Clipboard/ System/ Settings/
    Tests/
      Media/ Lyrics/ Audio/ Shelf/ Clipboard/ System/ Lifecycle/

Ini pengelompokan tanggung jawab, bukan instruksi mengganti struktur boring.notch secara besar-besaran. Petakan path aktual di docs/architecture-map.md. Pure business logic tidak mengimpor view layer.

Concurrency:
- View-facing state dimutasi pada MainActor.
- Network/cache/clipboard processing berada di actor atau serial queue dengan lifetime jelas.
- Callback real-time audio memakai desain khusus, bukan MainActor/Task per buffer.
- Event OS diubah menjadi snapshot immutable sebelum masuk UI.
- Dependency injection untuk clock, network transport, file access, pasteboard dan audio HAL memungkinkan tests deterministik.
- Target rilis pertama: arm64 pada macOS aktual Max yang diverifikasi di T00. Deployment target dihitung dari baseline dan API yang dipakai; minimum versi tap engine bukan bukti seluruh aplikasi mendukung versi itu. Intel/OS lama tidak diklaim tanpa build dan test.
- Distribusi development lokal menggunakan model sandbox/signing upstream yang dipahami, bukan App Store sandbox yang ditambahkan sembarang. Pada T02 catat sandbox state, signing identity, helper requirement, usage descriptions dan entitlement aktual. Ad-hoc compile tidak membuktikan TCC/helper bekerja; pilih development signing yang tersedia dan diizinkan.
- start/stop idempotent. Semua timer, listener, observer, process, task dan audio object memiliki pemilik dan cleanup eksplisit.

## 2. Media: kontrak dan identitas

Model konseptual:

    SourceID
      provider: spotify | brave | safari
      appBundleID
      sessionID jika tersedia dari backend

    TrackIdentity
      sourceID
      trackID jika sumber menyediakan
      titleRaw, artistRaw, albumRaw?
      durationSeconds? (nil berarti tidak diketahui)
      versionHints: live/remix/acoustic/remaster bila terdeteksi

    PlaybackSnapshot
      sourceID, revision, trackIdentity?
      state: stopped | paused | playing | unavailable
      positionSeconds?, durationSeconds?, playbackRate
      capturedAtMonotonic
      artworkReference?
      capabilities: playPause, next, previous, seek, targetedCommands
      provenance: OS session atau backend terpilih

    MediaProvider
      start(), stop()
      stream snapshots
      execute(command, expectedSourceID, expectedRevision)

Nilai unknown bukan nol. position nil tidak boleh dianggap lagu mulai dari nol. Buffer event dilimit/dedup supaya update artwork tidak mengubah track generation.

### SourceCoordinator

Preference: Auto atau manual SourceID yang konkret. UI dapat mengelompokkan Brave/Safari di Browser, tetapi saat keduanya tersedia pilihan harus menjelaskan browser mana yang aktif.

Auto:
1. Pertahankan sumber terpilih selama playing.
2. Jika sumber terpilih stopped/unavailable dan ada kandidat playing, pilih kandidat yang baru mulai berdasarkan event transisi playback, bukan update metadata/artwork.
3. Jika sumber paused, jangan berpindah hanya karena ada metadata baru; boleh berpindah ketika sumber lain benar-benar mulai playing.
4. Dua playing bersamaan: pertahankan sumber terpilih. Saat cold start tanpa pilihan, gunakan event start paling baru yang dapat dipercaya; jika tidak diketahui gunakan urutan deterministik dan tampilkan source switcher, bukan mengklaim tebakan sebagai maksud pengguna.
5. Tidak mengirim pause otomatis ke sumber lain.

Manual: tetap pada sumber pilihan. Bila hilang, tampilkan unavailable; tidak mengontrol sumber lain sebagai fallback diam-diam.

Command safety:
- Tangkap expectedSourceID dan generation saat aksi dibuat.
- Revalidasi sebelum dispatch, khususnya slider seek yang diseret ketika lagu berpindah.
- Jika backend hanya menyediakan global command, jangan menandai targetedCommands=true. Dalam keadaan ambigu, disable dan jelaskan, atau lakukan integrasi baru yang disetujui.
- Jangan melakukan optimistic update permanen; konfirmasi lewat snapshot atau rollback dengan pesan kegagalan.
- Debounce seek ketika slider digerakkan, kirim nilai final saat dilepas. Seek disabled jika duration/seek capability tidak diketahui.

### Timeline

Berdasarkan snapshot position, monotonic time dan rate. Saat paused posisi tetap. Saat seek/track change/rate change gunakan snapshot baru, bukan menambahkan delta lama.

Clamp ke rentang track bila durasi valid. Re-anchor sesudah sleep/wake; jangan menganggap monotonic delta yang mencakup suspend cocok untuk semua backend. Nilai negatif/nonfinite ditolak.

State musik hilang mematikan ticker dan invalidasi track generation. Album art decode off main, ukuran dibatasi dan cached; invalid artwork tidak menyebabkan retry loop.

### Integrasi browser

First choice: adapter upstream dengan data system Now Playing. Uji apakah title, artist, time dan sumber browser tersedia, serta apakah command dapat menargetkan sesi yang dipilih.

Jangan gunakan YouTubeMusicController HTTP upstream tanpa memastikan target aplikasinya. Jangan memakai CDP/devtools port, scraping cookies, history browser, Google tokens, atau remote-debugging sebagai dependency produk normal.

Jika extension dibutuhkan:
- Stop dan minta izin, serta catat bahwa ini perubahan cara instalasi.
- Brave Chromium extension dan Safari Web Extension memiliki packaging/permission/native messaging berbeda; jangan menjanjikan satu manifest langsung bekerja pada keduanya.
- Scope host hanya music.youtube.com, message schema bounded, allowed commands spesifik, validasi origin dan native host identity. Tidak ada arbitrary shell execution.
- Perlu ADR dan tests tersendiri sebelum menjadi solusi produksi.

## 3. Lyrics

Model:

    LyricLine: timestampSeconds, text, stableOrdinal
    LyricsDocument: trackMatch, lines, plainText?, source, fetchedAt, timingOffset
    LyricsState: disabled | consentRequired | loading | synced | plain |
                 instrumental | notFound | offline | rateLimited | error

### Parser

- Input UTF-8 dengan BOM opsional; ukuran maksimum 128 KiB sebagai default awal.
- Mendukung timestamp mm:ss, mm:ss.xx, mm:ss.xxx, beberapa timestamp pada satu baris, metadata tags, offset global sesuai semantik LRC.
- Sort stable timestamp, pertahankan order duplikat deterministik. Jangan crash pada timestamp malformed, baris kosong, CRLF, Unicode, atau tag tak dikenal.
- Maksimum 2000 baris; hindari regex backtracking tak terbatas.
- Pisahkan offset file dan offset penyesuaian pengguna, jangan menghitung keduanya dua kali.
- Active line adalah baris terakhir yang timestamp-nya <= playback position yang disesuaikan. Sebelum baris pertama tidak ada active line.
- Unit tests untuk boundary tepat pada timestamp, setelah baris terakhir, pause, seek mundur, offset negatif, dan waktu tidak finite.

### Fetch dan pencocokan

1. Periksa consent dan cache; local .lrc tidak membutuhkan consent jaringan.
2. Exact lookup LRCLIB dengan title/artist/album/duration yang benar-benar tersedia.
3. Search terbatas bila exact not-found/ambigu; jangan looping semua variasi metadata.
4. Bandingkan judul/artis/durasi/versi. Label live/remix/acoustic adalah pembeda penting, bukan noise yang boleh dibuang untuk auto-accept.
5. Jika ambigu, tampilkan kandidat untuk pilihan manual. Durasi tidak diketahui harus mengurangi confidence, bukan dianggap cocok.
6. Instrumental/plain/notFound punya state berbeda.

Default teknis:
- HTTPS dan User-Agent Gliese/version; jika repo private tidak perlu mengirim URL repo private ke API. Verifikasi format header yang diminta dokumentasi LRCLIB terkini.
- Timeout request 10 detik; maksimal satu request aktif per track generation; hentikan request saat lagu berubah atau consent dicabut. Gunakan generation monotonik selain TrackIdentity: urutan A-B-A tidak boleh menerima respons A dari sesi pertama.
- Retry transient maksimal dua kali dengan backoff/jitter; hormati Retry-After untuk 429. Jangan retry not-found seperti server error.
- Cache key menyertakan normalized title/artist/album bila relevan, duration, version hints dan schema version. Jangan mengandalkan title saja.
- Cache disk dibatasi 20 MiB sebagai titik awal; LRU. Negative cache hanya true notFound, masa berlaku 6 jam. Offline/429/error tidak menjadi negative hit.
- Consent dicabut: hentikan jaringan, default tidak menggunakan ulang cache online sampai pengguna memilih kebijakan; local import tetap tersedia. Clear lyrics cache menghapus artefak Gliese saja.
- URLSession cache dimatikan untuk mencegah salinan cache tersembunyi di luar kebijakan. Jangan log query lengkap bila dapat dihindari.

Privacy: query membocorkan metadata lagu ke LRCLIB setelah consent; jelaskan itu. Tidak mengirim audio, clipboard, URL tab lain atau cookie. Jangan menyatakan cache lyrics tidak mengandung kebiasaan mendengar; user bisa membersihkannya.

### Rendering

Utamakan current line dengan konteks baris tetangga. Perubahan teks tidak mengubah tinggi panel setiap suku kata. Update hanya ketika baris berubah atau interaksi, bukan redraw seluruh view 60 Hz.

Offset UI default step 0.5 detik, batas awal -10 sampai +10 detik dan reset. Simpan offset per recording match, bukan seluruh judul. Scroll manual menghentikan auto-follow sementara dengan tombol Follow yang nyata.

## 4. Audio mixer dan routing

Ini modul berisiko paling tinggi. Gain dan routing bukan sekadar binding slider.

Model:

    AudioDeviceDescriptor
      uid (persistable identity), currentObjectID (ephemeral)
      name, transport, outputChannels, sampleRate?, available
      capabilities: systemVolume, systemMute

    AudioApplicationIdentity
      bundleID?, executableIdentity?, currentProcessObjects
      displayName; jangan grouping hanya dengan nama tampilan

    MixerPreference
      gain: 0...1, muted
      route: followSystem | explicitDeviceUID

    MixerRuntimeState
      bypass | requestingPermission | preparing | active |
      deviceUnavailable | recovering | failed | stopping

ObjectID/PID tidak persisten: refresh pada app restart dan device re-enumeration. UID pun bisa hilang/berubah untuk perangkat tertentu; jangan menganggap model name pengganti aman untuk route.

### Per-app gain

- 100%, unmuted, followSystem: bypass tanpa engine jika backend memungkinkan.
- Gain selain unity, mute, atau explicit output: engine sesuai kebutuhan.
- Mute harus independen dari last nonzero gain, supaya unmute kembali ke nilai yang benar dan tidak melonjak ke 100%.
- Clamp values; tidak ada boost. Uji slider 0, intermediate, 100 serta perubahan cepat.
- Gunakan gain ramp untuk menghindari clicks; durasi awal 10 ms sebagai parameter teknik yang diuji, bukan jaminan kualitas.
- CoreAudio system master volume mempengaruhi output; mixer per-app gain tidak boleh mengubah volume perangkat untuk menyimulasikan per-app control.

### Routing

- Pilihan perangkat berdasarkan output yang benar-benar tersedia. Header dapat menunjukkan default sistem; setiap row punya route sendiri.
- FollowSystem mengikuti perubahan default device. ExplicitDeviceUID tidak pindah ke output lain tanpa kebijakan yang terlihat.
- Satu aplikasi ke satu output. Tidak perlu menyinkronkan DAC, TWS dan speaker Bluetooth, dan tidak perlu mirror satu app ke semua device.
- Browser multiprocess perlu resolusi group yang benar. Enumerasi process audio dan ancestry/identity harus diuji pada Brave/Safari. Tidak menjanjikan per-tab control.
- Jangan menangkap output Gliese/engine sendiri dan memainkannya kembali sebagai input. Filter engine processes/devices untuk mencegah feedback loop.
- Pro audio/DAW dan aplikasi panggilan di luar matriks dukungan awal. Terapkan pengecualian defensif atau peringatan untuk aplikasi panggilan: rerender bisa mempengaruhi screen-share/echo cancellation. Jangan ikut menangkap mic untuk fitur mixer.

### Engine transaction

Rancang operasi sebagai transaksi dengan rollback:
1. Resolve identity/device dan generation, validasi izin.
2. Siapkan tap + aggregate/render sesuai pola API yang diverifikasi pada versi OS.
3. Start jalur render dan cek progress/health sebelum mengumumkan active.
4. Hanya publish UI active setelah operasi selesai dan device masih sama.
5. Jika gagal, rollback object/listener/IOproc yang sudah dibuat; jangan meninggalkan mute source tanpa jalur output.

Urutan teknis mute/tap/start harus ditentukan dari API nyata dan hasil spike. Dokumen ini tidak menganggap pembuatan tap yang memute source otomatis aman atau atomik.

Callback real-time:
- Tidak ada allocation, logging, lock blocking, network, disk, SwiftUI update atau Task creation di render callback.
- Preallocate buffer/state. Validasi interleaved/non-interleaved layout, channel count, Float format dan frame bounds. Silence output yang tidak diisi agar tidak memutar uninitialized memory.
- Bounded ring/atomic state untuk gain/control; jangan membawa actor await ke render path.
- Cleanup menunggu callback aman tanpa deadlock; callback tidak memakai object yang sudah dihancurkan.

### Disconnect dan recovery

Default yang diusulkan: explicit route yang hilang tidak otomatis dipindahkan ke speaker. UI menunjukkan output unavailable dan pilihan pengguna.

Namun, tap/process termination dapat mengembalikan jalur output asli. Uji apakah silent holding atau source pause memang dapat dijamin. Jangan mengklaim "privasi terjamin saat crash". Jika fail-closed tidak dapat dibuktikan, tampilkan limitation sebelum pengguna mengaktifkan routing dan minta keputusan Max untuk menerima risiko atau mengubah scope.

- Reconnect device UID sama: revalidate format/rate, siapkan engine baru; jangan reuse stale IDs.
- Default device berubah: rebuild route followSystem secara terkontrol. Explicit route tidak berubah.
- Sleep: suspend/release sesuai backend; wake refresh identities dan re-anchor. Tidak busy retry loop.
- Retry recovery maksimal terbatas dengan cooldown; user dapat disable mixer agar kembali ke OS.
- Normal Quit: stop engine, destroy IOproc/tap/aggregate yang DIMILIKI Gliese, remove listener, terminate helper milik sendiri. Jangan menghapus aggregate pengguna atau mengubah semua device defaults.
- Crash: ukur state nyata setelah proses hilang. Tidak ada desain yang boleh mengandalkan defer selalu berjalan saat SIGKILL.

Preferences gain/route default hanya sesi untuk rilis pertama, terpisah dari UI settings yang persisten. Ini menghindari routing mengejutkan saat restart sebelum perilaku stabil. Bila diperlukan persistensi mixer, buat keputusan baru dengan Max; jangan menyimpan PID/ObjectID.

## 5. Shelf

ShelfItem: UUID, original file URL/bookmark data, displayName, availability, createdAt. Metadata minimum; tidak ada file-content indexing.

- Add: validasi file URL, dedup canonical reference dengan memperhatikan symlink; jangan resolve/membaca seluruh file besar tanpa kebutuhan.
- Prefer bookmark persistence sesuai sandbox/permission model aktual. Security-scoped access dibuka hanya selama operasi dan selalu ditutup.
- Drag out menawarkan file reference dan copy semantics. Jangan memindahkan file asli secara implisit. Uji tujuan Finder dan app lain karena operasi final dipengaruhi drag negotiation.
- Remove/Clear hanya menghapus item/bookmark Gliese.
- Missing/unmounted: tandai unavailable, tampilkan relink/reveal sesuai keadaan; tidak otomatis membuat file pengganti.
- Default maksimal 100 item sebagai batas awal; oversized list tidak menghabiskan thumbnails tak terbatas.
- Thumbnail bersifat on-demand dan bounded. Jangan upload untuk preview. Hindari menyimpan salinan konten file di cache tanpa alasan.
- Pada Quit refs boleh tersimpan, sesuai default Shelf; berbeda dari clipboard. Informasikan di Settings.

## 6. Clipboard

Model: ClipboardEntry(UUID, type, payload, contentFingerprint, capturedAt, sourceAppHint?, pinned). Payload hanya RAM milik proses. Link adalah teks, bukan fetch/preview URL otomatis.

Capture:
- Opt-in pertama kali; sampling NSPasteboard.changeCount awal 500 ms hanya ketika capture aktif.
- Set baseline changeCount saat start/resume. Jangan mengimpor clipboard yang sudah ada sebelum opt-in/resume karena pengguna belum menyalinnya dalam sesi capture.
- Hanya baca tipe yang didukung dan ukuran dibatasi. Jangan meminta konversi promised data yang berpotensi mahal dari aplikasi lain tanpa batas.
- Tipe confidential/transient/concealed di-skip. Ignore-app list memakai best-effort source hint; frontmost app tidak selalu pemilik clipboard. Jelaskan keterbatasan, jangan klaim proteksi password sempurna.
- Secure Input tidak dipakai sebagai izin untuk membaca lebih banyak data. Tidak perlu keylogger atau Accessibility tree.
- pause menghentikan pembacaan payload. Resume tidak backfill konten selama pause.

Memory limits default:
- 50 entries, 32 MiB total, image payload maksimal 5 MiB, decoded-image dimensions/pixel budget juga dibatasi agar compressed image kecil tidak menjadi allocation raksasa.
- Text payload maksimal 1 MiB.
- Evict entry non-pinned tertua. Pinned tetap tunduk pada global cap; jika semua pinned, tolak entry baru dengan indikator nonintrusif, bukan unbounded growth.
- Dedup konten consecutive; copy kembali dari UI tidak menambah duplikat berulang.

Lifetime:
- Tutup panel tetap menyimpan history dalam RAM.
- Quit/termination mengakhiri history; restart mulai kosong. Pin tidak persisten.
- History tidak ditulis ke SQLite/JSON/temp files, thumbnails disk, autosave UI, crash breadcrumbs atau logs.
- OS swap/crash dump tidak dapat dijamin nihil oleh aplikasi. Sebut kebijakan ini "tanpa persistensi history oleh Gliese", bukan secure erasure seluruh mesin.
- Clipboard sistem macOS bukan history Gliese. Quit tidak mengosongkannya; jangan mengubah clipboard sistem tanpa aksi terpisah pengguna.
- Clear all menghapus payload dan preview references; test memory release, bukan sekadar array kosong dengan retain lain.

## 7. System metrics

Tidak memerlukan root, helper privileged atau polling shell command.

Battery:
- Gunakan API power source yang sesuai. Tampilkan percent + charging; unknown/desktop/no battery ditangani tanpa angka palsu.
- Event-driven bila tersedia; fallback poll konservatif.

CPU:
- Gunakan delta tick cumulative antara dua sampel. Usage total dinormalisasi 0 sampai 100% seluruh mesin, bukan 100% per core yang dijumlahkan.
- Sampel pertama nil/collecting, bukan 0% yang dibuat-buat.
- Handle counter reset/wake; baseline baru bila delta tidak valid.

RAM:
- Baca total physical memory dan statistik VM yang terdokumentasi. Definisikan formula sebelum memberi label "Used".
- Jangan double-count compressed pages atau menjumlahkan bytes dan page counts. Page size dibaca dari host, bukan hardcode.
- Cached/reclaimable tidak otomatis dianggap used by apps. Bila formula tidak sepadan dengan Activity Monitor, jelaskan perbedaannya; tidak memalsukan kesamaan angka.
- Memory pressure hanya ditampilkan bila ada API semantik yang valid; jangan mengubah persen RAM menjadi label pressure.

Storage:
- Volume utama yang menyimpan data pengguna, bukan menjumlahkan System/Data APFS seolah disk terpisah.
- Tetapkan arti available bytes dan apakah termasuk purgeable; bandingkan dengan API yang sama. Tidak scan folder.

Lifecycle default:
- CPU/RAM sampel setiap 2 detik ketika System panel terlihat; storage 60 detik atau saat panel dibuka setelah stale.
- Saat panel tersembunyi hentikan polling CPU/RAM yang tidak diperlukan; battery event subscription boleh tetap murah.
- Display values memiliki timestamp/stale state. Jika API gagal, tampilkan unavailable bukan sampel lama sebagai live.

## 8. Settings, data, permission dan shutdown

Persisten di domain Gliese:
- schemaVersion; openMode hover/click; interval UI tuning.
- opt-in clipboard (boolean saja, bukan history); ignored apps.
- online lyrics consent; settings/offset/cache sesuai policy.
- Shelf references.
- launch at login opt-in; tidak otomatis aktif.

Nonpersisten:
- clipboard payload/pins/search query.
- audio runtime objects/PIDs dan preference gain/route versi pertama.
- browser session identifiers sementara.

Data paths diturunkan dari bundle identity menggunakan FileManager/Application Support/Caches. Jangan hardcode /Users/jurymaxwell pada kode aplikasi. Path pengguna hanya untuk dokumentasi mesin handoff.

Permission inventory:
- System audio capture: hanya saat mixer diaktifkan; teks menjelaskan pemrosesan lokal, tidak merekam ke file/tidak upload. Nama prompt tergantung OS, catat aktual.
- Automation untuk Spotify bila backend memerlukan, diminta saat aksi relevan.
- Files: drag/open dialog, jangan Full Disk Access global.
- Accessibility: jangan minta kecuali fitur yang benar-benar perlu dan sudah disetujui. Clipboard copy dan hover tidak membenarkan izin itu.
- Browser extension: bersyarat, izin Max dahulu.
- Network: LRCLIB setelah consent; verifikasi audit tidak membawa updater/telemetry upstream. Download dependency saat build bukan koneksi runtime.

Shutdown urutan: tandai stopping, cegah command baru, cancel network, stop sampling/pasteboard, clear memory payload, stop media helper dan audio engine secara aman, persist settings non-sensitif, exit. Tidak ada retry worker yang hidup sesudah stop.

Settings migration memiliki schema dan backward fallback yang konservatif. Tidak membaca/memigrasi defaults Vorssaint tanpa persetujuan. Reset hanya domain dan file Gliese yang dikenal; hindari wildcard delete.
