import Foundation

/// What a lookup of a title's rating found.
public enum ContentRatingLookup: Equatable, Sendable {
    /// Its certification ("PG-13", "TV-Y7", "12").
    case rated(String)
    /// The source knows the title, or not, but no rating of it.
    case unrated
    /// No answer (offline, a refused key): asked again later.
    case failed
    /// Nothing to ask with (no TMDB key): not asked, nothing kept.
    case unavailable
}

/// The titles' ratings by IMDb id, for the kids profiles
/// (`ContentRestriction`): the ones the sources gave (`record`) and the
/// ones TMDB told (`ask`, `resolve`), kept on disk for every profile — a
/// rating does not change. A title TMDB has no rating for is asked again
/// after `unratedLifetime`; one it did not answer about, after
/// `failureDelay`.
public final class ContentRatingStore: @unchecked Sendable {

    /// Posted on the main queue (object: the store) when ratings were
    /// learned: the screens of a kids profile show the titles they let
    /// through (the Home rebuilds).
    public static let didChangeNotification = Notification.Name("PopcornKit.ContentRatingStore.didChange")

    /// Seconds a list waits for the ratings of its titles before it is
    /// shown with those it has (`ContentRestriction.admit`).
    public static let listWait: TimeInterval = 4
    /// Lookups in flight at once (two TMDB requests each).
    static let parallelLookups = 4
    static let unratedLifetime: TimeInterval = 14 * 24 * 3600
    static let failureDelay: TimeInterval = 10 * 60

    public typealias Lookup = (_ imdbId: String, _ completion: @escaping (ContentRatingLookup) -> Void) -> Void

    /// The app's: in the Caches folder, rated by TMDB with the user's key.
    public static let shared: ContentRatingStore = {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #if DEBUG
        // The UI tests: nothing from an earlier run, no request.
        if UserDefaults.standard.bool(forKey: "PTDebugLibraryInMemory") {
            return ContentRatingStore(fileURL: nil, lookup: { _, done in done(.unavailable) })
        }
        #endif
        return ContentRatingStore(fileURL: folder?.appendingPathComponent("ContentRatings.json"),
                                  lookup: TMDBRatingLookup().lookUp)
    }()

    private struct Entry: Codable {
        /// nil: the source has no rating of the title.
        var certification: String?
        var date: Date
    }

    private let fileURL: URL?
    private let lookup: Lookup
    private let now: () -> Date
    private let center: NotificationCenter
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var failures: [String: Date] = [:]
    private var queued: [String] = []
    private var running = Set<String>()
    private var waiters: [Waiter] = []
    private var savePending = false
    private var postPending = false

    private final class Waiter {
        var remaining: Set<String>
        var completion: (() -> Void)?
        init(remaining: Set<String>, completion: @escaping () -> Void) {
            self.remaining = remaining
            self.completion = completion
        }
    }

    public init(fileURL: URL?, lookup: @escaping Lookup, now: @escaping () -> Date = Date.init,
                center: NotificationCenter = .default) {
        self.fileURL = fileURL
        self.lookup = lookup
        self.now = now
        self.center = center
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    // MARK: Reading

    /// The rating known for the title: nil when none is (not asked yet, or
    /// the source has none).
    public func certification(of imdbId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[imdbId]?.certification
    }

    /// Nothing more to ask about the title for now: rated, found unrated
    /// recently, or not answered about a moment ago. Under the lock.
    private func isSettled(_ id: String, at date: Date) -> Bool {
        if let entry = entries[id] {
            if entry.certification != nil { return true }
            if date.timeIntervalSince(entry.date) < ContentRatingStore.unratedLifetime { return true }
        }
        if let failed = failures[id], date.timeIntervalSince(failed) < ContentRatingStore.failureDelay { return true }
        return false
    }

    // MARK: Writing

    /// A rating a source gave (YTS's, the Popcorn API's): kept when no other
    /// is known. One not understood (« Not Rated ») is not kept.
    public func record(_ certification: String, for imdbId: String) {
        guard !imdbId.isEmpty, ContentRating.age(of: certification) != nil else { return }
        lock.lock()
        let isNew = entries[imdbId]?.certification == nil
        if isNew { entries[imdbId] = Entry(certification: certification, date: now()) }
        lock.unlock()
        if isNew { scheduleSave() }
    }

    /// Looks the titles' ratings up in the background, the ones not known
    /// yet; posts `didChangeNotification` once some were found.
    public func ask(_ imdbIds: [String]) {
        start(imdbIds)
    }

    /// Looks the titles' ratings up, then `completion` (main queue) once
    /// every one was answered about, or after `timeout` seconds.
    public func resolve(_ imdbIds: [String], timeout: TimeInterval, completion: @escaping () -> Void) {
        let date = now()
        lock.lock()
        let missing = Set(imdbIds.filter { !$0.isEmpty && !isSettled($0, at: date) })
        guard !missing.isEmpty else {
            lock.unlock()
            return DispatchQueue.main.async(execute: completion)
        }
        let waiter = Waiter(remaining: missing, completion: completion)
        waiters.append(waiter)
        lock.unlock()
        start(Array(missing))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(waiter) }
    }

    // MARK: Lookups

    private func start(_ ids: [String]) {
        let date = now()
        lock.lock()
        for id in ids where !id.isEmpty && !isSettled(id, at: date) && !running.contains(id) && !queued.contains(id) {
            queued.append(id)
        }
        var next: [String] = []
        while running.count < ContentRatingStore.parallelLookups, !queued.isEmpty {
            let id = queued.removeFirst()
            running.insert(id)
            next.append(id)
        }
        lock.unlock()
        for id in next {
            lookup(id) { [weak self] result in self?.answered(id, result) }
        }
    }

