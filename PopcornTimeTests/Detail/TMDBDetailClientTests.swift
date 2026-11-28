//
//  TMDBDetailClientTests.swift
//  PopcornTimeTests
//
//  What TMDB gives a title's page and a person's page (TMDBDetailClient), on hand-made answers in
//  TMDB's shape (Fixtures/TMDBDetail, tools/tmdb-fixtures.py): the IMDb → TMDB id by /find (asked
//  once), the recommendations (the similar titles when there are none) with their IMDb ids, the
//  cast and crew of a movie and of a show, a person's filmography in TMDB's vote order without
//  talk shows, « Himself » and undated projects, when TMDB is worth asking, and DetailExtras
//  taking TMDB's answer. Nothing reaches TMDB.
//

import Foundation
import XCTest
@testable import PopcornKit

final class TMDBDetailClientTests: CheckedTestCase {

    private let folder = Fixtures.url("TMDBDetail")
    private var requests = TMDBGathered<[String]>([])

    /// A client answering from the fixtures; every path asked is kept in `requests`.
    private func makeClient(answers: Bool = true) -> TMDBDetailClient {
        let streaming = TMDBStreamingClient(ids: TMDBIdCache(file: nil))
        streaming.apiKey = { nil }
        let folder = self.folder, requests = self.requests
        streaming.recorded = { path, completion in
            requests.update { $0.append(path) }
            completion(answers ? TMDBDetailClientTests.answer(to: path, in: folder) : nil)
        }
        return TMDBDetailClient(client: streaming)
    }

