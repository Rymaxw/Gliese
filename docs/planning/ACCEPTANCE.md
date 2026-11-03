# Gliese: Acceptance dan Evidence

Induk: [PLAN.md](PLAN.md). Semua gate aplikasi saat dokumen dibuat: NOT_TESTED.

## 1. Aturan bukti

PASS hanya setelah langkah dijalankan dan hasil aktual cocok. FAIL berarti sudah diuji tetapi tidak memenuhi. BLOCKED berarti terhalang izin/toolchain. NOT_TESTED berarti belum diuji, termasuk hardware tidak tersedia. NOT_APPLICABLE harus disertai alasan dan tidak boleh dipakai untuk menghapus browser atau fitur wajib.

Setiap record menyimpan: gate ID, requirement ID, git SHA/dirty state, OS/build, browser/app version, device UID yang disamarkan seperlunya, langkah, expected, observed, command/exit code, path log/screenshot, waktu, keterbatasan, reviewer. Bukti UI/hardware dapat manual; jangan menggantinya dengan unit test yang hanya mock.

Simpan di docs/evidence/. Jangan merekam desktop pribadi, clipboard, cookie, token, konten akun atau audio tanpa izin. Gunakan file dummy dan audio uji yang pengguna setujui. Identifikasi hardware boleh lokal, tetapi sanitasi sebelum report dibagikan.

Tidak ada test yang benar-benar dijalankan dalam penyusunan paket ini.

## 2. Gate per kebutuhan

### A01 / R01: identitas
- Inspect bundle: display name Gliese, bundle ID sendiri, helper/XPC identifiers konsisten, prefs/storage sendiri.
- Launch tidak menimpa aplikasi resmi dan tidak migrasi defaults Vorssaint.
- Updater upstream tidak berjalan. Icon final boleh pending pada development build dan harus dilabeli, bukan mengaku branding selesai.
- Bukti: plist/codesign inspection, lifecycle log, app path.

### A02 / R02: repo dan lisensi
- Origin menuju repo private terpisah; upstream tetap boring.notch.
- Verifikasi GitHub private=true setelah create dan sebelum push. Jika repo belum diizinkan, tandai remote gate pending tanpa menghalangi build lokal.
- LICENSE/third-party notices/provenance sesuai kode yang dipakai.
- Tidak ada push/commit tanpa izin/pesan yang diminta.
- Bukti: sanitized repo metadata, remotes, notices review, referensi approval. Repo private tidak membuat lisensi GPL hilang.

### A03 / R03: Spotify
- Play lagu, background app, pause/resume, next/previous, seek jika supported, quit/relaunch.
- Title/artist dan posisi sesuai sumber. Tidak stale setelah pergantian lagu.
- Command hanya Spotify ketika Spotify dipilih meskipun browser bermain.
- Permission denied menampilkan alasan/recovery, bukan crash atau popup berulang.

### A04 / R04: Brave YouTube Music
- Ulangi kasus A03 pada music.youtube.com Brave, termasuk background tab/window dan reload tab.
- Ads/nonmusik/metadata kurang harus menampilkan state jujur.
- Browser dengan tab audio kedua tidak menerima command salah tanpa indikasi.
- Jika hanya global OS control tersedia, laporkan keterbatasan; manual pin tidak boleh berpura-pura terjamin.

### A05 / R05: Safari YouTube Music
- Semua kasus A04 pada Safari. Kelulusan Brave tidak diwariskan ke Safari.
- Extension Chromium tidak dihitung bukti Safari.
- Autoplay/browser permission yang memblokir playback dibedakan dari bug Gliese.

### A06 / R06: sumber dan clock
- Unit tests: auto sticky, manual unavailable, metadata-only event tidak mengubah pilihan, source stopped, dua playing, cold start tie-break.
- Command queue stale generation ditolak. Drag seek lalu track berubah tidak seek lagu baru memakai posisi lama.
- Fake clock untuk pause, seek mundur, rate, unknown duration dan sleep re-anchor.
- Live: Spotify+Brave, Spotify+Safari, Brave+Safari, tab YouTube Music duplikat dan browser restart. Verifikasi UI source dan target audio sebenarnya.

### A07 / R07: lyrics
- Parser: mm:ss.xx/xxx, duplicate/multiple timestamps, offset, BOM/CRLF, Unicode, malformed, empty, oversized dan nonfinite.
- Matcher: judul sama artis berbeda, live vs studio, remix, duration unknown, featured artists, ambiguous results.
- Network fake transport: success, plain, instrumental, 404, 429 Retry-After, timeout, invalid JSON, oversized, consent off, consent revoke dan stale response.
- Clock: pause/resume/seek, before first/after last line, manual offset dan reset. Target timeline internal <=0.3 detik di fixture terkontrol, bukan janji ketepatan lirik terhadap vokal.
- Live corpus disusun agent dari lagu yang Max pilih/izinkan: lagu Inggris dan Indonesia, satu versi live/remix, satu tanpa timed lyrics. Simpan hasil per lagu; jangan menetapkan persentase coverage API sebagai ukuran keberhasilan kode.
- Import .lrc lokal, cancel picker, invalid input dan wrong recording tidak merusak state. Uji request A-B-A: respons A pertama tidak boleh menimpa state A generasi terbaru.
- Offline/consent off tidak mengirim request; imported lyrics tetap bisa dipakai.

