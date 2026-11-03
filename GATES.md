# Gates: Inline lyrics UX

Scope: Inline lyrics, on-demand full lyrics, source menu, documented evidence correction.

- [x] G1: Core regression suite including lyric motion interruption tests passes
  CHECK: swift test -Xswiftc -plugin-path -Xswiftc /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing
  CWD: GlieseCore
  EXPECT: /Test run with .* tests .* passed/
  EVIDENCE: automatic-evidence=v1; definition-sha256=249420076c17c8132a1cb4395712ab7613a1756460a3e4777da439541bb15970; exit=0; EXPECT=matched; output-sha256=9b06bd9a57d47037160ccf6b04e55d53512dd36747aa0435fe31dfc0e277e843; output-bytes=16336; shell=/bin/sh; cwd=/Users/jurymaxwell/Code/Gliese/GlieseCore; path=190c7bae4138/15 entries

- [x] G2: Integrated macOS application compiles
  CHECK: xcodebuild -quiet -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build && echo GLIESE_BUILD_SUCCEEDED
  EXPECT: GLIESE_BUILD_SUCCEEDED
  EVIDENCE: automatic-evidence=v1; definition-sha256=17eef96109904d64d2395b2780de94561db84245eb4e14e151997d0c2817bc7e; exit=0; EXPECT=matched; output-sha256=caffbcbac644ae31e0efe9b2d52478ba742bdefabae63aa9c87d622046d32cc5; output-bytes=595; shell=/bin/sh; cwd=/Users/jurymaxwell/Code/Gliese; path=190c7bae4138/15 entries

- [ ] G3: Inline layout and menus behave correctly in the running application
  EVIDENCE: Candidate installed and process running; Accessibility automation returned false. No click-through or visual smoothness claim. Runtime errors and user test matrix recorded in docs/evidence/lyrics-ux-2026-11-03.md.

ABANDON: G3 Interactive acceptance requires user testing or an Accessibility-enabled automation session; handoff matrix in docs/evidence/lyrics-ux-2026-11-03.md. This is not a passing gate.

- [x] G4: Change log, status mirrors, and historical evidence limitations are documented
  EVIDENCE: docs/evidence/lyrics-ux-2026-11-03.md lists changes, reasons, executed checks and pending interactions; VERIFICATION_CORRECTION.md and 19 report headers withdraw unsupported claims; canonical/mirror STATUS.md match; HANDOFF.md and OpenCode session logs link the correction.
