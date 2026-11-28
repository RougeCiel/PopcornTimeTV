//
//  KidsProfileTests.swift
//  PopcornTimeTests
//
//  Kids profiles and profile PINs: the ratings read from every system the sources use,
//  what a kids profile is let see (a title without a rating is not), the ratings store (the
//  sources' ratings, TMDB's answers, the waits), the Home and the grids filtered, the profiles
//  saved by 5.5.0 and earlier read as profiles for everyone, and the PIN: four digits, stored hashed only,
//  checked. No network, no keychain, no real clock.
//

import Foundation
import XCTest
@testable import PopcornKit

final class KidsProfileTests: CheckedTestCase {

    private typealias F = LibraryFixtures

    private final class Ids {
        var next = 0
        func make() -> String { next += 1; return "p\(next)" }
    }

    private func manager(_ storage: MemoryLibraryStorage, center: NotificationCenter = NotificationCenter()) -> ProfileManager {
        let clock = F.Clock("2026-11-28T12:00:00Z")
        let ids = Ids()
        return ProfileManager(storage: storage, defaultName: "Me", center: center, makeID: ids.make, now: { clock.now },
                              eraseExternal: { _ in })
    }

    /// A store that answers from a dictionary at once (no entry: unrated).
    private func store(_ ratings: [String: String] = [:], asked: Asked? = nil,
                       center: NotificationCenter = NotificationCenter()) -> ContentRatingStore {
        return ContentRatingStore(fileURL: nil, lookup: { id, done in
            asked?.ids.append(id)
            done(ratings[id].map(ContentRatingLookup.rated) ?? .unrated)
        }, center: center)
    }

    private final class Asked {
        var ids: [String] = []
    }

    private func movie(_ id: String, rated certification: String) -> Movie {
        return Movie(yts: ["imdb_code": id, "title": id, "mpa_rating": certification])!
    }