### A08 / R08: Shelf
- File dummy kecil, besar (tanpa membaca isi seluruhnya), Unicode/spasi, duplicate ref, missing file, symlink, removable volume.
- Drag-in, drag-out ke Finder dan aplikasi penerima, reveal, remove, clear, restart.
- Hash/existence file dummy sebelum/sesudah membuktikan remove/clear tidak menghapus atau mengubah original. Hash bukan untuk scanning file pribadi.
- Bookmark stale/permission denied memberi recoverable error.
- Drag default copy tidak memindahkan original karena negotiation keliru. Uji drag diterima dan dibatalkan, direktori serta izin file dicabut.

### A09 / R09: volume sistem
- Slider/mute sesuai perangkat, keyboard volume tercermin.
- Ganti output ketika panel terbuka; kontrol tidak lagi menulis ke device lama.
- Fixed-volume device menampilkan unsupported; tidak pura-pura slider bekerja.

### A10 / R10: volume aplikasi
- Dua aplikasi berbunyi; turunkan satu tanpa menurunkan yang lain.
- 0, intermediate, 100; mute/unmute kembali ke gain lama; perubahan cepat tidak click/jump berlebihan.
- 100% followSystem bypass bila didukung; jumlah engine kembali turun ketika tidak dibutuhkan.
- Unit tests gain clamp, mute state, generation, engine transaction failures.
- Uji audio nyata pada tingkat dengar rendah; jangan menaikkan master volume sebagai bagian tes otomatis. Pada fixture audio terkontrol ukur RMS relatif gain yang diminta, unity gain, dan mute dengan toleransi format yang dijelaskan. Fixture render saja tidak membuktikan original OS stream ikut mute; bukti runtime terpisah wajib.

### A11 / R11: output aplikasi
- Per output: DAC/IEM, TWS, Bluetooth speaker. Catat available channels/sample rate dan identitas nyata.
- Dua app ke output berbeda: DAC+speaker BT, DAC+TWS, TWS+speaker BT bila OS mendukung concurrent output.
- Uji Follow System versus explicit device; perubahan default tidak mengubah explicit route diam-diam.
- Brave/Safari multiprocess di-group benar; restart process tidak memindahkan app lain.
- Tidak ada duplicate playback ke default dan chosen output. Jangan menilai hanya dari dropdown yang berubah.
- Tidak menuntut dua perangkat Bluetooth sinkron sample-accurate. Catat latency dan drift yang terdengar/terukur.

### A12 / R12: audio failure dan cleanup
- Capture permission denied/revoked; tap create fail; IO start fail; perangkat hilang ketika gain aktif; sample-rate changes; route change berulang.
- Disconnect DAC/TWS saat routed: catat apakah audio bocor ke default, silent, atau pause. Jika fail-closed tidak terbukti, requirement privasi tidak boleh diklaim aman; keputusan risiko harus disetujui sebelum release.
- Sleep/wake, reconnect device, Bluetooth microphone/profile switch bila pengguna mengizinkan.
- Normal Quit dan crash probe: audio pulih/tidak macet, objek owned Gliese dibersihkan sesuai kemampuan OS, tidak ada orphan helper. Jangan mengklaim normal cleanup sama dengan SIGKILL.
- Enumerasi sebelum/sesudah memastikan aggregate milik pengguna tidak terhapus. Ulangi start/stop 20 kali untuk mendeteksi growth object/listener.
- Jangan mematikan Bluetooth seluruh mesin untuk mensimulasikan disconnect tanpa izin pengguna.

### A13 / R13: clipboard
- Mulai sebelum opt-in tidak capture. Start/resume tidak backfill clipboard lama.
- Text, link, image, unsupported type, confidential markers, ignore app hint, duplicate dan self-copy.
- Batas entries/bytes/decoded pixels termasuk semua pinned. Oversized ditolak tanpa UI freeze.
- Pause benar-benar berhenti membaca. Panel collapse mempertahankan history. Quit/relaunch mulai kosong; pin juga hilang.
- Clear menghapus data history namun tidak clipboard OS, dan tidak merekam ulang item yang sama tanpa changeCount baru.
- Audit file/log/network dengan sentinel dummy unik, ditambah positive-control fixture untuk memastikan scanner mampu mendeteksi kebocoran. Tidak menjalankan scanner terhadap konten clipboard pribadi.
- Tidak ada clipboard payload dalam autosave, serialized view state atau test screenshot pribadi. Akui batas OS swap/crash dumps.

### A14 / R14: system
- Battery charging/not charging/unknown; CPU first sample, delta normal, reset/wake; RAM page size dan unit; APFS volume mapping/storage unavailable.
- Bandingkan dengan API/tool OS dengan formula dan interval jelas. Activity Monitor snapshot berbeda tidak otomatis bug.
- Panel hidden/service off menghentikan timer yang tidak diperlukan. UI stale/unavailable jujur.
- Tidak ada sudo, folder scan, helper privileged atau shell polling loop.

