import AppKit
import Combine
import Foundation
import GlieseCore
import SwiftUI

@MainActor
final class GlieseClipboardManager: ObservableObject {
    static let shared = GlieseClipboardManager()

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var totalBytes: Int = 0
    @Published var searchQuery: String = ""
    @Published private(set) var lastCopiedID: UUID?

    private var store = ClipboardMemoryStore(
        maxEntries: 50,
        maxEntryBytes: 2_097_152,
        maxTotalBytes: 20_971_520
    )
    private var lastObservedChangeCount: Int
    private var pollTimer: Timer?

    private init() {
        self.lastObservedChangeCount = NSPasteboard.general.changeCount
        startPolling()
    }

    var filteredEntries: [ClipboardEntry] {
        store.filteredEntries(query: searchQuery)
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPasteboardIfChanged()
            }
        }
    }

    func stopAndWipe() {
        pollTimer?.invalidate()
        pollTimer = nil
        store.clearAll()
        entries = []
        totalBytes = 0
        searchQuery = ""
        lastCopiedID = nil
    }

    func copyToPasteboard(_ id: UUID) {
        guard let entry = store.prepareCopyToPasteboard(id: id) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()

        switch entry.payload {
        case .text(let str), .link(let str):
            pb.setString(str, forType: .string)
        case .image(let data, _, _, _):
            if let nsImage = NSImage(data: data),
               let tiff = nsImage.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            } else {
                pb.setData(data, forType: .png)
            }
        }

        lastObservedChangeCount = pb.changeCount
        lastCopiedID = entry.id
        syncPublishedState()
    }

    func togglePin(_ id: UUID) {
        store.togglePin(id: id)
        syncPublishedState()
    }

    func remove(_ id: UUID) {
        store.remove(id: id)
        syncPublishedState()
    }

    func clearAll() {
        store.clearAll()
        syncPublishedState()
    }

    func checkPasteboardIfChanged() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount

        let rawTypes = Set((pb.types ?? []).map(\.rawValue))
        let frontApp = NSWorkspace.shared.frontmostApplication
        let sourceBundle = frontApp?.bundleIdentifier
        let sourceName = frontApp?.localizedName

        if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = store.capture(
                payload: .text(str),
                pasteboardTypes: rawTypes,
                sourceAppBundleID: sourceBundle,
                sourceAppName: sourceName
            )
            syncPublishedState()
            return
        }

        if let pngData = pb.data(forType: .png),
           let image = NSImage(data: pngData) {
            let size = image.size
            _ = store.capture(
                payload: .image(data: pngData, width: Int(size.width), height: Int(size.height), uti: "public.png"),
                pasteboardTypes: rawTypes,
                sourceAppBundleID: sourceBundle,
                sourceAppName: sourceName
            )
            syncPublishedState()
            return
        }

        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            _ = store.capture(
                payload: .image(data: pngData, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, uti: "public.png"),
                pasteboardTypes: rawTypes,
                sourceAppBundleID: sourceBundle,
                sourceAppName: sourceName
            )
            syncPublishedState()
        }
    }

    private func syncPublishedState() {
        entries = store.entries
        totalBytes = store.totalBytes
    }
}

// MARK: - Notch Session Clipboard Tab View

struct GlieseClipboardView: View {
    @ObservedObject var clipboard = GlieseClipboardManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerBar
            Divider().overlay(Color.white.opacity(0.12))
            entriesList
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Filter session clipboard…", text: $clipboard.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                if !clipboard.searchQuery.isEmpty {
                    Button {
                        clipboard.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Text("RAM Only (\(clipboard.entries.count)/50)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            if !clipboard.entries.isEmpty {
                Button("Clear All") {
                    clipboard.clearAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Clear all clipboard history")
            }
        }
    }

    @ViewBuilder
    private var entriesList: some View {
        let items = clipboard.filteredEntries
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(clipboard.entries.isEmpty ? "Session clipboard is empty" : "No matching clipboard entries")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Copied text, links, and images stay in memory for this session only and are wiped on Quit. Concealed password manager items are ignored.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                clipboard.copyToPasteboard(entry.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: iconName(for: entry.kind))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.kind == .link ? Color.cyan : Color.white.opacity(0.75))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.previewText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let appName = entry.sourceAppName {
                                Text(appName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            if clipboard.lastCopiedID == entry.id {
                                Text("Copied")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(entry.previewText)")

            Button {
                clipboard.togglePin(entry.id)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5))
                    .foregroundStyle(entry.isPinned ? Color.yellow : Color.white.opacity(0.45))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isPinned ? "Unpin entry" : "Pin entry")

            Button {
                clipboard.remove(entry.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete entry")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func iconName(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .text: return "doc.plaintext"
        case .link: return "link"
        case .image: return "photo"
        }
    }
}
