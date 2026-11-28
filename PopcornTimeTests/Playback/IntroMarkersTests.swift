//
//  IntroMarkersTests.swift
//  PopcornTimeTests
//
//  « Skip Intro / Recap / Credits » (PopcornKit IntroMarkers): what a chapter's title says it
//  is in the app's languages and the anime names (OP / ED), the bounds that keep a mislabelled
//  chapter from skipping the episode, the button offered at each position, the credits that
//  end the file (the « next episode » card there: UpNextCountdown.useCredits), the external
//  sources filling only what the chapters lack.
//

import XCTest
import Foundation
@testable import PopcornKit

final class IntroMarkersTests: XCTestCase {

    private typealias M = IntroMarkers

    private func kind(_ title: String) -> M.Label? { M.label(ofChapterTitle: title) }

    // MARK: Titles

    func testTitlesInTheAppsLanguages() {
        XCTAssertEqual(kind("Intro"), .kind(.intro))
        XCTAssertEqual(kind("Opening"), .kind(.intro))
        XCTAssertEqual(kind("Opening Credits"), .kind(.intro))
        XCTAssertEqual(kind("OP"), .kind(.intro))
        XCTAssertEqual(kind("OP2"), .kind(.intro))
        XCTAssertEqual(kind("Générique de début"), .kind(.intro))
        XCTAssertEqual(kind("Vorspann"), .kind(.intro))
        XCTAssertEqual(kind("Sigla iniziale"), .kind(.intro))
        XCTAssertEqual(kind("Abertura"), .kind(.intro))

        XCTAssertEqual(kind("Recap"), .kind(.recap))
        XCTAssertEqual(kind("Previously On"), .kind(.recap))
        XCTAssertEqual(kind("Précédemment"), .kind(.recap))
        XCTAssertEqual(kind("Was bisher geschah"), .kind(.recap))
        XCTAssertEqual(kind("Anteriormente en"), .kind(.recap))

        XCTAssertEqual(kind("End Credits"), .kind(.credits))
        XCTAssertEqual(kind("Ending"), .kind(.credits))
        XCTAssertEqual(kind("ED"), .kind(.credits))
        XCTAssertEqual(kind("ED 1"), .kind(.credits))
        XCTAssertEqual(kind("Générique de fin"), .kind(.credits))
        XCTAssertEqual(kind("Abspann"), .kind(.credits))
        XCTAssertEqual(kind("Titoli di coda"), .kind(.credits))
        XCTAssertEqual(kind("Créditos finales"), .kind(.credits))

        XCTAssertEqual(kind("Preview"), .kind(.preview))
        XCTAssertEqual(kind("Next Episode"), .kind(.preview))
        XCTAssertEqual(kind("Prochain épisode"), .kind(.preview))

        // Placed by their time.
        XCTAssertEqual(kind("Générique"), .theme)
        XCTAssertEqual(kind("Credits"), .theme)
        XCTAssertEqual(kind("Sigla"), .theme)

        // Several languages in one title (MKV ChapterDisplay): « Intro / Générique ».
        XCTAssertEqual(kind("Intro / Générique"), .kind(.intro))
    }

    func testPlainChaptersAreNotMarkers() {
        for title in ["Chapter 1", "Chapitre 03", "00:12:04.000", "Ed's Return", "The Operation", "Introducing Mr. Smith",
                      "Prologue", "", "   ", "12"] {
            XCTAssertNil(kind(title), title)
        }
        XCTAssertNil(M.label(ofChapterTitle: nil))
    }

    // MARK: From chapters

    private let episode: [PlaybackChapter] = [
        PlaybackChapter(title: "Recap", start: 0),
        PlaybackChapter(title: "Intro", start: 45),
        PlaybackChapter(title: "Chapter 1", start: 135),
        PlaybackChapter(title: "Chapter 2", start: 1200),
        PlaybackChapter(title: "Credits", start: 2580),
    ]

    func testAnEpisodesChapters() {
        let markers = M.fromChapters(episode, duration: 2640)
        XCTAssertEqual(markers.markers, [
            SkipMarker(kind: .recap, start: 0, end: 45),
            SkipMarker(kind: .intro, start: 45, end: 135),
            SkipMarker(kind: .credits, start: 2580, end: 2640),
        ])
        XCTAssertEqual(markers.creditsStart, 2580)
    }

