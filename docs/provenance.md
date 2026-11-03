# Provenance Source Gliese

Dibuat T00, 2026-11-02 WIB. Semua SHA di bawah adalah hasil `git rev-parse HEAD` pada checkout lokal aktual (bukan hanya snapshot riset).

## Checkout aktif

| Repositori | Commit | Tanggal | Lisensi | Lokasi lokal | Peran |
|---|---|---|---|---|---|
| TheBoredTeam/boring.notch | `b7611bbf32c627a3427408fc142486900d71a23f` | 2026-10-31 (merge PR #1727) | GPL-3.0-or-later (LICENSE bagian atas: "GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007") | `/Users/jurymaxwell/Code/Gliese` (remote `upstream`, checkout pinned, detached HEAD) | Basis shell aplikasi: notch window, media surface, shelf, volume, settings |
| vorssaint/vorssaint-utils | `a5da7633e09d0ebbf5b5607c0434ded28a239469` | (rev-parse cocok snapshot riset) | GPL-3.0-or-later (`Package.swift` header: SPDX GPL-3.0-or-later) | `/Users/jurymaxwell/Code/notch-mac-reference/vorssaint-utils` | Referensi terarah: engine lyrics/mixer/clipboard/metrics. Tidak di-vendor utuh. |
| ungive/mediaremote-adapter | `0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd` | (rev-parse cocok snapshot riset) | BSD-3-Clause (LICENSE) | `/Users/jurymaxwell/Code/notch-mac-reference/mediaremote-adapter` | Referensi adapter Now Playing; bisa dibangun sendiri bila framework vendored perlu di-regenerate |

## Copy prebuilt yang dibawa upstream

`boring.notch` membawa `mediaremote-adapter/mediaremote-adapter.pl` (BSD 3-Clause, header "Copyright (c) 2025 Jonas van den Berg") + `MediaRemoteAdapter.framework` (binary prebuilt) + `MediaRemoteAdapterTestClient`. Status: diperlakukan sebagai artefact dari proyek mediaremote-adapter; kesesuaian biner dengan source adapter pada SHA di atas belum diverifikasi byte-ke-byte (menunggu regenerasi CMake bila dibutuhkan; dicek di T05).

## Dependency SPM upstream (yang mengikut ketika memakai xcodeproj)

lottie-spm, swift-collections, AsyncXPCConnection, Pow, SkyLightWindow, Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, swiftui-intospect, Sparkle, MacroVisionKit. Pin versi ada di `project.pbxproj` (`XCRemoteSwiftPackageReference` + `XCVersionRequirement`). Versi actual dikunci oleh `Package.resolved` saat build pertama.

## Kebijakan

- Repo Gliese akan menjadi repo private mandiri (NOT_YET_CREATED, menunggu izin + `gh`); `upstream` tetap menunjuk TheBoredTeam/boring.notch. Bukan fork; lisensi GPL-3.0 dan attribution dipertahankan saat kode upstream diadaptasi.
- `docs/planning/` menyimpan salinan paket perencanaan dengan catatan lokasi kanonis (`/Users/jurymaxwell/Code/notch-mac/`).

## Adaptasi kode (log, diisi saat mulai)

Belum ada adaptasi. Belum ada penyuntingan file upstream selain menambah folder docs/ (untracked).
