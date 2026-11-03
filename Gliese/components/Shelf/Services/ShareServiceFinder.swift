import Cocoa

class ShareServiceFinder {
    @MainActor
    func findApplicableServices(for items: [Any]) async -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}