### A15 / R15: notch interaction
- Hover default, switch ke click dan persist settings.
- Delay/hysteresis tidak berkedip di edge. Hover ke slider/output popover/drop target tidak collapse.
- Tidak merebut keyboard focus hanya karena mouse lewat.
- Musik, Shelf, Mixer, Clipboard, System reachable tanpa dead navigation; controls punya aksi nyata.

### A16 / R16: lifecycle dan accessibility
- Keyboard Tab/Enter/Escape, focus visible, VoiceOver labels/values, Reduce Motion.
- Long title, multiline lyric, empty state, permission/error/offline.
- Fullscreen Brave/Safari video, Spaces, Mission Control; presentasi/game hanya bila aplikasi tersedia dan pengguna mengizinkan. Unsupported test environment ditandai pending.
- Display disconnect/reconnect, scaling, notchless external display bila tersedia. Jangan tempatkan window pada layar yang hilang.
- Sleep/wake dan lock/unlock tidak menampilkan preview clipboard sensitif di lock screen. Sembunyikan konten saat session locked.

### A17 / R17: permissions dan privacy
- Inventory entitlements/usage descriptions, requested permissions, runtime outbound endpoints.
- Consent LRCLIB off: zero lyric requests. Updater/telemetry off. Clipboard/file/audio tidak dikirim ke jaringan.
- Audio permission hanya saat mixer diminta; penolakan tidak memblokir Shelf/System/Music yang tidak membutuhkan izin itu.
- No token/password/cookie logging, no launch-at-login default, no global Gatekeeper/SIP changes.
- Pure privacy tests memakai fake transport dan positive controls; runtime observasi memakai alat lokal yang diizinkan, bukan memasang root CA atau MITM akun pribadi.

### A18 / R18: performa dan resource

Protokol pengukuran, bukan hasil yang sudah ada:
1. Catat environment, build config dan workload. Tutup controller/mixer lain hanya setelah izin.
2. Baseline upstream dan Gliese diukur pada mesin/output/track/screen state yang sama, satu per satu.
3. Warm-up 60 detik, ukur 5 menit per skenario dengan sampel tiap 5 detik: idle panel closed, playback unity, lyrics visible, satu app attenuated, dua routes, clipboard bounded, System visible.
4. Catat CPU proses utama dan seluruh helpers, memory footprint/RSS dengan definisi, wakeups jika alat mendukung, audio discontinuity dan observed latency. RSS bukan otomatis physical footprint.
5. Ulangi start/stop, lagu berpindah dan route switch; cari tren memory/timer/object growth. Durasi pendek tidak membuktikan bebas leak selamanya.
6. Nyatakan tool dan keterbatasan. Jika tidak dapat mengukur latency end-to-end tanpa alat, tulis NOT_MEASURED, bukan 0 ms.

Budget kandidat untuk triage, bukan janji user: tambahan idle CPU rerata >1 percentage point terhadap upstream, tambahan steady memory >100 MiB, atau growth yang terus naik memerlukan investigasi/ADR. Angka ini bukan klaim hasil dan tidak membenarkan drop fitur otomatis. Audio glitches/wrong output tetap blocker meskipun CPU rendah.

### A19 / R19: build dan handoff
- Clean build pada pinned source/dependencies; full test suite yang relevan PASS; record skipped tests.
- Gliese.app benar-benar diluncurkan, semua bagian diklik/digunakan; compile-only tidak cukup.
- Inspect signature/entitlements sesuai development setup. Notarization tidak diklaim tanpa hasil Apple.
- Handoff: path app, source SHA/dirty state, command build/test, provenance, matriks di atas, README/privacy/troubleshooting/known issues dan cara uninstall Gliese saja.
- Remote GitHub verification hanya bila create/push diizinkan. Private repo atau DMG bukan alasan menghentikan verifikasi lokal yang sudah bisa dilakukan.

## 3. Evidence template

    Gate: Axx
    Requirement: Rxx
    Status: NOT_TESTED / PASS / FAIL / BLOCKED
    Build SHA dan dirty state:
    OS / app / browser / hardware:
    Preconditions dan izin:
    Steps:
    Expected:
    Observed:
    Command dan exit code (jika relevan):
    Evidence paths:
    Known limitations:
    Reviewer / rerun:

## 4. Release severity

Blocker: penghapusan/korupsi file asli, kebocoran clipboard/audio, wrong-app command, wrong-output routing tanpa penjelasan, volume jump berbahaya, audio macet setelah quit, crash umum, Safari/Brave target tidak bekerja.

Major: resource leak, consent/recovery salah, unsupported device terlihat supported, history bertahan di disk, interaction memblokir pekerjaan.

Minor: spacing, animasi kurang halus, icon development. Minor tetap dicatat; jangan menyebut branding final kalau belum disetujui.

Semua blocker/major harus diperbaiki atau ada perubahan scope/risk acceptance eksplisit Max. Tidak boleh menandai requirement PASS dengan alasan 'akan diperbaiki nanti'.
