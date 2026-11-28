import Foundation

// « Skip Intro / Recap / Credits » (5.6.0), the decisions. Pure: no file, no
// network, no clock. The app's `SkipMarkerWatch` reads the file's chapters
// (Matroska Chapters, MP4 chapter track), asks the optional external sources
// (`SkipMarkerProvider`) and feeds the players' position here; the players
// show the button `IntroMarkers.skip(at:)` returns, and the « next episode »
// card comes at `creditsStart` (`UpNextCountdown.useCredits`).
//
// A chapter counts by its title, in the six languages of the app and the
// usual anime / scene names (« OP », « ED »), within bounds that keep a
// mislabelled chapter from skipping the episode: an intro or a recap in the
// first half (or the first 15 min) and at most 5 min long, credits in the
// second half and at most 15 min long. An ambiguous name (« Générique »,
// « Sigla », « Credits », « Theme ») is an intro before the middle of the
// file, credits after it.

/// A chapter of the file played: its title (nil: none), where it starts and
/// ends (seconds of the file; nil end: where the next one starts).
public struct PlaybackChapter: Equatable {
    public let title: String?
    public let start: TimeInterval
    public let end: TimeInterval?

    public init(title: String?, start: TimeInterval, end: TimeInterval? = nil) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// A part of the file the player offers to skip.
public struct SkipMarker: Equatable {
    public enum Kind: String, CaseIterable {
        case recap, intro, credits, preview
    }

    public enum Source: Equatable {
        /// The file's own chapters.
        case chapters
        /// An external source (`SkipMarkerProvider.name`).
        case external(String)
    }

    public let kind: Kind
    public let start: TimeInterval
    public let end: TimeInterval
    public let source: Source

    public init(kind: Kind, start: TimeInterval, end: TimeInterval, source: Source = .chapters) {
        self.kind = kind
        self.start = start
        self.end = end
        self.source = source
    }

    public var length: TimeInterval { end - start }

    /// "intro 0:42–2:12 (chapters)": the `[Skip]` lines.
    public var logDescription: String {
        func time(_ seconds: TimeInterval) -> String {
            let whole = Int(seconds.rounded())
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        let origin: String
        switch source {
        case .chapters: origin = "chapters"
        case .external(let name): origin = name
        }
        return "\(kind.rawValue) \(time(start))–\(time(end)) (\(origin))"
    }
}

/// What an external source is asked (a community base of intro times).
public struct SkipMarkerQuery: Equatable {
    public let imdbID: String?
    public let tmdbID: Int?
    /// nil for a movie.
    public let season: Int?
    public let episode: Int?
    /// The file's length (seconds) when known: a source keyed by length
    /// (the times of one release do not fit another cut).
    public let duration: TimeInterval?

    public init(imdbID: String?, tmdbID: Int? = nil, season: Int? = nil, episode: Int? = nil, duration: TimeInterval? = nil) {
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.season = season
        self.episode = episode
        self.duration = duration
    }
}

/// An external source of skip markers. None is required: the file's
/// chapters work alone. A source answers once (any thread), with an empty
/// list when it knows nothing; its markers fill only the kinds the chapters
/// did not give (`IntroMarkers.merging`).
public protocol SkipMarkerProvider: AnyObject {
    var name: String { get }
    func markers(for query: SkipMarkerQuery, completion: @escaping ([SkipMarker]) -> Void)
}

/// The sources the app asks, in order (none by default).
public enum SkipMarkerProviders {
    public static var registered: [SkipMarkerProvider] = []
}

/// The skip markers of one file.
public struct IntroMarkers: Equatable {

    public struct Bounds: Equatable {
        /// An intro / a recap starts before this fraction of the file…
        public var openingMaxFraction = 0.5
        /// … or, the length unknown, before this time.
        public var openingMaxStart: TimeInterval = 15 * 60
        /// An intro / a recap / a preview lasts at most this.
        public var openingMaxLength: TimeInterval = 5 * 60
        /// Credits start after this fraction of the file.
        public var creditsMinFraction = 0.5
        /// Credits last at most this.
        public var creditsMaxLength: TimeInterval = 15 * 60
        /// A part shorter than this is not offered.
        public var minLength: TimeInterval = 5
        /// The button goes this long before the end of the part (a skip
        /// would land where playback already is).
        public var hideBeforeEnd: TimeInterval = 2
        /// Credits followed by less than this of something else end the
        /// episode: the « next episode » card, not a button.
        public var minAfterCredits: TimeInterval = 10

        public init() {}
        public static let standard = Bounds()
    }

