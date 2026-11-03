# Gliese: Rencana Implementasi Kanonis

Revisi: 1.0, 2026-11-02 WIB.
Pemilik: Max / Jury Maxwell / Rymaxw.
Status: spesifikasi dan handoff, bukan aplikasi yang sudah dibangun.
Bahasa dokumentasi: Indonesia. Identifier kode tetap bahasa Inggris.

## 0. Mulai di sini

Paket ini ditujukan kepada agent coding berikutnya. Jangan menebak kebutuhan dari nama proyek atau membawa semua fitur upstream.

Urutan baca:
1. Dokumen ini: kebutuhan, batas pekerjaan, urutan implementasi.
2. [ARCHITECTURE.md](ARCHITECTURE.md): kontrak data, lifecycle, algoritma dan kebijakan privasi.
3. [ACCEPTANCE.md](ACCEPTANCE.md): matriks pengujian dan definisi selesai.
4. [EXECUTION.md](EXECUTION.md): langkah praktis, toolchain, repository, resume dan format laporan.
5. [DECISIONS.md](DECISIONS.md): keputusan terkunci, default yang dapat disetel, pertanyaan bersyarat.

Hasil review independen dan tindak lanjut ada di [REVIEW.md](REVIEW.md).

Status pekerjaan ada di [STATUS.md](STATUS.md). Jangan mengubah status menjadi lulus hanya karena file source sudah ada. [PLANNING_GATES.md](PLANNING_GATES.md) mengaudit paket dokumen ini, bukan membuktikan aplikasi bekerja.

### Aturan paling penting

- Pertahankan fitur wajib. Fitur yang gagal dibuktikan harus dilaporkan sebagai blocker atau membutuhkan persetujuan perubahan cakupan, bukan dihapus diam-diam.
- Buktikan integrasi Spotify, Brave, Safari dan routing mixer sebelum polish visual.
- Jangan gunakan data demo sebagai pengganti hasil pengujian nyata. Fixture boleh untuk unit test dan harus dilabeli sebagai fixture.
- Tidak push tanpa izin Max untuk setiap push. Minta teks commit persis dari Max sebelum commit.
- Repo private terpisah, bukan fork GitHub public. Tidak membuat repo atau aplikasi selama tahap penyusunan rencana ini.

## 1. Produk yang dibangun

Gliese adalah aplikasi notch native macOS untuk aktivitas harian Max: musik dan lirik, file sementara, mixer audio per aplikasi, clipboard sementara, serta monitoring sistem sederhana. Referensi tampilan dan basis implementasi adalah boring.notch.

Pengguna dan lingkungan utama:
- Max, Mac Apple Silicon. Snapshot lingkungan sebelumnya menyebut M2 dan macOS 27.2; verifikasi lagi saat implementasi.
- Spotify desktop.
- YouTube Music pada music.youtube.com di Brave dan Safari. Keduanya merupakan target, bukan alternatif yang boleh dipilih salah satu.
- Audio: IEM melalui DAC, TWS, speaker Bluetooth. Model dan interface DAC dicatat saat perangkat tersambung.
- Penggunaan pribadi, repo private dahulu. Distribusi publik dan Mac App Store tidak menjadi target rilis ini.

Bukan tujuan: membuat replika seluruh Vorssaint, platform plugin, atau aplikasi utility serbaguna.

## 2. Daftar kebutuhan dengan ID stabil

Label K = keputusan eksplisit Max; D = default implementasi yang direkomendasikan; V = kemampuan yang masih harus diverifikasi. ID digunakan di task, test, dan laporan.