    func testTheButtonAtEachPosition() {
        let markers = M.fromChapters(episode, duration: 2640)
        XCTAssertEqual(markers.skip(at: 10)?.kind, .recap)
        XCTAssertEqual(markers.skip(at: 45)?.kind, .intro)
        XCTAssertEqual(markers.skip(at: 132)?.kind, .intro)
        XCTAssertNil(markers.skip(at: 133.5), "2 s before the end of the part: no button (the skip would land there)")
        XCTAssertNil(markers.skip(at: 600))
        XCTAssertNil(markers.skip(at: 2600), "credits that end the file: the « next episode » card, not a button")
        XCTAssertNil(markers.skip(at: .nan))
    }

    func testCreditsBeforeAPostCreditsSceneAreSkippable() {
        let chapters = [
            PlaybackChapter(title: "Chapter 1", start: 0),
            PlaybackChapter(title: "End Credits", start: 2400),
            PlaybackChapter(title: "Post-credits scene", start: 2520),
        ]
        let markers = M.fromChapters(chapters, duration: 2640)
        XCTAssertEqual(markers.skip(at: 2450), SkipMarker(kind: .credits, start: 2400, end: 2520))
        XCTAssertNil(markers.creditsStart, "something plays after them: no card at their start")
    }

    func testCreditsThenAPreviewEndTheFile() {
        let chapters = [
            PlaybackChapter(title: "OP", start: 90),
            PlaybackChapter(title: "Part A", start: 180),
            PlaybackChapter(title: "ED", start: 1290),
            PlaybackChapter(title: "Preview", start: 1380),
        ]
        let markers = M.fromChapters(chapters, duration: 1410)
        XCTAssertEqual(markers.creditsStart, 1290)
        XCTAssertNil(markers.skip(at: 1300))
        XCTAssertEqual(markers.skip(at: 1390)?.kind, .preview)
    }

    func testAmbiguousNamesArePlacedByTime() {
        let chapters = [
            PlaybackChapter(title: "Générique", start: 60),
            PlaybackChapter(title: "Partie 1", start: 120),
            PlaybackChapter(title: "Générique", start: 1300),
        ]
        let markers = M.fromChapters(chapters, duration: 1380)
        XCTAssertEqual(markers.markers.map(\.kind), [.intro, .credits])
    }

    func testAdjacentPartsOfOneKindMerge() {
        let chapters = [
            PlaybackChapter(title: "Opening", start: 30),
            PlaybackChapter(title: "Opening (cont.)", start: 60),
            PlaybackChapter(title: "Act 1", start: 110),
        ]
        XCTAssertEqual(M.fromChapters(chapters, duration: 1500).markers, [SkipMarker(kind: .intro, start: 30, end: 110)])
    }

    func testExplicitEndsAndUnsortedChapters() {
        let chapters = [
            PlaybackChapter(title: "Act 1", start: 100, end: 1000),
            PlaybackChapter(title: "Intro", start: 10, end: 70),
        ]
        XCTAssertEqual(M.fromChapters(chapters, duration: 1500).markers, [SkipMarker(kind: .intro, start: 10, end: 70)])
    }

    // MARK: Bounds

    func testImplausibleMarkersAreDropped() {
        let chapters = [
            PlaybackChapter(title: "Intro", start: 0, end: 2),            // too short
            PlaybackChapter(title: "Recap", start: 5, end: 600),          // 10 min recap
            PlaybackChapter(title: "Opening", start: 1000, end: 1060),    // past the middle
            PlaybackChapter(title: "End Credits", start: 200, end: 260),  // credits in the first half
            PlaybackChapter(title: "Credits", start: 1100, end: 1200),    // « Credits » past the middle: fine
        ]
        let markers = M.fromChapters(chapters, duration: 1200)
        XCTAssertEqual(markers.markers, [SkipMarker(kind: .credits, start: 1100, end: 1200)])
    }

    func testWithoutDuration() {
        let chapters = [
            PlaybackChapter(title: "Intro", start: 60),
            PlaybackChapter(title: "Act 1", start: 150),
            PlaybackChapter(title: "Credits", start: 2500, end: 2600),
        ]
        let markers = M.fromChapters(chapters, duration: nil)
        XCTAssertEqual(markers.markers.map(\.kind), [.intro, .credits])
        XCTAssertEqual(markers.creditsStart, 2500)
        // The length known later: credits that stop 40 s before the end do not end the file.
        let known = markers.with(duration: 2640)
        XCTAssertNil(known.creditsStart)
        XCTAssertEqual(known.skip(at: 2550)?.kind, .credits)
    }

    // MARK: External sources

