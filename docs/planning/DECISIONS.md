# Gliese: Keputusan dan Batas Asumsi

Induk: [PLAN.md](PLAN.md).

## Dikonfirmasi Max

- Nama Gliese.
- Spotify desktop dan YouTube Music di Brave serta Safari.
- Lyrics, Shelf, volume sistem, clipboard, monitoring baterai/CPU/RAM/storage.
- Mixer seperti Windows: volume/mute dan pemilihan output per aplikasi, tanpa boost.
- Perangkat audio: IEM lewat DAC, TWS, speaker Bluetooth.
- Clipboard history hanya selama aplikasi berjalan; hilang ketika Quit.
- Hover default dan opsi click.
- Arah tampilan boring.notch; repo private dahulu.
- Agent lain melaksanakan implementasi. Sesi ini membuat plan detail, bukan membuat aplikasi.
- Setiap push memerlukan izin Max dan teks commit harus diminta dari Max.

## Keputusan arsitektur yang direkomendasikan

- Basis boring.notch dengan reuse selektif source Vorssaint; bukan reverse engineering binary.
- Repo private mandiri karena fork GitHub public tidak dapat dijadikan private secara individual.
- Identitas usulan com.rymaxw.gliese. Helper mengikuti identitas baru yang konsisten.
- Tidak ada backend, telemetry, automatic updater, driver audio eksternal atau service privileged.
- Tahap feasibility media dan mixer mendahului polish; semua fitur tetap target rilis pertama.
- Data flow, acceptance dan ownership ada di dokumen terkait.

## Default teknis yang boleh dituning dengan evidence

| Area | Default | Alasan |
|---|---|---|
| Source picker | Auto + pilihan Spotify/Brave/Safari yang tersedia | command harus jelas targetnya |
| Source auto | sticky pada sumber playing; tidak auto-pause sumber lain | tidak mengganggu playback pengguna |
| Shelf | reference-only; persist refs; remove tidak delete original | file staging, bukan backup |
| Clipboard | opt-in, 50 entries, 32 MiB total, 5 MiB image, 1 MiB text | bounded resource dan privacy |
| Clipboard pin | hanya sesi, tetap tunduk batas memori | sesuai quit-to-clear |
| Clipboard action | copy, bukan auto-paste | tanpa izin tambahan yang tidak perlu |
| Mixer prefs | gain/route hanya sesi pada rilis pertama | menghindari routing tak terduga saat startup |
| Route disconnect | jangan fallback diam-diam; verifikasi safety nyata | mencegah audio privat keluar speaker |
| Lyrics | consent off awal; API cache terbatas; .lrc lokal | metadata disclosure transparan |
| Hover | buka 180 ms, tutup 350 ms | mencegah flicker; tuning lewat uji |
| Metrics | CPU/RAM 2 detik saat panel tampak; storage 60 detik | menekan polling |
| Startup | launch at login off | tidak mengubah perilaku sistem otomatis |
| UI language | English mengikuti upstream | fokus fitur, bukan scope lokalisasi baru |
| Packaging | .app lokal; DMG opsional | bukti working build lebih penting |

Default ini bukan klaim bahwa Max memilih setiap angka. Agent boleh menyesuaikan parameter tanpa bertanya berulang bila tidak mengubah privacy, feature scope, platform atau risk exposure. Catat alasan dan hasil pengujian. Perubahan tersebut harus konsisten lintas PLAN, ARCHITECTURE dan ACCEPTANCE.

## Pertanyaan bersyarat, bukan blocker plan

- Jika browser backend tidak memenuhi kontrol target: persetujuan extension/izin baru atau keputusan scope, bukan fallback diam-diam.
- Jika routing gagal menjaga audio saat disconnect/crash: penjelasan hasil nyata dan keputusan risk acceptance Max.
- Jika target hardware tidak tersedia: minta Max menghubungkan perangkat untuk acceptance; jangan mengarang hasil.
- Jika full Xcode/signing/permission diperlukan: minta tindakan terkait, bukan seluruh akses mesin.
- Jika perlu ikon/logo final: minta persetujuan aset. Placeholder development harus jujur.
- Jika perlu persistensi mixer atau clipboard disk: keputusan baru, tidak aktif secara default.

## Klaim yang dilarang sebelum pengujian

- Semua browser/perangkat pasti didukung.
- Mixer nol latensi atau pasti ringan.
- Clipboard memory-only berarti tidak mungkin masuk swap/crash dump OS.
- Audio pasti tetap mute saat aplikasi crash.
- Semua lagu punya synced lyrics.
- Build unsigned pasti memiliki perilaku TCC/helper sama dengan build signed.
- Repo private menghapus kewajiban lisensi.

## Riwayat keputusan

2026-11-02: nama, sumber, fitur, arah tampilan dan private ditetapkan. System dibatasi monitoring. Mixer diperluas menjadi routing per aplikasi; boost ditolak. Clipboard sesi dan hover/click dikunci. Perangkat DAC/IEM, TWS dan speaker Bluetooth dikonfirmasi. Paket handoff detail disusun; belum implementasi.