| ID | Kebutuhan | Kategori | Pemilik implementasi | Gate |
|---|---|---|---|---|
| R01 | Nama Gliese; identitas aplikasi dan data terpisah dari upstream | K/D | Integrator | A01 |
| R02 | Repo private mandiri; lisensi/attribution dipertahankan; commit/push sesuai izin | K/D | Integrator | A02 |
| R03 | Metadata dan kontrol Spotify desktop | K/V | Media | A03 |
| R04 | Metadata dan kontrol YouTube Music Brave | K/V | Media | A04 |
| R05 | Metadata dan kontrol YouTube Music Safari | K/V | Media | A05 |
| R06 | Pemilihan sumber deterministik; perintah tidak mengenai sumber yang salah | D/V | Media | A06 |
| R07 | Lirik tersinkronisasi, fallback jelas, tidak membawa lirik lagu lama | K/V | Lyrics | A07 |
| R08 | Shelf file sementara, drag-in/out, tidak menghapus file asli | K/D | Shelf | A08 |
| R09 | Volume output sistem dan mute | K/V | Audio | A09 |
| R10 | Volume 0 sampai 100% dan mute per aplikasi, tanpa boost | K/V | Audio | A10 |
| R11 | Pemilihan output per aplikasi: DAC/IEM, TWS, speaker Bluetooth yang tersedia | K/V | Audio | A11 |
| R12 | Cleanup dan recovery audio pada disconnect, izin ditolak, sleep, quit/crash | D/V | Audio | A12 |
| R13 | History clipboard teks/link/gambar selama sesi; tidak persisten setelah Quit | K/D | Clipboard | A13 |
| R14 | Monitoring baterai, CPU, RAM, storage saja | K/V | System | A14 |
| R15 | Arah boring.notch, hover default dengan opsi click | K | UI | A15 |
| R16 | Fokus, keyboard, VoiceOver, Reduce Motion, fullscreen dan display lifecycle | D/V | UI | A16 |
| R17 | Permission minimum, data lokal, consent jaringan dan perlindungan data sensitif | D | Semua | A17 |
| R18 | Performa diukur beserta helper, tanpa kebocoran resource | D/V | Integrator | A18 |
| R19 | Gliese.app dapat dibangun dan dijalankan; handoff dapat direproduksi | D/V | Integrator | A19 |

Playback mencakup play/pause, next/previous, title/artist dan progress. Seek/artwork ditampilkan bila data/capability tersedia; unavailable harus eksplisit. Browser yang hanya menampilkan metadata tanpa kontrol yang tepat belum dianggap memenuhi kebutuhan musik.

## 3. Basis source dan temuan

Gunakan source inspection lebih dahulu. Vorssaint dan boring.notch open source, sehingga REA binary bukan prasyarat atau tugas implementasi.

Snapshot HEAD yang diambil saat penyusunan revisi ini:

| Sumber | SHA yang diamati | Peran |
|---|---|---|
| TheBoredTeam/boring.notch | b7611bbf32c627a3427408fc142486900d71a23f | kandidat baseline shell/media/Shelf/volume |
| vorssaint/vorssaint-utils | a5da7633e09d0ebbf5b5607c0434ded28a239469 | referensi terarah lyrics/mixer/clipboard/metrics |
| ungive/mediaremote-adapter | 0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd | referensi adapter Now Playing |

SHA di atas terverifikasi dari GitHub API, bukan hasil build. Checkout/pin yang benar-benar dipakai wajib dicatat; versi adapter yang dikunci boring.notch lebih diprioritaskan daripada otomatis mengambil HEAD terbaru. Jangan update dependency hanya agar terlihat terbaru.

Fakta dan batas bukti:
- boringnotch.com menautkan repo TheBoredTeam/boring.notch.
- Source Vorssaint AppVolumeMixer menggunakan CoreAudio process taps dan aggregate device. Itu bukan bukti semua hardware Max bekerja, dan bukan janji overhead rendah.
- Controller bernama YouTubeMusicController pada boring.notch memiliki HTTP API/identitas aplikasi tertentu. Jangan menganggap controller itu untuk tab YouTube Music di Brave/Safari.
- Adapter MediaRemote merupakan titik risiko API private. Simbol binary atau komentar source bukan bukti runtime berhasil.
- LRCLIB pernah mengembalikan syncedLyrics untuk satu query lagu pada riset awal. Tidak ada jaminan coverage seluruh lagu, terutama live/remix.
- Nusa tetap referensi awal; repo publik yang diperiksa hanya landing page. Tidak perlu download/unpack installer Windows untuk proyek ini.
- Jangan menjadikan dugaan consent lyrics Vorssaint sebagai diagnosis pasti masalah aplikasi Max.

### Strategi reuse

Pertahankan shell boring.notch dan bagian yang terbukti berguna. Port algoritma atau engine Vorssaint secara selektif beserta dependensi yang benar-benar dibutuhkan. Jangan menyalin monolit NotchService atau AppVolumeMixer lalu mematikan puluhan fitur dengan flag tanpa memahami lifecycle.

Reuse bukan berarti rewrite total. Bungkus kode yang stabil dengan interface kecil dan tests; hanya ekstrak bagian yang diperlukan. Bila engine mixer ternyata terlalu terikat ke toolkit lain, tulis ADR berisi dependency map dan opsi sebelum menambah scope besar.

## 4. Batas rilis pertama