    /// "/movie/9100002/credits?language=en-US" → movie_9100002_credits.json; an external_ids
    /// path from external_ids.json; nil when there is no file (TMDB "fails").
    private static func answer(to path: String, in folder: URL) -> Data? {
        let bare = String(path.split(separator: "?").first ?? "")
        let parts = bare.split(separator: "/").map(String.init)
        if parts.count == 3, parts[2] == "external_ids" {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("external_ids.json")),
                  let ids = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return nil }
            let imdb: Any = ids["\(parts[0])/\(parts[1])"] ?? NSNull()
            return try? JSONSerialization.data(withJSONObject: ["id": Int(parts[1]) ?? 0, "imdb_id": imdb])
        }
        return try? Data(contentsOf: folder.appendingPathComponent(parts.joined(separator: "_") + ".json"))
    }

    /// The IMDb ids of the Home fixtures' top movies / shows, in their order (the fixtures'
    /// TMDB ids are 9100000 + n / 9200000 + n).
    private func topIds(_ file: String) -> [String] {
        let data = Fixtures.data("Home/\(file)")
        let metas = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["metas"] as? [[String: Any]] ?? []
        return metas.compactMap { $0["id"] as? String }
    }
    private var movieIds: [String] { topIds("cm_movie_top.json") }
    private var showIds: [String] { topIds("cm_series_top.json") }

    /// Waits for a completion on the main queue.
    private func wait<T>(_ start: (@escaping (T) -> Void) -> Void) -> T? {
        var value: T?
        var called = false
        start { value = $0; called = true }
        check(homeWait(10) { called }, "TMDBDetailClient called back")
        return value
    }

    private var asked: [String] { requests.value }

    // MARK: Related titles

    func testRecommendationsWithTheirImdbIdsWithoutTheTitleItself() {
        let client = makeClient()
        let related = wait { client.related(imdbId: movieIds[2], kind: .movie, completion: $0) } ?? nil
        eq(related?.map(\.id) ?? [], Array(movieIds[4...8]), "TMDB's recommendations in its order, the title left out")
        check(related?.allSatisfy { $0 is Movie } == true, "a movie's recommendations are movies")
        check(related?.first?.title.isEmpty == false, "with their titles")
        check(asked.contains { $0.hasPrefix("/find/\(movieIds[2])?external_source=imdb_id") }, "the TMDB id from /find")
        check(asked.contains("/movie/9100004/external_ids"), "their IMDb ids asked", "\(asked)")
        check(!asked.contains { $0.contains("/similar") }, "no similar titles asked when there are recommendations")
    }

    func testTheSimilarTitlesWhenTMDBRecommendsNothing() {
        let client = makeClient()
        let related = wait { client.related(imdbId: movieIds[3], kind: .movie, completion: $0) } ?? nil
        eq(related?.map(\.id) ?? [], Array(movieIds[10...12]), "the similar titles")
        check(asked.contains { $0.hasPrefix("/movie/9100003/similar") }, "asked after an empty list of recommendations")
    }

    func testAShowsRecommendationsAreShows() {
        let client = makeClient()
        let related = wait { client.related(imdbId: showIds[0], kind: .show, completion: $0) } ?? nil
        eq(related?.map(\.id) ?? [], Array(showIds[1...3]), "the show's recommendations")
        check(related?.allSatisfy { $0 is Show } == true, "shows")
    }

    func testTheTMDBIdIsAskedOnce() {
        let client = makeClient()
        _ = wait { client.related(imdbId: movieIds[2], kind: .movie, completion: $0) }
        _ = wait { client.people(imdbId: movieIds[2], kind: .movie, completion: $0) }
        eq(asked.filter { $0.hasPrefix("/find/") }.count, 1, "one /find for the title's two lists")
    }

    func testATitleTMDBDoesNotKnowOrNoAnswerIsNil() {
        let client = makeClient()
        check(wait { client.related(imdbId: "tt0000404", kind: .movie, completion: $0) }! == nil, "unknown title: no list")
        check(wait { client.people(imdbId: "tt0000404", kind: .movie, completion: $0) }! == nil, "unknown title: no people")
        check(wait { client.related(imdbId: "cinemeta:x", kind: .movie, completion: $0) }! == nil, "not an IMDb id: nothing asked")
        check(!asked.contains { $0.contains("cinemeta") }, "no request for a non-IMDb id")

        let silent = makeClient(answers: false)
        check(wait { silent.related(imdbId: self.movieIds[2], kind: .movie, completion: $0) }! == nil, "no answer: nil")
        check(wait { silent.people(imdbId: self.movieIds[2], kind: .movie, completion: $0) }! == nil, "no answer: nil")
        check(wait { silent.credits(of: Actor(name: "Ada Fictional", imdbId: "tmdb:9300001", tmdbId: 9300001), completion: $0) }! == nil,
              "no answer: nil")
    }

    // MARK: Cast and crew

    func testAMoviesCastAndCrew() {
        let client = makeClient()
        guard let people = wait({ client.people(imdbId: movieIds[2], kind: .movie, completion: $0) }) ?? nil else {
            return XCTFail("no people")
        }
        eq(people.actors.map(\.name), ["Ada Fictional", "Ben Placeholder", "Cy Sample"], "billing order, an actor once")
        eq(people.actors.map(\.characterName), ["Laurie", "Dr. Loomis", ""], "their first role")
        eq(people.actors[0].imdbId, "tmdb:9300001", "a TMDB person's id")
        eq(people.actors[0].tmdbId, 9300001, "and TMDB id")
        eq(people.actors[0].largeImage, "https://image.tmdb.org/t/p/h632/ada.jpg", "the photo in a size TMDB serves profiles in")
        eq(people.actors[0].mediumImage, people.actors[0].largeImage, "the same address for every size")
        check(people.actors[1].largeImage == nil, "no photo: none")
        eq(people.crew.map(\.name), ["Dee Director", "Ed Writer", "Dee Director"], "the director, then the writers")
        eq(people.crew.map(\.roleType), [.director, .writer, .writer], "their roles")
        eq(people.crew.map(\.job), ["Director", "Writer", "Writer"], "their jobs")
        check(!people.crew.contains { $0.name == "Flo Producer" || $0.name == "Gus Editor" }, "no producer, no story editor")
        check(asked.contains { $0.hasPrefix("/movie/9100002/credits") }, "a movie's credits")
    }

    func testAShowsCreatorsAndCast() {
        let client = makeClient()
        guard let people = wait({ client.people(imdbId: showIds[0], kind: .show, completion: $0) }) ?? nil else {
            return XCTFail("no people")
        }
        eq(people.actors.map(\.name), ["Ivy Lead", "Jon Support"], "every season's cast")
        eq(people.actors.map(\.characterName), ["Maeve", "Kevin"], "a role with a name")
        eq(people.crew.map(\.name), ["Hal Creator"], "the creators, not the episodes' directors")
        eq(people.crew.first?.job, "Creator", "as creator")
        eq(people.crew.first?.largeImage, "https://image.tmdb.org/t/p/h632/hal.jpg", "with their photo")
        check(asked.contains { $0.hasPrefix("/tv/9200000?append_to_response=aggregate_credits") }, "one request for both")
    }

    // MARK: A person's titles

    func testAPersonsTitlesByVotesWithoutAppearances() {
        let client = makeClient()
        let titles = wait { client.credits(of: Actor(name: "Ada Fictional", imdbId: "nm9300001"), completion: $0) } ?? nil
        eq(titles?.map(\.id) ?? [], [movieIds[6], showIds[2], movieIds[9], movieIds[5]],
           "most voted first, a title once, no talk show, « Herself », undated project or producer credit")
        check(titles?[1] is Show == true, "movies and shows together")
        check(asked.contains { $0.hasPrefix("/find/nm9300001?external_source=imdb_id") }, "an IMDb person found by /find")
        check(asked.contains { $0.hasPrefix("/person/9300001/combined_credits") }, "their combined credits")
    }

    func testATMDBPersonNeedsNoFind() {
        let client = makeClient()
        let titles = wait { client.credits(of: Actor(name: "Ada Fictional", imdbId: "tmdb:9300001", tmdbId: 9300001), completion: $0) } ?? nil
        eq(titles?.count ?? 0, 4, "the same titles")
        check(!asked.contains { $0.hasPrefix("/find/") }, "no /find")
    }

    func testAppearancesAreNotRoles() {
        for character in ["Self", "Himself", "Herself - Host", "Self (archive footage)", "Themselves"] {
            check(TMDBDetailClient.isSelf(character), "\(character) is an appearance")
        }
        for character in ["Selfie Girl", "Laurie", "", "Dr. Himselfson"] {
            check(!TMDBDetailClient.isSelf(character), "\(character) is a role")
        }
        check(!TMDBDetailClient.isSelf(nil), "no character: kept")
    }

    // MARK: Availability

    func testTMDBIsAskedOnlyWithAKeyItTakes() {
        let none = TMDBStreamingClient(ids: TMDBIdCache(file: nil))
        none.apiKey = { nil }
        check(!TMDBDetailClient(client: none).isAvailable, "no key: not asked")
        check(!TMDBDetailClient(client: none).canShowCredits(of: Actor(name: "Ada", imdbId: "tmdb:1", tmdbId: 1)), "no key: no person page")

        let keyed = TMDBStreamingClient(ids: TMDBIdCache(file: nil))
        keyed.apiKey = { "0123456789abcdef0123456789abcdef" }
        let client = TMDBDetailClient(client: keyed)
        check(client.isAvailable, "a key: asked")
        check(client.canShowCredits(of: Actor(name: "Ada", imdbId: "tmdb:1", tmdbId: 1)), "a TMDB person has a page")
        check(client.canShowCredits(of: Actor(name: "Ada", imdbId: "nm0000001")), "an IMDb person has a page")
        check(!client.canShowCredits(of: Actor(name: "Ada", characterName: "", imdbId: "cinemeta:Ada")), "a Cinemeta name has none")
        check(!client.canShowCredits(of: Actor(name: "Ada", characterName: "", imdbId: "tvmaze:12")), "a TVMaze person has none")

        let refused = TMDBStreamingClient(recordedIn: folder, refusesEveryKey: true)
        check(!TMDBDetailClient(client: refused).isAvailable, "a refused key: not asked")
    }

    // MARK: DetailExtras

    func testThePagesTakeTMDBsAnswer() {
        let client = makeClient()
        let movie = Movie(cinemeta: ["id": movieIds[2], "name": "Halloween"])!
        let related: [Movie]? = wait { DetailExtras.related(movie, tmdb: client, completion: $0) }
        eq(related?.map(\.id) ?? [], Array(movieIds[4...8]), "the page's related titles are TMDB's")
        let people: ([Actor], [Crew])? = wait { done in
            DetailExtras.people(forMediaOfType: .movies, id: self.movieIds[2], tmdb: client) { done(($0, $1)) }
        }
        eq(people?.0.first?.name, "Ada Fictional", "the page's cast is TMDB's")
        eq(people?.1.first?.roleType, .director, "and its crew")
    }
}