    private func wait(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    // MARK: - Ratings

    func testTheRatingsOfEverySystemTheSourcesUse() {
        let ages: [(String, Int?)] = [
            ("G", 0), ("TV-Y", 0), ("TV-G", 0), ("U", 0), ("Livre", 0), ("All", 0), ("0", 0), ("FSK 0", 0), ("Tous publics", 0),
            ("TV-Y7", 7), ("TV-Y7-FV", 7), ("TE+7", 7),
            ("PG", 10), ("TV-PG", 10), ("10", 10),
            ("12", 12), ("12A", 12), ("-12", 12), ("FSK12", 12),
            ("PG-13", 13), ("TV-14", 13), ("13", 13), ("14A", 14),
            ("15", 15), ("M", 15), ("16+", 16),
            ("R", 17), ("TV-MA", 17), ("NC-17", 18), ("18", 18), ("Rated R", 17),
            ("", nil), ("Unrated", nil), ("Not Rated", nil), ("NR", nil), ("Approved", nil), ("N/A", nil), ("A", nil), ("99", nil),
        ]
        for (certification, age) in ages {
            eq(ContentRating.age(of: certification), age, "« \(certification) »")
        }
    }

    func testWhatEachMaximumRatingLetsThrough() {
        check(ContentRating.allAges.admits("G") && ContentRating.allAges.admits("TV-Y"), "all ages: G, TV-Y")
        check(!ContentRating.allAges.admits("TV-Y7") && !ContentRating.allAges.admits("PG"), "all ages: not TV-Y7 nor PG")
        check(ContentRating.pg.admits("PG") && ContentRating.pg.admits("TV-Y7") && ContentRating.pg.admits("G"), "PG: PG, TV-Y7, G")
        check(!ContentRating.pg.admits("PG-13") && !ContentRating.pg.admits("12"), "PG: not PG-13 nor 12")
        check(ContentRating.pg13.admits("PG-13") && ContentRating.pg13.admits("TV-14") && ContentRating.pg13.admits("12A"),
              "PG-13: PG-13, TV-14, 12A")
        check(!ContentRating.pg13.admits("R") && !ContentRating.pg13.admits("16") && !ContentRating.pg13.admits("TV-MA"),
              "PG-13: not R, 16, TV-MA")
        for rating in ContentRating.allCases {
            check(!rating.admits("") && !rating.admits("Unrated"), "\(rating): a title without a rating is not shown")
        }
        eq(ContentRating.default, .pg, "a new kids profile: up to PG")
    }

    // MARK: - What a kids profile sees

    func testATitleWithoutARatingIsNotShownAndIsAskedFor() {
        let asked = Asked()
        let ratings = store(["tt3": "PG"], asked: asked)
        let restriction = ContentRestriction(maxRating: .pg)
        check(restriction.admits(imdbId: "tt1", certification: "G", store: ratings), "rated by its source: G")
        check(!restriction.admits(imdbId: "tt2", certification: "R", store: ratings), "rated by its source: R")
        check(!restriction.admits(imdbId: "tt3", store: ratings), "not rated yet: not shown")
        check(wait { asked.ids == ["tt3"] }, "…and asked for (the sources' ratings are not)")
        check(wait { ratings.certification(of: "tt3") == "PG" }, "the answer is kept")
        check(restriction.admits(imdbId: "tt3", store: ratings), "then shown")
        eq(ratings.certification(of: "tt1"), "G", "a source's rating is kept for the other screens")
        check(!restriction.admits(imdbId: "tt4", certification: "Not Rated", store: ratings), "« Not Rated » is no rating")
    }

    func testAListWaitsForTheRatingsItLacksThenKeepsWhatIsRatedForTheProfile() {
        let ratings = store(["tt10": "PG", "tt11": "R", "tt12": "TV-Y"])
        let restriction = ContentRestriction(maxRating: .pg)
        let movies = [movie("tt1", rated: "G"), movie("tt2", rated: "PG-13"), movie("tt10", rated: ""),
                      movie("tt11", rated: "Unrated"), movie("tt13", rated: "")]
        var admitted: [String]?
        restriction.admit(movies, store: ratings, wait: 2) { admitted = $0.map(\.id) }
        check(wait { admitted != nil }, "the list is delivered")
        eq(admitted, ["tt1", "tt10"], "G from YTS, PG from TMDB; not PG-13, R, nor a title nobody rated")

        let shows = [Show(id: "tt12"), Show(id: "tt11"), Show(id: "tt14")]
        var admittedShows: [String]?
        restriction.admit(shows, store: ratings, wait: 2) { admittedShows = $0.map(\.id) }
        check(wait { admittedShows != nil }, "the shows are delivered")
        eq(admittedShows, ["tt12"], "the shows rated from TMDB")
    }

    func testAListIsNotHeldLongerThanItsWait() {
        // A lookup that never answers.
        let ratings = ContentRatingStore(fileURL: nil, lookup: { _, _ in })
        var admitted: [Movie]?
        let start = Date()
        ContentRestriction(maxRating: .pg).admit([movie("tt1", rated: "")], store: ratings, wait: 0.2) { admitted = $0 }
        check(wait { admitted != nil }, "delivered after the wait")
        check(Date().timeIntervalSince(start) < 1.5, "not later")
        eq(admitted?.count, 0, "a title still unrated is left out")
    }

    func testTheStoreAnnouncesTheRatingsItLearnsAndAsksAnUnratedTitleOnlyOnce() {
        let center = NotificationCenter()
        let asked = Asked()
        let ratings = store(["tt1": "PG"], asked: asked, center: center)
        var posts = 0
        let token = center.addObserver(forName: ContentRatingStore.didChangeNotification, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        ratings.ask(["tt1", "tt2"])
        check(wait { posts == 1 }, "one notification for the burst")
        ratings.ask(["tt1", "tt2"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        eq(asked.ids.sorted(), ["tt1", "tt2"], "a rated title and an unrated one are not asked again")
    }

    func testWithoutAKeyNothingIsKeptAndTheListIsNotHeld() {
        let ratings = ContentRatingStore(fileURL: nil, lookup: { _, done in done(.unavailable) })
        var admitted: [Movie]?
        ContentRestriction(maxRating: .pg13).admit([movie("tt1", rated: "PG"), movie("tt2", rated: "")],
                                                   store: ratings, wait: 5) { admitted = $0 }
        check(wait(1) { admitted != nil }, "delivered at once")
        eq(admitted?.map(\.id), ["tt1"], "only what the source rated")
    }

    func testTheStoreKeepsItsRatingsOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ratings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ContentRatings.json")
        let first = ContentRatingStore(fileURL: file, lookup: { _, done in done(.rated("TV-Y7")) })
        first.ask(["tt1"])
        check(wait(5) { FileManager.default.fileExists(atPath: file.path) }, "saved")
        let second = ContentRatingStore(fileURL: file, lookup: { _, done in done(.failed) })
        eq(second.certification(of: "tt1"), "TV-Y7", "read back")
    }

    func testTMDBsAnswersAreRead() {
        let find = #"{"movie_results":[],"tv_results":[{"id":1399}]}"#.data(using: .utf8)!
        check(TMDBRatingLookup.found(in: find)! == (1399, false), "a show found")
        check(TMDBRatingLookup.found(in: #"{"movie_results":[],"tv_results":[]}"#.data(using: .utf8)!) == nil, "nothing found")
        let releases = #"{"results":[{"iso_3166_1":"FR","release_dates":[{"certification":"","type":3},{"certification":"U","type":3}]},{"iso_3166_1":"US","release_dates":[{"certification":"PG","type":3}]}]}"#
        let movieRatings = TMDBRatingLookup.releaseDates(in: releases.data(using: .utf8)!)
        eq(TMDBRatingLookup.pick(movieRatings, region: "FR"), "PG", "the US rating first")
        let shows = #"{"results":[{"iso_3166_1":"DE","rating":"12"},{"iso_3166_1":"FR","rating":"10"}]}"#
        let showRatings = TMDBRatingLookup.contentRatings(in: shows.data(using: .utf8)!)
        eq(TMDBRatingLookup.pick(showRatings, region: "FR"), "10", "else the device's country")
        eq(TMDBRatingLookup.pick(showRatings, region: "IT"), "12", "else the first one")
        eq(TMDBRatingLookup.pick([], region: "US"), nil, "none")
    }

    // MARK: - The Home and the grids

    func testTheHomeShowsAKidsProfileOnlyTheTitlesRatedForIt() {
        let lists = HomeFixture.allLists()
        let all = HomeBuilder.shelves(HomeFixture.inputs(lists))
        let ids = Set(all.flatMap(\.items).map(\.imdbId))
        check(ids.count > 10, "a full page to filter")
        let allowed = Set(ids.sorted().enumerated().filter { $0.offset % 3 == 0 }.map(\.element))
        var inputs = HomeFixture.inputs(lists)
        inputs.admits = { allowed.contains($0.imdbId) }
        let filtered = HomeBuilder.shelves(inputs)
        let shown = Set(filtered.flatMap(\.items).map(\.imdbId))
        check(!shown.isEmpty, "titles are left")
        check(shown.isSubset(of: allowed), "only the titles let through, on every shelf and the hero")
        check(filtered.allSatisfy { !$0.items.isEmpty }, "no empty shelf")
    }

    func testAKidsGridGoesPastAPageWithNothingForIt() {
        var pager = CatalogPager<String> { $0 }
        pager.isRestricted = true
        let first = pager.reset()
        pager.receive(.success(["a"]), for: first)
        let second = pager.next()!
        let outcome = pager.receive(.success([]), for: second)
        eq(outcome, .continueWith(CatalogPager<String>.Request(page: 3, generation: first.generation, isRefresh: false)),
           "an empty page is not the end: the next one is asked")
        check(pager.hasMore, "more to come")

        var plain = CatalogPager<String> { $0 }
        let request = plain.reset()
        pager = plain
        pager.receive(.success([]), for: request)
        check(!pager.hasMore, "for another profile an empty page is still the end")
    }

    // MARK: - Profiles

    func testAProfileSavedBefore560IsForEveryoneWithoutAPIN() throws {
        let old = #"[{"id":"primary","name":"Me","avatar":0,"createdAt":1764000000},{"id":"p1","name":"Alex","avatar":2,"createdAt":1764000100}]"#
        let storage = MemoryLibraryStorage([ProfileManager.profilesKey: old.data(using: .utf8)!, ProfileManager.activeKey: "p1"])
        let profiles = manager(storage)
        eq(profiles.profiles.map(\.name), ["Me", "Alex"], "both profiles read")
        eq(profiles.activeID, "p1", "the active one kept")
        for profile in profiles.profiles {
            check(!profile.isKid && !profile.hasPIN && profile.restriction == nil, "\(profile.name): for everyone, no PIN")
            eq(profile.maxRating, .default, "\(profile.name): the default rating, for the day it is a kids profile")
        }
        // A rating from a later build is read as the default.
        let later = #"[{"id":"primary","name":"Me","avatar":0,"createdAt":1764000000,"isKid":true,"maxRating":"TV-MA-9"}]"#
        let laterProfiles = manager(MemoryLibraryStorage([ProfileManager.profilesKey: later.data(using: .utf8)!]))
        eq(laterProfiles.active.maxRating, .default, "an unknown rating")
        check(laterProfiles.active.isKid, "the kids profile stays one")
    }

    func testAKidsProfileIsSavedAndMakingTheActiveOneAKidsProfileIsAnnounced() throws {
        let center = NotificationCenter()
        let storage = MemoryLibraryStorage()
        let profiles = manager(storage, center: center)
        let kid = try profiles.create(name: "Sam", avatar: 3, isKid: true, maxRating: .allAges)
        eq(kid.restriction, ContentRestriction(maxRating: .allAges), "a kids profile, all ages")
        eq(manager(storage).profile(withID: kid.id)?.restriction, ContentRestriction(maxRating: .allAges), "read back")

        var switches = 0
        let token = center.addObserver(forName: .activeProfileDidChange, object: nil, queue: nil) { _ in switches += 1 }
        defer { center.removeObserver(token) }
        try profiles.update(kid.id, maxRating: .pg13)
        eq(switches, 0, "another profile's rating changes nothing on screen")
        profiles.activate(kid.id)
        eq(switches, 1, "activated")
        try profiles.update(kid.id, maxRating: .pg)
        eq(switches, 2, "the active profile's rating: the screens follow")
        try profiles.update(kid.id, name: "Samuel")
        eq(switches, 2, "a new name only: nothing to rebuild")
        try profiles.update(kid.id, isKid: false)
        eq(switches, 3, "no longer a kids profile: the screens follow")
        eq(profiles.active.maxRating, .pg, "the rating is kept for the day it is one again")
    }

    func testThePINIsFourDigitsStoredHashedOnly() throws {
        let storage = MemoryLibraryStorage()
        let profiles = manager(storage)
        let alex = try profiles.create(name: "Alex", avatar: 1)
        check(profiles.checkPIN("0000", for: alex.id), "no PIN: any opens it")
        for bad in ["123", "12345", "12a4", "١٢٣٤", " 123", ""] {
            XCTAssertThrowsError(try profiles.setPIN(bad, for: alex.id), "« \(bad) »") { error in
                eq(error as? ProfileManager.ProfileError, .invalidPIN, "« \(bad) »: not a PIN")
            }
        }
        try profiles.setPIN("2580", for: alex.id)
        check(profiles.profile(withID: alex.id)!.hasPIN, "a PIN")
        check(profiles.checkPIN("2580", for: alex.id), "the PIN opens it")
        check(!profiles.checkPIN("2581", for: alex.id) && !profiles.checkPIN("", for: alex.id), "another does not")

        let data = storage.object(forKey: ProfileManager.profilesKey) as! Data
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains("2580"), "the PIN is nowhere in the stored list")
        let reread = manager(storage)
        check(reread.checkPIN("2580", for: alex.id) && !reread.checkPIN("0852", for: alex.id), "checked after a relaunch")

        // The same PIN on two profiles: two different hashes (salt, id).
        let sam = try profiles.create(name: "Sam", avatar: 2)
        try profiles.setPIN("2580", for: sam.id)
        check(profiles.profile(withID: sam.id)!.pinHash != profiles.profile(withID: alex.id)!.pinHash, "salted")
        check(!ProfilePIN.matches("2580", hash: profiles.profile(withID: alex.id)!.pinHash!, profileID: sam.id),
              "a hash does not open another profile")

        try profiles.setPIN(nil, for: alex.id)
        check(!profiles.profile(withID: alex.id)!.hasPIN && profiles.checkPIN("1111", for: alex.id), "removed")
        check(!profiles.checkPIN("2580", for: "gone"), "an unknown profile opens with nothing")
        XCTAssertThrowsError(try profiles.setPIN("1234", for: "gone"))
    }

    func testAPINHashIsReadOnlyInItsOwnForm() {
        check(!ProfilePIN.matches("1234", hash: "1234", profileID: "p1"), "a PIN stored in clear is not taken")
        check(!ProfilePIN.matches("1234", hash: "pbkdf2$x$y$z", profileID: "p1"), "a damaged hash opens nothing")
        let hash = ProfilePIN.hash("1234", profileID: "p1")
        check(hash.hasPrefix("pbkdf2$\(ProfilePIN.rounds)$"), "PBKDF2, its rounds")
        check(ProfilePIN.matches("1234", hash: hash, profileID: "p1"), "and read back")
    }
}

private extension Show {
    init(id: String) {
        self.init(title: id, id: id)
    }
}
