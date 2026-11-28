import Foundation
import Combine
import AVFoundation
import PopcornKit

// « Skip Intro / Recap / Credits » (5.6.0): the app's half of PopcornKit's
// `IntroMarkers`. One watch per file played, shared by the players that play
// it in turn (the native one, then VLC after a hand-off: same file, same
// watch). It reads the file's chapters in the background — Matroska
// Chapters (`MatroskaDemuxer.loadChapters`, retried while the torrent has
// not downloaded them), an MP4 / MOV chapter track (AVFoundation) — then
// asks the optional external sources (`SkipMarkerProviders.registered`).
//
// WHAT A PLAYER CALLS (main thread):
//
//   let skip = SkipMarkerWatch.watch(for: localFile, media: media)
//   skip.attach { seconds in /* seek the player there */ }   // the player that plays now
//   skip.tick(position: s, duration: d)    // its 1 Hz clock (seconds of the file)
//   skip.active                            // @Published: the part to offer skipping (nil: none)
//   skip.skip()                            // the button: jumps to its end
//
// The credits that end the file go to the episode's `UpNextSession` (its
// card comes where they start) from `tick`, whatever the player.

@MainActor
final class SkipMarkerWatch: ObservableObject {

    /// The watch of the file playing (one at a time).
    private(set) static var current: SkipMarkerWatch?

    let file: URL
    let media: Media?
    @Published private(set) var markers: IntroMarkers = .none
    /// The part the button offers to skip now; nil: no button.
    @Published private(set) var active: SkipMarker?

    private var seekHandler: ((TimeInterval) -> Void)?
    private var isStopped = false
    private var attempts = 0
    private var askedProviders = false
    private var duration: TimeInterval?
    private var loggedOffers: Set<String> = []
    /// The part whose button the user put away (Menu on the Apple TV): not
    /// offered again while playback is inside it.
    private var dismissed: SkipMarker?
    private let queue = DispatchQueue(label: "PopcornTime.SkipMarkerWatch", qos: .utility)

    /// A Matroska file still downloading: its chapters are asked again this often…
    static let retryInterval: TimeInterval = 10
    /// … this many times at most.
    static let maxAttempts = 60

    /// The watch of `file`: the current one when it plays the same file (a
    /// hand-off to VLC), else a new one that starts reading its markers.
    static func watch(for file: URL, media: Media?) -> SkipMarkerWatch {
        if let current = current, !current.isStopped,
           current.file.standardizedFileURL.path == file.standardizedFileURL.path {
            return current
        }
        current?.stop()
        let watch = SkipMarkerWatch(file: file, media: media)
        current = watch
        watch.load()
        return watch
    }

    private init(file: URL, media: Media?) {
        self.file = file
        self.media = media
    }

    // MARK: What the player calls

    /// `seek` jumps the player that plays now to a time of the file (seconds).
    func attach(seek: @escaping (TimeInterval) -> Void) {
        seekHandler = seek
    }

    /// The player's clock.
    func tick(position: TimeInterval, duration: TimeInterval?) {
        guard !isStopped, position.isFinite else { return }
        if let duration = duration, duration.isFinite, duration > 0, self.duration == nil {
            self.duration = duration
            if markers.duration == nil, !markers.isEmpty { markers = markers.with(duration: duration) }
        }
        var offer = markers.skip(at: position)
        if offer == nil { dismissed = nil }
        if offer != nil, offer == dismissed { offer = nil }
        if offer != active {
            active = offer
            if let offer = offer, loggedOffers.insert(offer.logDescription).inserted {
                print("[Skip] button: \(offer.logDescription)")
            }
        }
        if let credits = markers.creditsStart {
            UpNextSession.current?.useCredits(at: credits)
        }
    }

    /// The button: playback jumps to the end of the part offered.
    func skip() {
        guard let marker = active, let seek = seekHandler else { return }
        print("[Skip] skipped \(marker.logDescription)")
        active = nil
        seek(marker.end)
    }

    /// The user put the button away: not offered again inside this part.
    func dismissOffer() {
        guard let marker = active else { return }
        print("[Skip] button put away: \(marker.logDescription)")
        dismissed = marker
        active = nil
    }

    /// The playback is over: nothing more is read.
    func stop() {
        isStopped = true
        seekHandler = nil
        active = nil
        if SkipMarkerWatch.current === self { SkipMarkerWatch.current = nil }
    }

    // MARK: Reading the markers

    private func load() {
        let file = self.file
        if BoundedStorageUX.isMatroska(file) {
            queue.async { [weak self] in
                let result = SkipMarkerWatch.matroskaChapters(file)
                DispatchQueue.main.async { self?.matroskaRead(result) }
            }
        } else if ["mp4", "m4v", "mov"].contains(file.pathExtension.lowercased()) {
            Task { [weak self] in
                let chapters = await SkipMarkerWatch.assetChapters(file)
                self?.adopt(chapters: chapters, duration: nil, origin: "MP4 chapters")
            }
        } else {
            askProviders()
        }
    }

