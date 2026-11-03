import Foundation
import Testing
@testable import GlieseCore

@Suite("ShelfPolicy File Reference & Deduplication Tests")
struct ShelfPolicyTests {

    @Test("Accepts file URLs, normalizes relative segments without reading disk, and deduplicates")
    func fileURLNormalizationAndDedup() {
        let url1 = URL(fileURLWithPath: "/tmp/gliese-test/../gliese-test/report.pdf")
        let url2 = URL(fileURLWithPath: "/tmp/gliese-test/report.pdf")

        let first = ShelfPolicy.evaluateAdd(url: url1, existing: [])
        guard case .added(let record) = first else {
            Issue.record("Expected .added")
            return
        }
        #expect(record.canonicalFilePath == "/tmp/gliese-test/report.pdf")
        #expect(record.displayName == "report.pdf")

        let second = ShelfPolicy.evaluateAdd(url: url2, existing: [record])
        #expect(second == .duplicateExisting(record.id))
    }

    @Test("Rejects non-file URLs and enforces 100-item cap")
    func rejectsWebURLAndEnforcesCap() {
        let webURL = URL(string: "https://example.com/file.pdf")!
        #expect(ShelfPolicy.evaluateAdd(url: webURL, existing: []) == .rejectedNotFileURL)

        let existing = (0..<2).map { idx in
            ShelfReferenceRecord(canonicalFilePath: "/tmp/f\(idx).txt", displayName: "f\(idx).txt")
        }
        let overCap = ShelfPolicy.evaluateAdd(
            url: URL(fileURLWithPath: "/tmp/f3.txt"),
            existing: existing,
            maxItems: 2
        )
        #expect(overCap == .rejectedCapReached(maxItems: 2))
    }
}
