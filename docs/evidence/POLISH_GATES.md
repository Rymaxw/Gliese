# Gates: Player polish

Scope: concise lyric status, track-change stale work protection, action button feedback, startup error investigation.

- [x] P1: Core regression suite passes
  CHECK: swift test -Xswiftc -plugin-path -Xswiftc /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing
  CWD: ../../GlieseCore
  EXPECT: /Test run with .* tests .* passed/
  EVIDENCE: automatic-evidence=v1; definition-sha256=3a23b8de9350dc434c6970b7312062d32d46eb7ee9e63279a8ebff80b093695f; exit=0; EXPECT=matched; output-sha256=78cb94be8d6da57594e7c5c55486ae3b6648a4fd3726160f3dee91d03f53739d; output-bytes=16162; shell=/bin/sh; cwd=/Users/jurymaxwell/Code/Gliese/GlieseCore; path=190c7bae4138/15 entries

- [x] P2: Integrated app builds
  CHECK: xcodebuild -quiet -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build && echo GLIESE_BUILD_SUCCEEDED
  CWD: ../..
  EXPECT: GLIESE_BUILD_SUCCEEDED
  EVIDENCE: automatic-evidence=v1; definition-sha256=d213d68fef79788d70c10c57448935c09c46f41444a5c640646a5c01a9cc4d9b; exit=0; EXPECT=matched; output-sha256=d85750c8d114e148c5630c26eb33061e3da582e980ea49abfedc4e2d461c951d; output-bytes=1326; shell=/bin/sh; cwd=/Users/jurymaxwell/Code/Gliese; path=190c7bae4138/15 entries

- [x] P3: Installed candidate and startup findings documented with actual evidence
  EVIDENCE: player-polish.md, player-polish-install.log, player-polish-build.log, player-polish-runtime-errors.log record code changes, build success, signature/hash match, running PID and remaining AppIntents/CoreUI errors.

- [ ] P4: Visual transitions and all changed interactions accepted
  EVIDENCE: Code and build reviewed; visual race/hover/focus/sharing acceptance not performed. User test steps in player-polish.md.

ABANDON: P4 Requires interactive user validation or Accessibility-enabled automation; not a passing gate.
