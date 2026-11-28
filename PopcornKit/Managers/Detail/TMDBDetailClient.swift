import Foundation

/// What TMDB adds under a title's first screen, with the user's TMDB key
/// (the one of the streaming services, `HomeSettings.tmdbAPIKey`): the
/// titles to suggest, the cast and crew with their photos, and a person's
/// filmography (their page). Trakt gave these until it refused the app's
/// key; the keyless sources (`OpenMetadata`) still stand in without a key.
///
/// - TMDB knows titles and people by TMDB ids, the app titles by IMDb ids:
///   a title's TMDB id comes from `/find/{imdb}`, kept in memory; the
///   titles TMDB lists are given their IMDb ids by the streaming client
///   (`withImdbIds`, kept on disk), and the ones without are left out.
/// - A person from TMDB is an `Actor` / `Crew` whose `tmdbId` is TMDB's and
///   whose `imdbId` is "tmdb:<id>" (TMDB's credits carry no IMDb id).
/// - Requests go through `TMDBStreamingClient`: the same key in the query
///   or the header, the same refusal noted, the same recorded answers in a
///   DEBUG fixture run.
/// - Every completion runs on the main queue; nil means TMDB did not
///   answer (no key, refused, offline): the caller falls back.
public final class TMDBDetailClient: @unchecked Sendable {

    public static let shared = TMDBDetailClient(client: .shared)

    /// Suggested titles a page shows at most.
    static let relatedLimit = 20
    /// Actors a page lists at most (TMDB lists a hundred for some films).
    static let castLimit = 30
    /// Titles a person's page shows at most: each one new to the app costs
    /// an external-ids request the first time.
    static let filmographyLimit = 40

    /// TV genres of appearances that are not roles: talk shows, news, reality.
    static let appearanceGenres: Set<Int> = [10763, 10764, 10767]

    let client: TMDBStreamingClient
    /// "movie:tt0468569" → 155; "person:nm0000288" → 3894.
    private let found = TMDBGathered<[String: Int]>([:])

    init(client: TMDBStreamingClient) {
        self.client = client
    }

    /// A key is stored (or a fixture run answers) and TMDB has not refused
    /// it: TMDB is worth asking.
    public var isAvailable: Bool {
        if client.recorded != nil { return !client.refusesEveryKey }
        guard client.apiKey() != nil else { return false }
        return !client.isKeyRefused
    }

    /// Can a person's page be filled for this person: TMDB is available and
    /// the person is known to TMDB (a TMDB id) or to IMDb ("nm…").
    public func canShowCredits(of person: Person) -> Bool {
        return isAvailable && (TMDBDetailClient.personId(of: person) != nil || person.imdbId.hasPrefix("nm"))
    }

    // MARK: Related titles

    /// TMDB's recommendations for the title (its « similar » titles when it
    /// has none), each with its IMDb id, without the title itself.
    public func related(imdbId: String, kind: HomeItem.Kind, completion: @escaping ([Media]?) -> Void) {
        let done = TMDBDetailClient.onMain(completion)
        tmdbId(imdbId: imdbId, kind: kind) { id in
            guard let id else { return done(nil) }
            let base = "/\(TMDBDetailClient.segment(kind))/\(id)"
            self.results(base + "/recommendations?language=\(TMDBStreamingClient.language)&page=1") { results in
                guard let results else { return done(nil) }
                let finish: ([[String: Any]]) -> Void = { results in
                    self.media(results, kind: kind) { media in
                        done(media.map { Array($0.map(\.media).filter { $0.id != imdbId }.prefix(TMDBDetailClient.relatedLimit)) })
                    }
                }
                guard results.isEmpty else { return finish(results) }
                self.results(base + "/similar?language=\(TMDBStreamingClient.language)&page=1") { similar in
                    guard let similar else { return done(nil) }
                    finish(similar)
                }
            }
        }
    }

    // MARK: Cast and crew

    /// The title's cast in billing order (a show's: every season's, the
    /// most episodes first, as TMDB orders them), then its directors,
    /// writers and, for a show, its creators.
    public func people(imdbId: String, kind: HomeItem.Kind, completion: @escaping (_ people: (actors: [Actor], crew: [Crew])?) -> Void) {
        let done = TMDBDetailClient.onMain(completion)
        tmdbId(imdbId: imdbId, kind: kind) { id in
            guard let id else { return done(nil) }
            let path = kind == .movie
                ? "/movie/\(id)/credits?language=\(TMDBStreamingClient.language)"
                : "/tv/\(id)?append_to_response=aggregate_credits&language=\(TMDBStreamingClient.language)"
            self.client.get(path) { data in
                guard let root = TMDBDetailClient.object(data) else { return done(nil) }
                done(TMDBDetailClient.people(root, kind: kind))
            }
        }
    }

