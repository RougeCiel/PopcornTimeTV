import Foundation

// Kids profiles. A kids profile sees only the titles rated for its
// age: the Home, the Movies and Shows grids, Search and the « More Like
// This » of a title's page. A title without a rating is not shown to it —
// what nobody rated is not taken to be for children.
//
// Where the ratings come from:
//   - the title's own source when it gives one (YTS's « mpa_rating », the
//     Popcorn API's « certification »);
//   - TMDB otherwise, with the user's key (`ContentRatingStore`): the US
//     rating first, else the device's country, else any country's. Without
//     a key the sources' ratings are the only ones: a kids profile then sees
//     few titles (its editor says so).

/// The highest rating a kids profile may watch.
public enum ContentRating: String, Codable, CaseIterable, Sendable {
    /// Every age: G, TV-Y, TV-G (France « Tous publics », Germany FSK 0).
    case allAges = "G"
    /// Up to PG: TV-Y7, PG, TV-PG (« -10 », FSK 6).
    case pg = "PG"
    /// Up to PG-13: PG-13, TV-14, « -12 », FSK 12, UK 12A.
    case pg13 = "PG-13"

    /// A new kids profile's.
    public static let `default` = ContentRating.pg

    /// The oldest age of the ratings it lets through.
    public var maxAge: Int {
        switch self {
        case .allAges: return 0
        case .pg: return 10
        case .pg13: return 13
        }
    }

    /// The age a certification is for, in any of the systems the sources
    /// use (US films and TV, the UK, France, Germany, Canada, Brazil,
    /// Australia, and plain ages: « 12 », « 16+ », « -12 »); nil for none
    /// or one not known (« Unrated », « Not Rated », « Approved », « »).
    public static func age(of certification: String) -> Int? {
        var value = certification.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !value.isEmpty else { return nil }
        // « FSK 12 », « FSK12 », « TV-Y7-FV », « Rated PG-13 ».
        for prefix in ["RATED ", "FSK", "BBFC "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if value.hasSuffix("-FV") { value = String(value.dropLast(3)) }
        if let age = named[value] { return age }
        // Plain ages: « 12 », « 16+ », « -12 », « 12A », « 14A », « 18+ ».
        let digits = value.drop { $0 == "-" || $0 == "+" }.prefix { $0.isNumber }
        guard let number = Int(digits), number <= 21 else { return nil }
        let rest = value.drop { $0 == "-" || $0 == "+" }.dropFirst(digits.count)
        guard rest.isEmpty || ["+", "A", "R", " ANS", "+ ANS"].contains(String(rest)) else { return nil }
        return number
    }

    /// Whether a title rated `certification` is within this rating.
    public func admits(_ certification: String) -> Bool {
        guard let age = ContentRating.age(of: certification) else { return false }
        return age <= maxAge
    }

    /// The names of the ratings (the plain ages are read as numbers).
    private static let named: [String: Int] = [
        // United States, films (MPA) and television.
        "G": 0, "TV-Y": 0, "TV-G": 0,
        "TV-Y7": 7,
        "PG": 10, "TV-PG": 10,
        "PG-13": 13, "TV-14": 13,
        "R": 17, "NC-17": 18, "TV-MA": 17, "X": 18, "NR-17": 17,
        // United Kingdom (BBFC), Ireland, Australia, Canada, Brazil, Spain…
        "U": 0, "UC": 0, "E": 0, "L": 0, "LIVRE": 0, "ALL": 0, "AL": 0, "TP": 0, "A.L.": 0, "APTA": 0,
        "TE+7": 7, "7+": 7, "7I": 7,
        "M": 15, "MA15+": 15, "MA": 17, "R18+": 18, "R16": 16, "R13": 13,
        "14A": 14, "18A": 18,
        // France (CNC): « Tous publics », « Interdit aux moins de 12 ans ».
        "TOUS PUBLICS": 0,
    ]
}

/// What a kids profile may see: the titles rated up to `maxRating`.
public struct ContentRestriction: Sendable, Equatable, Hashable {
    public let maxRating: ContentRating

    public init(maxRating: ContentRating) {
        self.maxRating = maxRating
    }

    /// The active profile's: nil for a profile that is not a kids one.
    public static var current: ContentRestriction? {
        return ProfileManager.shared.active.restriction
    }

    /// Whether the title `imdbId` may be shown: its own `certification`
    /// when its source gave one (kept in `store` for the other screens),
    /// else the one `store` knows. Not known: not shown, and asked for
    /// (`ContentRatingStore.didChangeNotification` once it is known).
    public func admits(imdbId: String, certification: String? = nil, store: ContentRatingStore = .shared) -> Bool {
        if let certification, ContentRating.age(of: certification) != nil {
            store.record(certification, for: imdbId)
            return maxRating.admits(certification)
        }
        if let known = store.certification(of: imdbId) { return maxRating.admits(known) }
        store.ask([imdbId])
        return false
    }