    /// Sorted by start, at most one per kind and place.
    public let markers: [SkipMarker]
    /// The file's length (seconds), when known.
    public let duration: TimeInterval?
    public let bounds: Bounds

    public init(markers: [SkipMarker], duration: TimeInterval?, bounds: Bounds = .standard) {
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.duration = length
        self.bounds = bounds
        self.markers = markers
            .filter { IntroMarkers.isPlausible($0, duration: length, bounds: bounds) }
            .sorted { $0.start < $1.start }
    }

    public static let none = IntroMarkers(markers: [], duration: nil)

    public var isEmpty: Bool { markers.isEmpty }

    // MARK: From chapters

    /// The markers the chapters' titles give.
    public static func fromChapters(_ chapters: [PlaybackChapter], duration: TimeInterval?,
                                    bounds: Bounds = .standard) -> IntroMarkers {
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let sorted = chapters
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
        var found: [SkipMarker] = []
        for (index, chapter) in sorted.enumerated() {
            guard let label = label(ofChapterTitle: chapter.title) else { continue }
            let nextStart = sorted[(index + 1)...].first { $0.start > chapter.start }?.start
            let explicitEnd = chapter.end.flatMap { $0.isFinite && $0 > chapter.start ? $0 : nil }
            guard let end = explicitEnd ?? nextStart ?? length, end > chapter.start else { continue }
            let kind: SkipMarker.Kind
            switch label {
            case .kind(let known): kind = known
            case .theme:
                let middle = length.map { $0 / 2 } ?? bounds.openingMaxStart
                kind = chapter.start < middle ? .intro : .credits
            }
            // « Opening » then « Opening (cont.) », « ED » then « Credits »: one part.
            if let last = found.last, last.kind == kind, chapter.start - last.end <= 1 {
                found[found.count - 1] = SkipMarker(kind: kind, start: last.start, end: max(last.end, end))
            } else {
                found.append(SkipMarker(kind: kind, start: chapter.start, end: end))
            }
        }
        return IntroMarkers(markers: found, duration: length, bounds: bounds)
    }

    /// What a chapter's title says it is.
    enum Label: Equatable {
        case kind(SkipMarker.Kind)
        /// A theme or « credits » with no « opening » / « end »: placed by its time.
        case theme
    }

    /// Phrases, accents and case folded, punctuation as spaces; each is
    /// matched as whole words.
    private static let recapPhrases = [
        "recap", "previously", "previously on", "last time", "story so far",
        "precedemment", "precedemment dans", "resume", "rappel", "recapitulatif", "dans les episodes precedents",
        "zusammenfassung", "was bisher geschah", "ruckblick", "bisher bei",
        "riassunto", "nelle puntate precedenti", "ricapitolando",
        "resumen", "anteriormente", "anteriormente en", "previamente", "en capitulos anteriores",
        "resumo", "anteriormente em", "nos episodios anteriores",
    ]
    private static let previewPhrases = [
        "preview", "next episode", "next time", "next week", "coming up", "sneak peek",
        "prochain episode", "prochainement", "a suivre", "bande annonce",
        "vorschau", "nachste folge", "nachstes mal",
        "anteprima", "prossimo episodio", "prossimamente",
        "proximo episodio", "adelanto", "en el proximo", "no proximo",
    ]
    private static let creditsPhrases = [
        "end credits", "ending credits", "closing credits", "ending", "ending theme", "ending song", "outro",
        "credits end", "end titles", "end title", "final credits",
        "generique de fin", "generique fin", "credits de fin",
        "abspann", "nachspann", "schlusstitel", "abspannlied",
        "titoli di coda", "sigla finale", "sigla di chiusura",
        "creditos finales", "creditos de cierre", "tema de cierre",
        "creditos finais", "encerramento", "tema de encerramento",
    ]
    private static let introPhrases = [
        "intro", "opening", "opening credits", "opening theme", "opening song",
        "theme song", "main title", "main titles", "title sequence",
        "generique de debut", "generique d ouverture", "generique debut",
        "vorspann", "titelsequenz", "titellied",
        "sigla iniziale", "sigla di apertura",
        "cabecera", "creditos iniciales",
        "abertura", "creditos iniciais", "vinheta de abertura",
    ]
    /// The story itself, whatever else the title says (« Post-Credits Scene »).
    private static let contentPhrases = [
        "post credits", "after credits", "mid credits", "stinger", "apres generique", "nach dem abspann",
        "dopo i titoli", "pos creditos", "post creditos", "escena",
    ]
    private static let themePhrases = [
        "generique", "sigla", "credits", "credit", "creditos",
    ]