Wajib:
- Music + Lyrics.
- Shelf.
- Volume sistem + mixer per aplikasi + output routing.
- Clipboard memory-only.
- System monitoring.
- Settings, permission flow, serta lifecycle notch.

Dikeluarkan:
- Boost, equalizer, satu aplikasi ke banyak output sekaligus, kontrol tiap tab browser.
- Fan control, temperature helper privileged, cleaner, process killer, window management.
- Cloud clipboard, akun Gliese, telemetry, backend server, langganan.
- Calendar, Pomodoro, water reminder, to-do, mascot, AI agent monitoring.
- AirPlay/per-app network routing khusus, driver audio pihak ketiga, kernel extension.
- Distribusi publik, automatic updates, Apple Music sebagai target acceptance wajib.

Kode fitur upstream yang tidak dipakai boleh tetap sementara jika penghapusannya berisiko, tetapi harus tidak aktif, tidak meminta izin, tidak menjalankan service, dan tidak muncul sebagai fitur Gliese. Buat inventarisnya dan hapus bertahap setelah baseline aman.

## 5. Default UX untuk implementasi

Detail ini keputusan perancang plan, bukan permintaan eksplisit tambahan Max. Boleh disetel lewat uji tanpa mengubah scope.

- Notch collapsed menampilkan status musik singkat; expanded memiliki Music, Shelf, Clipboard, System. Mixer dapat dibuka dari kontrol volume dan tetap tersedia tanpa musik aktif.
- Default hover dengan delay buka 180 ms dan tutup 350 ms sebagai titik awal. Pointer yang masuk slider, menu output, popover atau drag session tidak menutup panel. Nilai dituning, tidak dijadikan benchmark pasti.
- Mode click mengabaikan pointer hover untuk membuka, tetapi drag-in Shelf boleh menampilkan drop target.
- Escape menutup popover terlebih dahulu lalu panel. Jangan merebut fokus aplikasi lain ketika hover. Search clipboard baru meminta fokus saat field diklik.
- Bahasa UI awal English mengikuti upstream untuk mengurangi scope lokalisasi; dokumentasi handoff Indonesia. Label sederhana dan tidak marketing.
- Audio route dan permission status terlihat jelas. Kontrol yang tidak tersedia dinonaktifkan dengan alasan, bukan tombol palsu.
- Shelf menyimpan referensi, bukan salinan file. Referensi dipertahankan antarsesi sebagai default dan bisa clear all. History clipboard berbeda: hanya sesi.
- Clipboard text/link/image, search, copy, delete, pin selama sesi. Tidak auto-paste. Menutup panel bukan menghapus history.
- Online lyric lookup off sampai consent. Local import .lrc tersedia saat online tidak diizinkan.
- Launch at login off sampai pengguna mengaktifkan. Updater upstream off. Tidak ada download otomatis aplikasi lain.
- Design direction: notch ringkas seperti boring.notch. Jangan mengarang tema galaksi karena nama Gliese. Ikon final/branding visual perlu persetujuan tersendiri; tidak menjadi alasan menunda spike teknis.

Saat membuat UI nyata, lakukan Design Read dari referensi yang ditampilkan, tetapkan spacing/type/motion secara sadar, baca aturan antislop setempat, dan verifikasi state kosong/loading/error/accessibility. Dokumen ini tidak mengklaim visual sudah diaudit melalui screenshot.

## 6. Urutan pekerjaan dan dependency graph

Alur utama: T00 -> T01 -> T02 -> (T03 dan T04 secara serial untuk tes audio) -> T05 -> T06/T07/T08/T09 -> T10 -> T11.

Tabel berikut merupakan kontrak pekerjaan. Status awal semua NOT_STARTED. Jangan menjalankan dua pengujian yang mengubah output audio atau clipboard sistem bersamaan.

### T00: orientasi, izin, dan pencatatan

Input: paket ini dan instruksi Max untuk mulai implementasi.
Langkah:
1. Baca instruction files proyek, git status, STATUS, lalu dokumen paket.
2. Periksa Mac/toolchain aktual, kapasitas, browser/Spotify terpasang, serta izin yang tersedia.
3. Tentukan source checkout; jangan menimpa folder PLAN saat clone.
4. Buat baseline environment/provenance dan daftar approval yang dibutuhkan.
Output: docs/evidence/environment.md, docs/provenance.md, STATUS yang diperbarui.
Gate keluar: rute build diketahui atau blocker toolchain dijelaskan; belum install besar otomatis.
Stop: credential/Xcode/izin yang memerlukan manusia tidak tersedia.

