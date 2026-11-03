# Inline lyrics UX

Approved by Max, 2026-11-03. Candidate implemented and installed; interactive UI acceptance pending. See ../evidence/lyrics-ux-2026-11-03.md.

## Design decisions

- ENERGY 1 / RHYTHM 1 / MOTION 2: a quiet notch player, with movement limited to reading lyrics.
- One inline lyric below the artist replaces the permanent right-hand card, freeing horizontal space.
- Fixed-height clipped text area prevents long text and transitions from overlapping controls.
- Crossfade and a small vertical shift take 220 ms. A new change replaces the prior transition rather than queuing it.
- Overflow scroll starts after the transition and a reading delay. Pause freezes it; Reduce Motion truncates text instead.
- Track changes and seek discontinuities reset the displayed line and scroll immediately.
- Full lyrics, local import, LRCLIB consent and timing offset remain available in a Lyrics popover.
- The current source icon opens Automatic/manual selection. Auto retains the existing sticky selection policy.
- No desktop card or lock-screen overlay. Max reported that the installed build was not visible on his lock screen; this is not a complete lock/unlock privacy test.

## Acceptance

See ../../GATES.md. Unit tests measure motion state and timeline behavior, not visual smoothness. Build success does not establish interactive UI acceptance.

## Documentation policy

Record changed files, reasons, executed commands and actual results in ../evidence/lyrics-ux-2026-11-03.md. Canonical status: /Users/jurymaxwell/Code/notch-mac/STATUS.md; mirror: STATUS.md.

Historical claim “19 gates PASS 100%” is withdrawn: the old AcceptanceVerifier wrote fixed PASS descriptions for checks it did not perform. Max's routing/disconnect test covers his reported case only, not the complete hardware matrix.