    /// The cast and crew of a `/movie/{id}/credits` answer, or of a
    /// `/tv/{id}?append_to_response=aggregate_credits` one.
    static func people(_ root: [String: Any], kind: HomeItem.Kind) -> (actors: [Actor], crew: [Crew]) {
        let credits = kind == .movie ? root : (root["aggregate_credits"] as? [String: Any] ?? [:])
        var actors: [Actor] = []
        var seen = Set<Int>()
        for entry in credits["cast"] as? [[String: Any]] ?? [] {
            guard let id = int(entry["id"]), let name = text(entry["name"]), seen.insert(id).inserted else { continue }
            // A show's actor: their roles of every season, the main one first.
            let roles = (entry["roles"] as? [[String: Any]] ?? []).compactMap { text($0["character"]) }
            let character = text(entry["character"]) ?? roles.first ?? ""
            actors.append(Actor(name: name, characterName: character, imdbId: "tmdb:\(id)", tmdbId: id,
                                largeImage: profile(entry["profile_path"])))
            if actors.count == castLimit { break }
        }

        var crew: [Crew] = []
        var seenCrew = Set<String>()
        func add(_ entry: [String: Any], job: String, role: Role) {
            guard let id = int(entry["id"]), let name = text(entry["name"]), seenCrew.insert("\(role.rawValue):\(id)").inserted else { return }
            crew.append(Crew(name: name, job: job, roleType: role, imdbId: "tmdb:\(id)", tmdbId: id,
                             largeImage: profile(entry["profile_path"])))
        }
        if kind == .show {
            for creator in root["created_by"] as? [[String: Any]] ?? [] { add(creator, job: "Creator".localized, role: .writer) }
        }
        let members = credits["crew"] as? [[String: Any]] ?? []
        func jobs(_ entry: [String: Any]) -> [String] {
            return text(entry["job"]).map { [$0] } ?? []
        }
        // A show's directors and writers are its episodes' (dozens): a
        // show lists its creators, a movie its directors and writers.
        if kind == .movie {
            for entry in members where jobs(entry).contains("Director") { add(entry, job: "Director".localized, role: .director) }
            for entry in members where !Set(jobs(entry)).isDisjoint(with: writingJobs) { add(entry, job: "Writer".localized, role: .writer) }
        }
        return (actors, crew)
    }

    /// A movie's writing credits that name its writers (not « Story
    /// Editor », « Script Consultant »…).
    static let writingJobs: Set<String> = ["Screenplay", "Writer", "Story", "Novel", "Author", "Original Story", "Characters"]

    // MARK: A person's titles