    func testExternalMarkersFillOnlyWhatTheChaptersLack() {
        let chapters = M.fromChapters([PlaybackChapter(title: "Intro", start: 30, end: 90),
                                       PlaybackChapter(title: "Act 1", start: 90)], duration: 2400)
        let external = [SkipMarker(kind: .intro, start: 0, end: 60, source: .external("Base")),
                        SkipMarker(kind: .credits, start: 2350, end: 2400, source: .external("Base")),
                        SkipMarker(kind: .recap, start: 2000, end: 2050, source: .external("Base"))]
        let merged = chapters.merging(external)
        XCTAssertEqual(merged.markers, [SkipMarker(kind: .intro, start: 30, end: 90),
                                        SkipMarker(kind: .credits, start: 2350, end: 2400, source: .external("Base"))],
                       "the chapters' intro stays; a recap past the middle is not plausible")
        XCTAssertEqual(merged.creditsStart, 2350)
    }

    func testLogDescription() {
        XCTAssertEqual(SkipMarker(kind: .intro, start: 42, end: 132).logDescription, "intro 0:42–2:12 (chapters)")
    }
}

/// The « next episode » card at the start of the credits (`UpNextCountdown.useCredits`).
final class UpNextCreditsTests: XCTestCase {

    private func countdown(autoAdvance: Bool = true, lead: TimeInterval = 60) -> UpNextCountdown {
        var tuning = UpNextCountdown.Tuning()
        tuning.cardLead = lead
        return UpNextCountdown(autoAdvance: autoAdvance, tuning: tuning)
    }

    func testTheCardComesAtTheCreditsAndTheNextEpisodeStartsALeadLater() {
        var c = countdown()
        _ = c.tick(now: 0, position: 10, duration: 2640, isPlaying: true)
        XCTAssertEqual(c.cardAt, 2580)
        c.useCredits(at: 2400)
        XCTAssertEqual(c.cardAt, 2400)
        XCTAssertEqual(c.countdownEnd, 2460)
        XCTAssertLessThanOrEqual(c.prefetchAt ?? .infinity, 2400)
        _ = c.planReady(now: 1)
        _ = c.tick(now: 2, position: 2399, duration: 2640, isPlaying: true)
        XCTAssertNil(c.card)
        _ = c.tick(now: 3, position: 2400, duration: 2640, isPlaying: true)
        XCTAssertEqual(c.phase, .offered)
        XCTAssertEqual(c.card?.secondsLeft, 60)
        XCTAssertEqual(c.card?.total, 60)
        _ = c.tick(now: 4, position: 2430, duration: 2640, isPlaying: true)
        XCTAssertEqual(c.card?.secondsLeft, 30)
        let effects = c.tick(now: 5, position: 2460, duration: 2640, isPlaying: true)
        XCTAssertEqual(effects, [.start(.deadline)], "the countdown over the credits ran out: the next episode starts")
        XCTAssertFalse(c.reachedEnd)
    }

    func testShortCreditsCountDownToTheEndOfTheFile() {
        var c = countdown()
        c.useCredits(at: 2610)   // before the length is known: kept
        _ = c.tick(now: 0, position: 10, duration: 2640, isPlaying: true)
        XCTAssertEqual(c.cardAt, 2610)
        XCTAssertEqual(c.countdownEnd, 2640)
    }

    func testWithoutAutoplayTheCardWaitsForTheEnd() {
        var c = countdown(autoAdvance: false)
        _ = c.tick(now: 0, position: 10, duration: 2640, isPlaying: true)
        c.useCredits(at: 2400)
        _ = c.planReady(now: 1)
        _ = c.tick(now: 2, position: 2400, duration: 2640, isPlaying: true)
        XCTAssertEqual(c.phase, .offered)
        XCTAssertEqual(c.tick(now: 3, position: 2500, duration: 2640, isPlaying: true), [])
        XCTAssertEqual(c.phase, .offered)
    }

    func testImplausibleCreditsAndLateCallsAreIgnored() {
        var c = countdown()
        _ = c.tick(now: 0, position: 10, duration: 2640, isPlaying: true)
        c.useCredits(at: 600)   // 34 min before the end
        XCTAssertEqual(c.cardAt, 2580)
        c.useCredits(at: 2700)  // past the end
        XCTAssertEqual(c.cardAt, 2580)
        c.useCredits(at: nil)
        XCTAssertEqual(c.cardAt, 2580)

        var offered = countdown()
        _ = offered.tick(now: 0, position: 2590, duration: 2640, isPlaying: true)
        XCTAssertEqual(offered.phase, .offered)
        offered.useCredits(at: 2400)
        XCTAssertEqual(offered.cardAt, 2580, "the card is up: it stays as it is")
    }
}