    private enum MatroskaRead {
        case chapters([PlaybackChapter], duration: TimeInterval?)
        case notYet
        case none(String)
    }

    private func matroskaRead(_ result: MatroskaRead) {
        guard !isStopped else { return }
        attempts += 1
        switch result {
        case .chapters(let chapters, let duration):
            adopt(chapters: chapters, duration: duration, origin: "Matroska chapters")
        case .notYet where attempts < Self.maxAttempts:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                guard let self = self, !self.isStopped else { return }
                self.load()
            }
        case .notYet:
            print("[Skip] \(file.lastPathComponent): chapters not downloaded after \(attempts) tries")
            askProviders()
        case .none(let reason):
            print("[Skip] \(file.lastPathComponent): no chapters (\(reason))")
            askProviders()
        }
    }

    private func adopt(chapters: [PlaybackChapter], duration: TimeInterval?, origin: String) {
        guard !isStopped else { return }
        let found = IntroMarkers.fromChapters(chapters, duration: duration ?? self.duration)
        markers = found
        let list = found.markers.map(\.logDescription).joined(separator: ", ")
        print("[Skip] \(file.lastPathComponent): \(chapters.count) \(origin)"
              + (found.isEmpty ? ", no part to skip" : " → \(list)")
              + (found.creditsStart.map { "; credits end the file at \(Int($0)) s" } ?? ""))
        askProviders()
    }

    /// The external sources, for the kinds the file's chapters lack.
    private func askProviders() {
        guard !askedProviders, !isStopped else { return }
        askedProviders = true
        let providers = SkipMarkerProviders.registered
        guard !providers.isEmpty, let query = query else { return }
        for provider in providers {
            provider.markers(for: query) { [weak self] found in
                DispatchQueue.main.async {
                    guard let self = self, !self.isStopped, !found.isEmpty else { return }
                    self.markers = self.markers.merging(found)
                    print("[Skip] \(provider.name): " + found.map(\.logDescription).joined(separator: ", "))
                }
            }
        }
    }

    private var query: SkipMarkerQuery? {
        if let episode = media as? Episode {
            return SkipMarkerQuery(imdbID: episode.show?.id, tmdbID: episode.show?.tmdbId, season: episode.season,
                                   episode: episode.episode, duration: duration)
        }
        if let movie = media as? Movie {
            return SkipMarkerQuery(imdbID: movie.id, duration: duration)
        }
        return nil
    }

    // MARK: Readers (background)

    nonisolated private static func matroskaChapters(_ file: URL) -> MatroskaRead {
        guard file.isFileURL, let handle = try? FileHandle(forReadingFrom: file) else { return .notYet }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { return .notYet }
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { size }))
        guard demuxer.parseHeaders() else { return .notYet }
        switch demuxer.loadChapters() {
        case .available(let chapters):
            let list = chapters.map { PlaybackChapter(title: $0.title, start: $0.startSeconds, end: $0.endSeconds) }
            return .chapters(list, duration: demuxer.durationSeconds > 0 ? demuxer.durationSeconds : nil)
        case .notYet:
            return .notYet
        case .unavailable(let reason):
            return .none(reason)
        }
    }

    /// The chapter track of an MP4 / MOV (the user's languages first).
    nonisolated private static func assetChapters(_ file: URL) async -> [PlaybackChapter] {
        let asset = AVURLAsset(url: file)
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages) else {
            return []
        }
        var chapters: [PlaybackChapter] = []
        for group in groups {
            let range = group.timeRange
            guard range.start.isNumeric else { continue }
            let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = try? await titleItem?.load(.stringValue)
            let end = range.duration.isNumeric ? (range.start + range.duration).seconds : nil
            chapters.append(PlaybackChapter(title: title ?? nil, start: range.start.seconds, end: end))
        }
        return chapters
    }
}

extension SkipMarker.Kind {
    /// The button's title: « Skip Intro », « Skip Recap »…
    var buttonTitle: String {
        switch self {
        case .intro: return "Player.SkipIntro".localized
        case .recap: return "Player.SkipRecap".localized
        case .credits: return "Player.SkipCredits".localized
        case .preview: return "Player.SkipPreview".localized
        }
    }
}

#if !os(tvOS)
import SwiftUI

/// « Skip Intro » over the iPhone / iPad and Mac players: a capsule at the
/// bottom trailing corner while the watch offers a part to skip.
struct SkipMarkerButton: View {
    @ObservedObject var watch: SkipMarkerWatch

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let marker = watch.active {
                Button(action: { watch.skip() }) {
                    Label(marker.kind.buttonTitle, systemImage: "forward.end.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("skipMarkerButton")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: watch.active?.kind)
        .animation(.easeInOut(duration: 0.25), value: watch.active == nil)
    }
}
#endif
