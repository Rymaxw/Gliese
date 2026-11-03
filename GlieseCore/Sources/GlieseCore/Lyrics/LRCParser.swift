// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum LyricsParseOutcome: Equatable {
    case timed(LRCFile)
    case untimed(text: String, lineCount: Int)
    case empty
}

public struct LRCFile: Equatable, Sendable {
    public let lines: [LyricLine]
    public let metadata: [String: String]
    public let unknownTags: [String]
    public let offsetTagMilliseconds: Int?

    public func linesWithFileOffsetApplied() -> [LyricLine] {
        guard let ms = offsetTagMilliseconds, ms != 0 else { return lines }
        let delta = Double(ms) / 1000.0
        return lines.map { LyricLine(timestampSeconds: max(0, $0.timestampSeconds - delta), text: $0.text, stableOrdinal: $0.stableOrdinal) }
    }
}

public struct LyricLine: Equatable, Sendable {
    public let timestampSeconds: Double
    public let text: String
    public let stableOrdinal: Int
}

public enum LRCParseError: Error, Equatable, Sendable {
    case tooLarge(allowed: Int, actual: Int)
    case invalidUTF8
}

public enum LRCParser {
    public static let defaultByteLimit = 128 * 1024
    public static let maxLineCount = 2000

    static let lineTextCap = 4096
    static let metadataCap = 64
    static let unknownTagsCap = 64
    static let tokenCap = 64

    public static func parse(_ text: String, byteLimit: Int = defaultByteLimit) throws -> LyricsParseOutcome {
        try parse(Data(text.utf8), byteLimit: byteLimit)
    }

    public static func parse(_ data: Data, byteLimit: Int = defaultByteLimit) throws -> LyricsParseOutcome {
        guard !data.isEmpty else { return .empty }
        guard data.count <= byteLimit else { throw LRCParseError.tooLarge(allowed: byteLimit, actual: data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw LRCParseError.invalidUTF8 }
        let body = dropUTF8BOM(text).replacingOccurrences(of: "\r\n", with: "\n")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }

        var timed: [(seconds: Double, line: LyricLine)] = []
        var timedCount = 0
        var plain: [String] = []
        var metadata: [String: String] = [:]
        var unknown: [String] = []

        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
            if line.isEmpty { continue }

            var timestamps: [Double] = []
            var rest = line[...]
            var sawToken = false

            while rest.first == "[" {
                guard let close = rest.firstIndex(of: "]") else { break }
                let token = String(rest[rest.index(after: rest.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                if token.count <= tokenCap {
                    if let t = parseTimestamp(token) {
                        timestamps.append(t)
                    } else if timestamps.isEmpty {
                        sawToken = true
                        record(token, metadata: &metadata, unknown: &unknown)
                    }
                }
                rest = rest[rest.index(after: close)...]
            }

            if !timestamps.isEmpty {
                let clip = String(String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " \t")).prefix(lineTextCap))
                for t in timestamps where timed.count < maxLineCount {
                    timed.append((t, LyricLine(timestampSeconds: t, text: clip, stableOrdinal: timedCount)))
                    timedCount += 1
                }
            } else if !sawToken && plain.count < maxLineCount {
                plain.append(line)
            }
        }

        if !timed.isEmpty {
            let entries = timed.sorted { lhs, rhs in
                lhs.seconds == rhs.seconds ? lhs.line.stableOrdinal < rhs.line.stableOrdinal : lhs.seconds < rhs.seconds
            }
            let offset = metadata["offset"].flatMap(parseOffsetMilliseconds)
            let out = entries.map { LyricLine(timestampSeconds: $0.seconds, text: $0.line.text, stableOrdinal: $0.line.stableOrdinal) }
            return .timed(LRCFile(lines: out, metadata: metadata, unknownTags: Array(unknown.prefix(unknownTagsCap)), offsetTagMilliseconds: offset))
        }
        if !plain.isEmpty { return .untimed(text: plain.joined(separator: "\n"), lineCount: plain.count) }
        return .empty
    }

    static func dropUTF8BOM(_ text: String) -> String {
        if text.hasPrefix("\u{feff}") { return String(text.dropFirst(1)) }
        return text
    }
}

private func record(_ token: String, metadata: inout [String: String], unknown: inout [String]) {
    guard let colon = token.firstIndex(of: ":") else {
        if unknown.count < LRCParser.unknownTagsCap { unknown.append(token) }
        return
    }
    let key = String(token[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
    if key.isEmpty { return }
    let value = String(token[token.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    guard value.count <= 256 else { return }
    if metadata[key] == nil { metadata[key] = value }
}

func parseTimestamp(_ token: String) -> Double? {
    let parts = token.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count >= 1, parts[0].count <= 5, isDigits(parts[0]) else { return nil }
    var secondsPart = parts[1]
    var fractionDigits = ""
    if let dot = secondsPart.firstIndex(of: ".") {
        fractionDigits = String(secondsPart[secondsPart.index(after: dot)...])
        secondsPart = secondsPart[..<dot]
    }
    guard (1...2).contains(secondsPart.count), isDigits(secondsPart) else { return nil }
    let secs = Int(secondsPart) ?? -1
    guard (0...99).contains(secs) else { return nil }
    guard fractionDigits.isEmpty || (fractionDigits.count <= 3 && isDigits(fractionDigits)) else { return nil }
    let minutes = Int(parts[0]) ?? -1
    guard minutes >= 0, minutes < 100_000 else { return nil }
    let base = Double(minutes * 60 + secs)
    let frac = fractionDigits.isEmpty ? 0.0 : (Double(Int(fractionDigits) ?? 0) / pow(10.0, Double(fractionDigits.count)))
    return base + frac
}

private func isDigits<S: StringProtocol>(_ s: S) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
}

private func parseOffsetMilliseconds(_ raw: String) -> Int? {
    var s = raw[...]
    var sign = 1
    if s.first == "+" { s = s.dropFirst() }
    else if s.first == "-" { sign = -1; s = s.dropFirst() }
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 6, isDigits(trimmed[...]) else { return nil }
    let value = Int(trimmed) ?? 0
    return sign * value
}