### T01: checkout dan baseline build

Depends: T00.
Langkah:
1. Clone boring.notch ke direktori source terpisah; baca LICENSE, CONTRIBUTING, submodule, workflows, updater.
2. Pin baseline; catat scheme/target asli dari xcodebuild, jangan menebak namanya.
3. Build ke DerivedData lokal dengan konfigurasi yang cocok. Simpan exit code, log dan lokasi bundle.
4. Baseline T01 bersifat compile-only. Jangan meluncurkan bundle dengan identitas upstream pada akun utama. Runtime baseline dilakukan setelah T02 memberi identitas development terpisah, atau pada akun uji terisolasi dengan izin. Catat perubahan identitas dalam perbandingan performa.
Output: provenance SHA, log baseline, dependency map awal, artefak baseline.
Gate: build nyata; jika signing menghambat, pisahkan compile evidence dan launch evidence.
Stop: upstream tidak membangun pada environment aktual. Diagnosis sebelum menambahkan fitur.

### T02: identitas development dan test harness

Depends: T01.
Langkah:
1. Buat development identity Gliese terpisah untuk main app/helper/TCC/defaults/storage.
2. Disable updater, release workflows, login startup dan service tidak relevan.
3. Tambahkan test target untuk logika murni dan fake clock/provider. Simpan harness minimal yang dapat menguji feature baru.
4. Tangani repo private sesuai EXECUTION. Tidak perlu push untuk lanjut lokal.
Output: app development terisolasi, test harness bekerja, daftar perubahan identitas.
Gate: A01 dan lokal A02; tidak mengubah prefs aplikasi resmi.

### T03: spike media browser dan Spotify

Depends: T02.
Pertanyaan: apakah provider dapat membaca serta mengontrol sumber yang benar, termasuk ketika sumber lain hidup?
Langkah:
1. Buktikan Spotify, Brave YTM, Safari YTM secara terpisah.
2. Uji background tab, pause/resume, seek, source change, serta dua sumber simultan.
3. Catat field tersedia, latency observasi, capability, identitas browser/tab dan target command.
4. Uji helper crash/restart dan stale metadata dengan konten non-sensitif.
Output: docs/spikes/media.md, matriks A03-A06, minimal probe dengan cara menjalankannya.
Gate: VALIDATED, PARTIAL atau INVALIDATED dengan bukti. Metadata-only bukan lulus kontrol.
Stop: source targeting salah atau hanya global. Tentukan alternatif dengan Max; extension baru membutuhkan izin dan implementasi browser-specific, khususnya Safari. Jangan mengorbankan Safari diam-diam.

### T04: spike mixer gain dan routing hardware

Depends: T02; live testing serial terhadap T03.
Pertanyaan: dapatkah audio tiap app diturunkan/di-mute dan dialihkan ke output pilihannya tanpa duplikasi/silence permanen?
Langkah:
1. Baca engine Vorssaint dan buat dependency map serta test minimal; jangan menjalankan dua mixer sekaligus.
2. Dengan izin capture, uji unity bypass, gain, mute, dan satu route eksplisit.
3. Uji dua aplikasi ke dua output berbeda pada perangkat yang benar-benar tersambung.
4. Uji disconnect/reconnect, permission denied, sleep/wake, stop engine, normal quit dan crash.
5. Ukur overhead terhadap baseline; catat keterbatasan device/OS.
Output: docs/spikes/audio.md, device matrix, risk assessment dan hasil cleanup.
Gate: A09-A12 pada konfigurasi tersedia, blocker hardware ditandai NOT_TESTED.
Stop: wrong-output audio, feedback/duplicate audio, volume melonjak, render callback tidak stabil atau audio macet. Perbaiki sebelum menghubungkan engine ke UI final.

### T05: kontrak integrasi dikunci

Depends: T03 dan T04 beserta keputusan atas keterbatasannya.
Langkah: petakan interface ARCHITECTURE ke source asli, tetapkan module ownership, strategi signing/helper, izin, storage dan tests; tulis ADR untuk keputusan yang berbeda dari rekomendasi plan.
Output: docs/architecture-map.md dengan path aktual, kontrak provider/audio, daftar capability yang dibuktikan.
Gate: tidak ada klaim critical path yang masih bersandar pada nama file atau komentar upstream.

### T06: Music + Lyrics produksi

