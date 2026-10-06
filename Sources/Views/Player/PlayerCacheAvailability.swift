import SwiftUI

@MainActor
struct PlayerCacheAvailability: View {
    @Environment(MusicAppModel.self) private var model
    let identifier: String

    var body: some View {
        if let current = model.player.currentTrack {
            VStack(alignment: .leading, spacing: 4) {
                status("Current", track: current, ready: model.player.isCurrentTrackCached, suffix: "current")
                if let next = nextTrack {
                    status("Next", track: next, ready: model.player.isNextTrackCached, suffix: "next")
                }
                Text(notice(current: current))
                    .appFont(.caption2)
                    .accessibilityIdentifier("\(identifier).notice")
            }
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var nextTrack: Track? {
        model.player.nextAutomaticTrack
    }

    private var inventoryIsKnown: Bool {
        model.hasLoadedCachedSongs && model.cachedSongsUsage != nil && model.cachedSongsError == nil
    }

    /// Downloads keep the "iOS can remove" wording only for the cache tier; the permanent tier is stated plainly.
    private func notice(current: Track) -> String {
        if model.isDownloaded(current) {
            return model.isOffline ? "Offline. Downloads stay on this device." : "Downloaded audio stays on this device. iOS can remove cached audio."
        }
        return model.isOffline ? "Offline. iOS can remove cached audio." : "Temporary audio. iOS can remove it."
    }

    private func status(_ title: String, track: Track, ready: Bool, suffix: String) -> some View {
        let cached = ready || (inventoryIsKnown && model.cachedPlayableTrackIDs.contains(track.id))
        let detail = if model.isDownloaded(track) {
            "Downloaded"
        } else if cached {
            "Cached on this device"
        } else if inventoryIsKnown {
            model.isOffline ? "Needs a connection" : "Not cached"
        } else {
            "Cache status unavailable"
        }
        return Text("\(title): \(detail)")
            .appFont(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(identifier).\(suffix)")
    }
}