    /// The titles a person played in, directed or wrote, the most watched
    /// first (TMDB's vote count): movies and shows together, without talk
    /// shows, news, reality TV and the titles they only appear in as
    /// themselves, nor the ones not dated yet.
    public func credits(of person: Person, completion: @escaping ([Media]?) -> Void) {
        let done = TMDBDetailClient.onMain(completion)
        personId(of: person) { id in
            guard let id else { return done(nil) }
            self.client.get("/person/\(id)/combined_credits?language=\(TMDBStreamingClient.language)") { data in
                guard let root = TMDBDetailClient.object(data) else { return done(nil) }
                let picked = TMDBDetailClient.filmography(root)
                let group = DispatchGroup()
                let found = TMDBGathered<[String: Media]>([:])
                let answered = TMDBGathered(false)
                for kind in HomeItem.Kind.allCases {
                    let results = picked.filter { $0.kind == kind }.map(\.result)
                    guard !results.isEmpty else { continue }
                    group.enter()
                    self.media(results, kind: kind) { media in
                        if let media {
                            answered.update { $0 = true }
                            found.update { for (id, title) in media { $0["\(kind):\(id)"] = title } }
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .global(qos: .userInitiated)) {
                    // Nothing to look up is an answer: a person with no title.
                    guard answered.value || picked.isEmpty else { return done(nil) }
                    // Back in the vote order, movies and shows mixed.
                    let titles = found.value
                    var seen = Set<String>()
                    done(picked.compactMap { entry -> Media? in
                        guard let id = TMDBDetailClient.int(entry.result["id"]), let media = titles["\(entry.kind):\(id)"],
                              seen.insert(media.id).inserted else { return nil }
                        return media
                    })
                }
            }
        }
    }

    /// The entries of a `/person/{id}/combined_credits` answer worth a
    /// card, by kind, the most voted first, one per title, at most
    /// `filmographyLimit`.
    static func filmography(_ root: [String: Any]) -> [(kind: HomeItem.Kind, result: [String: Any])] {
        var entries: [(kind: HomeItem.Kind, result: [String: Any])] = []
        var seen = Set<String>()
        let cast = (root["cast"] as? [[String: Any]] ?? []).filter { !isSelf(text($0["character"])) }
        let crew = (root["crew"] as? [[String: Any]] ?? []).filter {
            let department = text($0["department"])
            return department == "Directing" || department == "Writing" || text($0["job"]) == "Creator"
        }
        for entry in cast + crew {
            let kind: HomeItem.Kind
            switch text(entry["media_type"]) {
            case "movie": kind = .movie
            case "tv": kind = .show
            default: continue
            }
            let genres = Set((entry["genre_ids"] as? [Any] ?? []).compactMap(int))
            guard let id = int(entry["id"]), genres.isDisjoint(with: appearanceGenres),
                  text(entry[kind == .movie ? "release_date" : "first_air_date"]) != nil,
                  seen.insert("\(kind):\(id)").inserted else { continue }
            entries.append((kind, entry))
        }
        let votes: ([String: Any]) -> Int = { int($0["vote_count"]) ?? 0 }
        let ranked = entries.enumerated().sorted {
            votes($0.element.result) != votes($1.element.result) ? votes($0.element.result) > votes($1.element.result) : $0.offset < $1.offset
        }.map(\.element)
        return Array(ranked.prefix(filmographyLimit))
    }

    /// « Self », « Himself », « Herself - Host »…: an appearance, not a role.
    static func isSelf(_ character: String?) -> Bool {
        guard let character = character?.lowercased() else { return false }
        let words = character.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { ["self", "himself", "herself", "themselves", "themself"].contains($0) }
    }

    // MARK: Ids

    /// The person's TMDB id when it is already known (a TMDB person, or
    /// any person with a TMDB id).
    static func personId(of person: Person) -> Int? {
        if person.tmdbId > 0 { return person.tmdbId }
        if person.imdbId.hasPrefix("tmdb:"), let id = Int(person.imdbId.dropFirst(5)), id > 0 { return id }
        return nil
    }

    private func personId(of person: Person, completion: @escaping (Int?) -> Void) {
        if let id = TMDBDetailClient.personId(of: person) { return completion(id) }
        guard person.imdbId.hasPrefix("nm") else { return completion(nil) }
        find(person.imdbId, field: "person_results", key: "person:\(person.imdbId)", completion: completion)
    }

    /// The title's TMDB id, from `/find` (kept in memory).
    func tmdbId(imdbId: String, kind: HomeItem.Kind, completion: @escaping (Int?) -> Void) {
        guard HomeParse.isImdbId(imdbId) else { return completion(nil) }
        find(imdbId, field: kind == .movie ? "movie_results" : "tv_results", key: "\(kind):\(imdbId)", completion: completion)
    }

    private func find(_ imdbId: String, field: String, key: String, completion: @escaping (Int?) -> Void) {
        if let id = found.value[key] { return completion(id) }
        client.get("/find/\(imdbId)?external_source=imdb_id") { data in
            let id = (TMDBDetailClient.object(data)?[field] as? [[String: Any]])?.first.flatMap { TMDBDetailClient.int($0["id"]) }
            if let id { self.found.update { $0[key] = id } }
            completion(id)
        }
    }

    // MARK: Answers

    /// The "results" of a page, nil when TMDB did not answer.
    private func results(_ path: String, completion: @escaping ([[String: Any]]?) -> Void) {
        client.get(path) { data in
            guard let root = TMDBDetailClient.object(data) else { return completion(nil) }
            completion(root["results"] as? [[String: Any]] ?? [])
        }
    }

    /// TMDB's results as the app's movies or shows, in their order: the
    /// ones with an IMDb id (a lookup that got no answer leaves its title out).
    private func media(_ results: [[String: Any]], kind: HomeItem.Kind, completion: @escaping ([(tmdbId: Int, media: Media)]?) -> Void) {
        client.withImdbIds(results, kind: kind) { resolved, failed in
            if resolved.isEmpty && failed > 0 { return completion(nil) }
            completion(resolved.compactMap { result in
                guard let id = TMDBDetailClient.int(result["id"]), let media = HomeParse.tmdbEntry(result, kind: kind)?.item.media else { return nil }
                return (id, media)
            })
        }
    }

    private static func onMain<T>(_ completion: @escaping (T) -> Void) -> (T) -> Void {
        return { value in DispatchQueue.main.async { completion(value) } }
    }

    static func object(_ data: Data?) -> [String: Any]? {
        return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func segment(_ kind: HomeItem.Kind) -> String {
        return kind == .movie ? "movie" : "tv"
    }

    static func int(_ value: Any?) -> Int? {
        return (value as? NSNumber)?.intValue
    }

    static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A profile photo's address (TMDB's 632-pixel-high size: the sizes a
    /// profile is served in are w45, w185, h632 and original).
    static func profile(_ value: Any?) -> String? {
        return text(value).map { "https://image.tmdb.org/t/p/h632" + $0 }
    }
}
