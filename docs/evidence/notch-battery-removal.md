# Penghapusan indikator baterai header notch

2026-11-03. Max meminta indikator baterai di notch dihapus karena menduplikasi menu bar macOS.

- `boringNotch/components/Notch/BoringHeader.swift`: menghapus `BoringBatteryView` dan observer baterai dari header agar area kanan lebih lega.
- `boringNotch/components/Settings/SettingsView.swift`: menghapus toggle “Show battery indicator” agar tidak menawarkan kontrol yang tidak lagi berfungsi.
- `boringNotch/models/Constants.swift`: menghapus deklarasi key `showBatteryIndicator` yang tidak dipakai lagi. Preferensi pengguna tidak dihapus.

Scope perubahan adalah indikator permanen di header. Notifikasi perubahan daya dan metrik baterai di tab System masih merupakan fitur terpisah.

Verifikasi: build Debug Xcode exit 0 (`notch-battery-removal-build.log`); staged `codesign --verify --deep --strict` exit 0; SHA-256 executable build dan instalasi cocok (`notch-battery-removal-install.log`). Instalasi di `/Applications/Gliese.app`, backup `/Applications/Gliese-backup-20261103-100024.app`. Hash terbaru `76cf620ea5acaa72f0c5f680fe8b60c05412a4bfb59c8a802df24b0d3a8c8f5c` menggantikan kandidat tipografi sebelumnya. Tidak ada perubahan logika core; suite core tidak diulang untuk penghapusan view ini. Layout runtime perlu diamati pengguna.

Tidak ada commit atau push.