Depends: T05.
Implementasi: provider lifecycle, source coordinator, progress clock, controls, consent, LRCLIB client/matcher/cache, parser, offset, local import, status lyrics dan UI.
TDD: satu perilaku per siklus RED-GREEN-REFACTOR; unit tests memakai clock/network fixture, bukan layanan live.
Gate: A03-A07, bagian A17. Test live tidak menggantikan unit test dan sebaliknya.

### T07: audio produksi dan mixer UI

Depends: T05.
Implementasi: device registry, app grouping, per-app gains/routes, state machine, cleanup/recovery, permission flow dan output picker.
Gate: A09-A12 dan integrasi dengan media/lyrics. Audit bahwa routed audio tidak membuat Now Playing mengidentifikasi Gliese sebagai lagu baru dan tidak menciptakan loop.

### T08: Shelf dan clipboard

Depends: T05; pure tests dapat paralel dengan T06/T07.
Implementasi: file references, drag/drop/reveal, missing file, clipboard bounded memory, opt-in/pause/exclusions/pin/search/copy/clear dan quit policy.
Gate: A08, A13, bagian A17. Live clipboard tests hanya memakai dummy dan tidak menyalin clipboard pribadi ke evidence.

### T09: system monitoring dan settings

Depends: T05.
Implementasi: battery/CPU/memory/storage read-only, sampling visibility, settings schema, hover/click preference, launch setting opt-in.
Gate: A14-A15; service off benar-benar menghentikan timer/subscription.

### T10: integrasi UI, hardening dan regression

Depends: T06-T09.
Implementasi: seluruh navigasi notch, Escape/focus, keyboard/VoiceOver, fullscreen, display changes, sleep/wake, permission denial, offline dan bounded resources.
Gate: A01-A18 yang relevan. Jalankan baseline perbandingan tanpa mixer lain aktif.
Stop: konten clipboard bocor, file asli hilang, wrong-app command, wrong-output audio atau crash. Ini bukan polish opsional.

### T11: paket lokal dan handoff

Depends: T10.
Output: Gliese.app nyata, instruksi build/run, test summary, evidence, known limitations, attribution, privacy note, troubleshooting, uninstall/rollback. DMG opsional.
Gate: A19 dan semua gate wajib. NOT_TESTED/BLOCKED tidak dihitung lulus.
Tidak publish, push, atau notarize menggunakan identitas yang belum diizinkan. Jika hardware unavailable, serahkan candidate build dengan daftar test pending, bukan klaim rilis selesai.

## 7. Pembagian agent dan ownership

Satu integrator memegang project.pbxproj, target/helper config, Info.plist, entitlements, app lifecycle, dependency lock, shared models, settings schema dan navigasi global. Worker lain tidak menyunting file tersebut bersamaan.

Worker Media/Lyrics: module Media, Lyrics dan tests-nya.
Worker Audio: module Audio dan tests-nya.
Worker Shelf/Clipboard: kedua module beserta tests.
Worker System: module System dan tests.
Reviewer: baca diff/evidence; tidak menandai pekerjaan lengkap hanya dari ringkasan worker.

Path modul pada ARCHITECTURE bersifat usulan; map ke source asli dahulu. Maksimal satu worker menjalankan test live audio/browser/session pada satu Mac. Test logika murni boleh paralel. Build berat dibatasi sesuai RAM aktual.

Parent/integrator mengulang tests penting dan integrasi, bukan menerima klaim worker tanpa artefak. Jangan commit otomatis sebagai bagian akhir task worker. Jika tugas dilanjutkan agent lain, STATUS menyimpan command terakhir, hasil, file ownership dan next action.

## 8. Definisi selesai

Selesai implementasi berarti semua requirement R01-R19 memenuhi gate masing-masing dengan evidence aktual dan tidak ada data-loss/privacy/audio-routing defect terbuka. Kompatibilitas hardware yang belum diuji tetap dinyatakan belum diuji.

Selesai dokumen berarti kebutuhan, defaults, kontrak, urutan, tests dan handoff jelas. Dokumen selesai TIDAK berarti aplikasinya selesai.

## 9. Referensi

- https://boringnotch.com/
- https://github.com/TheBoredTeam/boring.notch
- https://github.com/vorssaint/vorssaint-utils
- https://github.com/ungive/mediaremote-adapter
- https://lrclib.net/docs
- https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/about-permissions-and-visibility-of-forks

Setiap source/PR yang diadopsi dicatat pada SHA aktual beserta lisensi, perubahan lokal dan test terkait. Tidak ada keharusan mengadopsi PR tertentu yang disebut percakapan lama.
