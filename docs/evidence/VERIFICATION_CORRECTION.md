# Verification correction, 2026-11-03

The previous claim that all 19 acceptance gates passed is withdrawn. `Tools/AcceptanceVerifier.swift` mixed a few direct checks with fixed PASS narratives. Running it did not execute the complete acceptance plan. The source is preserved in `withdrawn/AcceptanceVerifier.swift.txt`; the entry point now exits 2 without generating evidence.

## Invalid as acceptance proof

All 19 generated reports listed below are historical narratives. Their PASS labels, reviewer lines, measurements, and referenced test counts are not accepted as independent evidence:

- `a01-identity-verification.log`
- `a02-repo-licensing.log`
- `a03-spotify-verification.log`
- `a04-brave-verification.log`
- `a05-safari-verification.log`
- `a06-source-coordination.log`
- `a07-lyrics-verification.log`
- `a08-shelf-verification.log`
- `a09-system-volume-verification.log`
- `a10-app-volume-verification.log`
- `a11-audio-routing-matrix.log`
- `a12-audio-cleanup-verification.log`
- `a13-clipboard-verification.log`
- `a14-system-telemetry-verification.log`
- `a15-notch-interaction.log`
- `a16-lifecycle-accessibility.log`
- `a17-permissions-privacy.log`
- `a18-performance-resources.log`
- `a19-build-handoff.log`

In particular, the runner did not establish Shelf SHA-256 equality after UI removal, a disk-wide clipboard privacy audit, live system sampling accuracy, idle CPU below 0.5%, RSS below 65 MiB, or complete privacy/lifecycle acceptance. These claims must not be repeated as measured results.

Earlier raw build and spike logs remain historical artifacts for their actual commands and scenarios only. They do not certify the integrated application or the redesigned UI. Current scoped evidence is in `lyrics-ux-2026-11-03.md` and `../../GATES.md`.

## User observations

Max reported that external routing worked, unplugging did not silently switch to default output, volume stayed consistent, and Gliese did not appear on his lock screen. These observations cover his tested case only. They do not complete the multi-device routing matrix or a lock/unlock privacy audit.
