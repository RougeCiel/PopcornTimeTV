import Foundation

/// What a title's page shows under its first screen: related titles, cast
/// and crew. With the user's TMDB key they come from TMDB
/// (`TMDBDetailClient`: recommendations, credits with photos, people
/// whose page can open). Without a key, or when TMDB does not answer or
/// has nothing, from the keyless sources (`OpenMetadata`: YTS, Cinemeta,
/// TVMaze) — or Trakt when a Trakt account is connected, which falls back
/// to the same sources when it fails. A section with nothing stays hidden.
public enum DetailExtras {

    /// Titles to suggest next to `media`, on the main queue.
    public static func related<T: Media>(_ media: T, completion: @escaping ([T]) -> Void) {
        related(media, tmdb: .shared, completion: completion)
    }

    static func related<T: Media>(_ media: T, tmdb: TMDBDetailClient, completion: @escaping ([T]) -> Void) {
        let fallback = {
            guard TraktManager.shared.isSignedIn(), !TraktManager.anonymousAccessRefused else {
                return OpenMetadata.related(media) { related in completion(related.compactMap { $0 as? T }) }
            }
            TraktManager.shared.getRelated(media) { related, _ in completion(related) }
        }
        guard tmdb.isAvailable, let kind = kind(of: media) else { return fallback() }
        tmdb.related(imdbId: media.id, kind: kind) { related in
            let titles = (related ?? []).compactMap { $0 as? T }
            titles.isEmpty ? fallback() : completion(titles)
        }
    }

    /// Cast and crew of a movie (`.movies`) or a show (`.shows`).
    public static func people(forMediaOfType type: Trakt.MediaType, id: String,
                              completion: @escaping ([Actor], [Crew]) -> Void) {
        people(forMediaOfType: type, id: id, tmdb: .shared, completion: completion)
    }

    static func people(forMediaOfType type: Trakt.MediaType, id: String, tmdb: TMDBDetailClient,
                       completion: @escaping ([Actor], [Crew]) -> Void) {
        let fallback = {
            guard TraktManager.shared.isSignedIn(), !TraktManager.anonymousAccessRefused else {
                return OpenMetadata.people(forMediaOfType: type, id: id, completion: completion)
            }
            TraktManager.shared.getPeople(forMediaOfType: type, id: id) { actors, crew, _ in completion(actors, crew) }
        }
        let kind: HomeItem.Kind? = type == .movies ? .movie : type == .shows ? .show : nil
        guard tmdb.isAvailable, let kind else { return fallback() }
        tmdb.people(imdbId: id, kind: kind) { people in
            guard let people, !people.actors.isEmpty || !people.crew.isEmpty else { return fallback() }
            completion(people.actors, people.crew)
        }
    }

    /// Can `person`'s page (their titles) be filled: a TMDB person, or one
    /// with an IMDb id, while TMDB is available. The keyless sources'
    /// people ("cinemeta:…", "tvmaze:…") have no page.
    public static func hasPage(_ person: Person) -> Bool {
        return TMDBDetailClient.shared.canShowCredits(of: person)
    }

    /// The titles of `person`'s page, on the main queue; nil when TMDB did
    /// not answer (the page says it found nothing).
    public static func titles(of person: Person, completion: @escaping ([Media]?) -> Void) {
        TMDBDetailClient.shared.credits(of: person, completion: completion)
    }

    private static func kind(of media: Media) -> HomeItem.Kind? {
        if media is Movie { return .movie }
        if media is Show { return .show }
        return nil
    }
}
