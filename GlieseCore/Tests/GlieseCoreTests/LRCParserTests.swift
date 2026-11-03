// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import GlieseCore

@Suite("LRC parser")
struct LRCParserTests {
    private func lines(_ input: String) throws -> LRCFile {
        guard case .timed(let file) = try LRCParser.parse(Data(input.utf8)) else {
            Issue.record("expected timed outcome")
            return LRCFile(lines: [], metadata: [:], unknownTags: [], offsetTagMilliseconds: nil)
        }
        return file
    }

    @Test("format variants mm:ss, mm:ss.xx, mm:ss.xxx")
    func formatVariants() throws {
        let file = try lines("""
        [00:12]one
        [01:02.34]two
        [02:03.456]three
        """)
        #expect(file.lines.map(\.timestampSeconds) == [12, 62.34, 123.456])
        #expect(file.lines.map(\.text) == ["one", "two", "three"])
    }

    @Test("single-digit parts tolerated")
    func singleDigit() throws {
        let file = try lines("[1:5]x")
        #expect(file.lines.first?.timestampSeconds == 65)
    }

    @Test("multiple timestamps on one line")
    func multiTimestamps() throws {
        let file = try lines("[00:10.00][01:30.00]chorus")
        #expect(file.lines.map(\.timestampSeconds) == [10, 90])
        #expect(file.lines.allSatisfy { $0.text == "chorus" })
    }

    @Test("duplicate timestamps preserve file order")
    func duplicates() throws {
        let file = try lines("""
        [00:05]first
        [00:05]second
        [00:05]third
        """)
        #expect(file.lines.map(\.text) == ["first", "second", "third"])
        #expect(file.lines.map(\.stableOrdinal) == [0, 1, 2])
    }

    @Test("stable sort ascending regardless of file order")
    func sorting() throws {
        let file = try lines("""
        [00:30]b
        [00:10]a
        [00:20]c
        """)
        #expect(file.lines.map(\.text) == ["a", "c", "b"])
    }

    @Test("metadata captured and never emitted as lyrics")
    func metadata() throws {
        let file = try lines("""
        [ti:Sample]
        [ar:Someone]
        [by:tool]
        [Verse]
        [00:01]line
        """)
        #expect(file.metadata["ti"] == "Sample")
        #expect(file.metadata["ar"] == "Someone")
        #expect(file.metadata["by"] == "tool")
        #expect(file.unknownTags == ["Verse"])
        #expect(file.lines.map(\.text) == ["line"])
    }

    @Test("BOM and CRLF")
    func bomAndCRLF() throws {
        let raw = "\u{feff}[00:01]a\r\n[00:02]b\n"
        let file = try lines(raw)
        #expect(file.lines.map(\.timestampSeconds) == [1, 2])
        #expect(file.lines.map(\.text) == ["a", "b"])
    }

    @Test("unicode text preserved")
    func unicode() throws {
        let file = try lines("[00:01]Rindu · merindu ✨")
        #expect(file.lines.first?.text == "Rindu · merindu ✨")
    }

    @Test("malformed timestamp lines contribute nothing")
    func malformed() throws {
        let outcome = try LRCParser.parse(Data("[aa:bb]text\n[00:xx]bad\n".utf8))
        guard case .empty = outcome else { Issue.record("expected empty"); return }
    }

    @Test("empty inputs")
    func emptyCases() throws {
        let outcomeEmpty = try LRCParser.parse(Data())
        guard case .empty = outcomeEmpty else { Issue.record("empty data should be .empty"); return }
        let outcomeWs = try LRCParser.parse(Data("   \n\r\n".utf8))
        guard case .empty = outcomeWs else { Issue.record("whitespace should be .empty"); return }
        let outcomeBom = try LRCParser.parse(Data("\u{feff}".utf8))
        guard case .empty = outcomeBom else { Issue.record("BOM only should be .empty"); return }
    }

    @Test("untimed text file")
    func plain() throws {
        let outcome = try LRCParser.parse(Data("just some\nwords no timestamps\n".utf8))
        guard case .untimed(let text, let count) = outcome else {
            Issue.record("expected untimed")
            return
        }
        #expect(count == 2)
        #expect(text == "just some\nwords no timestamps")
    }

    @Test("oversized input rejected")
    func oversized() throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: LRCParser.defaultByteLimit + 1)
        #expect(throws: LRCParseError.tooLarge(allowed: LRCParser.defaultByteLimit, actual: big.count)) {
            try LRCParser.parse(big)
        }
    }

    @Test("invalid UTF-8 rejected")
    func invalidUTF8() throws {
        let bad = Data([0xFF, 0xFE, 0x5B, 0x30, 0x5D])
        #expect(throws: LRCParseError.invalidUTF8) {
            try LRCParser.parse(bad)
        }
    }

    @Test("offset tag captured raw, applied once on demand")
    func offsetTag() throws {
        let file = try lines("[offset:+500]\n[00:10]a\n[00:20]b")
        #expect(file.offsetTagMilliseconds == 500)
        #expect(file.lines.map(\.timestampSeconds) == [10, 20])
        let applied = file.linesWithFileOffsetApplied()
        #expect(applied.map(\.timestampSeconds) == [9.5, 19.5])
        #expect(file.lines.map(\.timestampSeconds) == [10, 20])
    }

    @Test("negative offset shifts later and clamps line 0")
    func negativeOffset() throws {
        let file = try lines("[offset:-3000]\n[00:02]a")
        #expect(file.offsetTagMilliseconds == -3000)
        let applied = file.linesWithFileOffsetApplied()
        #expect(applied.first?.timestampSeconds == 5)
    }

    @Test("empty-text timed line kept as gap marker")
    func emptyText() throws {
        let file = try lines("[00:12]")
        #expect(file.lines.count == 1)
        #expect(file.lines.first?.text == "")
    }

    @Test("tolerant seconds above 59")
    func tolerantSeconds() throws {
        let file = try lines("[03:75]weird")
        #expect(file.lines.first?.timestampSeconds == 255)
    }

    @Test("caps timed lines at maxLineCount (2000)")
    func lineCap() throws {
        let many = (0..<2100).map { "[00:01]line-\($0)" }.joined(separator: "\n")
        let file = try lines(many)
        #expect(file.lines.count == LRCParser.maxLineCount)
    }
}