    /// The label of a chapter's title; nil for a plain chapter (« Chapter 3 »,
    /// « 00:12:04.000 », a scene name).
    static func label(ofChapterTitle title: String?) -> Label? {
        guard let title = title else { return nil }
        let words = normalizedWords(title)
        guard !words.isEmpty else { return nil }
        // Anime numbering: « OP1 », « ED2 », « OP 2 ».
        let unnumbered = words.map { word -> String in
            for prefix in ["op", "ed"] where word.hasPrefix(prefix) && word.count > prefix.count
                && word.dropFirst(prefix.count).allSatisfy(\.isNumber) {
                return prefix
            }
            return word
        }.filter { !$0.allSatisfy(\.isNumber) }
        guard !unnumbered.isEmpty else { return nil }
        // « OP » / « ED » alone (« Ed » inside a title is a name).
        if unnumbered == ["op"] { return .kind(.intro) }
        if unnumbered == ["ed"] { return .kind(.credits) }
        if matches(unnumbered, contentPhrases) { return nil }
        if matches(unnumbered, previewPhrases) { return .kind(.preview) }
        if matches(unnumbered, recapPhrases) { return .kind(.recap) }
        if matches(unnumbered, creditsPhrases) { return .kind(.credits) }
        if matches(unnumbered, introPhrases) { return .kind(.intro) }
        if matches(unnumbered, themePhrases) { return .theme }
        return nil
    }

    /// The title's words, lowercased, without accents, split on anything
    /// that is not a letter or a digit.
    static func normalizedWords(_ title: String) -> [String] {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// One of `phrases` appears in `words` as consecutive whole words.
    private static func matches(_ words: [String], _ phrases: [String]) -> Bool {
        for phrase in phrases {
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.count <= words.count else { continue }
            for start in 0...(words.count - parts.count) where Array(words[start..<(start + parts.count)]) == parts {
                return true
            }
        }
        return false
    }

    private static func isPlausible(_ marker: SkipMarker, duration: TimeInterval?, bounds: Bounds) -> Bool {
        guard marker.start.isFinite, marker.end.isFinite, marker.start >= 0,
              marker.length >= bounds.minLength else { return false }
        if let duration = duration, marker.start >= duration { return false }
        switch marker.kind {
        case .intro, .recap:
            guard marker.length <= bounds.openingMaxLength else { return false }
            if let duration = duration { return marker.start < duration * bounds.openingMaxFraction }
            return marker.start < bounds.openingMaxStart
        case .credits:
            guard marker.length <= bounds.creditsMaxLength else { return false }
            if let duration = duration { return marker.start >= duration * bounds.creditsMinFraction }
            return true
        case .preview:
            guard marker.length <= bounds.openingMaxLength else { return false }
            if let duration = duration { return marker.start >= duration * bounds.creditsMinFraction }
            return true
        }
    }

    // MARK: External sources

    /// These markers, plus `others`' of the kinds these lack (the file's own
    /// chapters win: they were made for this very file).
    public func merging(_ others: [SkipMarker]) -> IntroMarkers {
        let known = Set(markers.map(\.kind))
        let added = others.filter { !known.contains($0.kind) }
        return IntroMarkers(markers: markers + added, duration: duration, bounds: bounds)
    }

    /// The same markers, the file's length now known (a marker that does not
    /// fit it goes).
    public func with(duration: TimeInterval?) -> IntroMarkers {
        IntroMarkers(markers: markers, duration: duration ?? self.duration, bounds: bounds)
    }

    // MARK: What the player shows

    /// The part to offer skipping at `position` (seconds); nil: no button.
    /// Credits that end the file are not offered: the « next episode » card
    /// comes there (`creditsStart`).
    public func skip(at position: TimeInterval) -> SkipMarker? {
        guard position.isFinite else { return nil }
        return markers.first { marker in
            guard position >= marker.start, position < marker.end - bounds.hideBeforeEnd else { return false }
            return marker.kind != .credits || !endsFile(marker)
        }
    }

    /// Where the credits that end the file start (only a preview may follow
    /// them); nil: none known.
    public var creditsStart: TimeInterval? {
        markers.last { $0.kind == .credits && endsFile($0) }?.start
    }

    /// Nothing but credits or a preview after `marker` (within `minAfterCredits`).
    private func endsFile(_ marker: SkipMarker) -> Bool {
        var reached = marker.end
        for next in markers where next.start >= marker.start && next != marker {
            guard next.start - reached < bounds.minAfterCredits else { break }
            guard next.kind == .credits || next.kind == .preview else { return false }
            reached = max(reached, next.end)
        }
        guard let duration = duration else { return true }
        return duration - reached < bounds.minAfterCredits
    }
}