    private func answered(_ id: String, _ result: ContentRatingLookup) {
        let date = now()
        lock.lock()
        running.remove(id)
        var learned = false
        switch result {
        case .rated(let certification) where ContentRating.age(of: certification) != nil:
            entries[id] = Entry(certification: certification, date: date)
            learned = true
        case .rated, .unrated:
            if entries[id]?.certification == nil { entries[id] = Entry(certification: nil, date: date) }
        case .failed:
            failures[id] = date
        case .unavailable:
            break
        }
        if result == .unavailable {
            // Nothing to ask with: the titles waiting are not asked either.
            for queuedID in queued { for waiter in waiters { waiter.remaining.remove(queuedID) } }
            queued.removeAll()
        }
        var done: [Waiter] = []
        for waiter in waiters {
            waiter.remaining.remove(id)
            if waiter.remaining.isEmpty { done.append(waiter) }
        }
        lock.unlock()
        done.forEach(finish)
        if result != .unavailable && result != .failed { scheduleSave() }
        if learned { schedulePost() }
        start([])
    }

    private func finish(_ waiter: Waiter) {
        lock.lock()
        let completion = waiter.completion
        waiter.completion = nil
        waiters.removeAll { $0 === waiter }
        lock.unlock()
        guard let completion else { return }
        if Thread.isMainThread { completion() } else { DispatchQueue.main.async(execute: completion) }
    }

    /// One notification for a burst of answers.
    private func schedulePost() {
        lock.lock()
        let posts = !postPending
        postPending = true
        lock.unlock()
        guard posts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.lock.lock()
            self.postPending = false
            self.lock.unlock()
            self.center.post(name: ContentRatingStore.didChangeNotification, object: self)
        }
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        let saves = !savePending
        savePending = true
        lock.unlock()
        guard saves else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { self.save() }
    }

    private func save() {
        lock.lock()
        savePending = false
        let snapshot = entries
        lock.unlock()
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A title's rating from TMDB, with the user's key (`HomeSettings`): its
/// TMDB id from its IMDb id (`/find`), then its US rating, else the
/// device's country's, else any country's (`release_dates` for a film,
/// `content_ratings` for a show).
struct TMDBRatingLookup {
    static let base = "https://api.themoviedb.org/3"

    var key: () -> String? = { HomeSettings().tmdbAPIKey }
    var region: String = Locale.current.region?.identifier ?? "US"
    var session: URLSession = .shared

    func lookUp(_ imdbId: String, completion: @escaping (ContentRatingLookup) -> Void) {
        guard let key = key() else { return completion(.unavailable) }
        get("/find/\(imdbId)?external_source=imdb_id", key: key) { data in
            guard let data else { return completion(.failed) }
            guard let found = TMDBRatingLookup.found(in: data) else { return completion(.unrated) }
            let path = found.isMovie ? "/movie/\(found.id)/release_dates" : "/tv/\(found.id)/content_ratings"
            self.get(path, key: key) { data in
                guard let data else { return completion(.failed) }
                let ratings = found.isMovie ? TMDBRatingLookup.releaseDates(in: data) : TMDBRatingLookup.contentRatings(in: data)
                completion(TMDBRatingLookup.pick(ratings, region: self.region).map(ContentRatingLookup.rated) ?? .unrated)
            }
        }
    }

    // MARK: Answers (pure)

    /// The title `/find` found: a film first.
    static func found(in data: Data) -> (id: Int, isMovie: Bool)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let movie = (object["movie_results"] as? [[String: Any]])?.first, let id = movie["id"] as? Int { return (id, true) }
        if let show = (object["tv_results"] as? [[String: Any]])?.first, let id = show["id"] as? Int { return (id, false) }
        return nil
    }

    /// A film's ratings by country: the first rated release of each.
    static func releaseDates(in data: Data) -> [(country: String, certification: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let country = result["iso_3166_1"] as? String,
                  let rated = (result["release_dates"] as? [[String: Any]])?
                    .compactMap({ $0["certification"] as? String })
                    .first(where: { ContentRating.age(of: $0) != nil }) else { return nil }
            return (country, rated)
        }
    }

    /// A show's ratings by country.
    static func contentRatings(in data: Data) -> [(country: String, certification: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let country = result["iso_3166_1"] as? String, let rating = result["rating"] as? String,
                  ContentRating.age(of: rating) != nil else { return nil }
            return (country, rating)
        }
    }

    /// The US rating, else `region`'s, else the first one understood.
    static func pick(_ ratings: [(country: String, certification: String)], region: String) -> String? {
        let usable = ratings.filter { ContentRating.age(of: $0.certification) != nil }
        return (usable.first { $0.country == "US" } ?? usable.first { $0.country == region } ?? usable.first)?.certification
    }

    // MARK: HTTP

    private func get(_ path: String, key: String, completion: @escaping (Data?) -> Void) {
        let isToken = TMDBKeySettings.kind(of: key) == .readToken
        let separator = path.contains("?") ? "&" : "?"
        guard let url = URL(string: TMDBRatingLookup.base + path + (isToken ? "" : "\(separator)api_key=\(key)")) else {
            return completion(nil)
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let data, error == nil, (200..<300).contains(status) else { return completion(nil) }
            completion(data)
        }.resume()
    }
}