    public func admitted(_ movies: [Movie], store: ContentRatingStore = .shared) -> [Movie] {
        return movies.filter { admits(imdbId: $0.id, certification: $0.certification, store: store) }
    }

    public func admitted(_ shows: [Show], store: ContentRatingStore = .shared) -> [Show] {
        return shows.filter { admits(imdbId: $0.id, store: store) }
    }

    /// The ratings a list lacks: the ids neither its titles nor `store` rate.
    static func unrated(_ ids: [(id: String, certification: String?)], store: ContentRatingStore) -> [String] {
        return ids.filter { entry in
            !(entry.certification.map { ContentRating.age(of: $0) != nil } ?? false) && store.certification(of: entry.id) == nil
        }.map(\.id)
    }

    /// Delivers `movies` admitted, once the ratings they lack were asked
    /// (`wait` seconds at most: a title still unrated then is left out).
    /// Main queue.
    public func admit(_ movies: [Movie], store: ContentRatingStore = .shared, wait: TimeInterval = ContentRatingStore.listWait,
                      completion: @escaping ([Movie]) -> Void) {
        let missing = ContentRestriction.unrated(movies.map { ($0.id, $0.certification) }, store: store)
        store.resolve(missing, timeout: wait) { completion(self.admitted(movies, store: store)) }
    }

    public func admit(_ shows: [Show], store: ContentRatingStore = .shared, wait: TimeInterval = ContentRatingStore.listWait,
                      completion: @escaping ([Show]) -> Void) {
        let missing = ContentRestriction.unrated(shows.map { ($0.id, nil) }, store: store)
        store.resolve(missing, timeout: wait) { completion(self.admitted(shows, store: store)) }
    }
}

/// Answers delivered in the order they were started, each once the work
/// before it is done: a list's saved first page, then the network's, even
/// when the first one's ratings take longer to come. Main queue.
final class InOrderDeliveries {
    private var previous: DispatchGroup?

    /// `body` runs once the deliveries started before it are done; it calls
    /// `done` when its own is.
    func run(_ body: @escaping (_ done: @escaping () -> Void) -> Void) {
        let group = DispatchGroup()
        group.enter()
        let before = previous
        previous = group
        let start = { body { group.leave() } }
        if let before { before.notify(queue: .main, execute: start) } else { start() }
    }
}

public extension ContentRestriction {

    /// A list's answers for the active profile: the titles it may see, the
    /// saved first page (`snapshot`) still before the network's. Unchanged
    /// for a profile that is not a kids one. Main queue.
    static func restricting<Item>(snapshot: (([Item]) -> Void)?,
                                  completion: @escaping ([Item]?, NSError?) -> Void,
                                  admit: @escaping (ContentRestriction, [Item], @escaping ([Item]) -> Void) -> Void)
        -> (snapshot: (([Item]) -> Void)?, completion: ([Item]?, NSError?) -> Void) {
        guard let restriction = current else { return (snapshot, completion) }
        let order = InOrderDeliveries()
        let restrictedSnapshot = snapshot.map { snapshot in
            { (items: [Item]) in
                DispatchQueue.main.async {
                    order.run { done in admit(restriction, items) { snapshot($0); done() } }
                }
            }
        }
        let restrictedCompletion = { (items: [Item]?, error: NSError?) in
            DispatchQueue.main.async {
                order.run { done in
                    guard let items else { completion(nil, error); return done() }
                    admit(restriction, items) { completion($0, error); done() }
                }
            }
        }
        return (restrictedSnapshot, restrictedCompletion)
    }

    /// A search's answer for the active profile (see `restricting`).
    static func restrictingSearch<Item>(_ completion: @escaping ([Item]?, NSError?, Bool) -> Void,
                                        admit: @escaping (ContentRestriction, [Item], @escaping ([Item]) -> Void) -> Void)
        -> ([Item]?, NSError?, Bool) -> Void {
        guard let restriction = current else { return completion }
        return { items, error, partial in
            DispatchQueue.main.async {
                guard let items else { return completion(nil, error, partial) }
                admit(restriction, items) { completion($0, error, partial) }
            }
        }
    }
}

public extension ContentRestriction {

    /// Cards (a service's catalogue) the active profile may see, once the
    /// ratings they lack were asked; all of them for a profile that is not
    /// a kids one, at once. Any queue.
    static func admit(_ items: [HomeItem], store: ContentRatingStore = .shared, completion: @escaping ([HomeItem]) -> Void) {
        guard let restriction = current else { return completion(items) }
        let missing = unrated(items.map { ($0.imdbId, nil) }, store: store)
        store.resolve(missing, timeout: ContentRatingStore.listWait) {
            completion(items.filter { restriction.admits(imdbId: $0.imdbId, store: store) })
        }
    }
}
