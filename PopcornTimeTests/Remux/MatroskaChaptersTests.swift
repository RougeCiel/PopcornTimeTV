//
//  MatroskaChaptersTests.swift
//  PopcornTimeTests
//
//  « Skip Intro » reads the Matroska Chapters (`MatroskaDemuxer.loadChapters`): the default
//  edition (not an ordered one), its enabled, visible atoms, nested ones too, every language's
//  title; the element found through the SeekHead or between the headers and the first Cluster;
//  a body not downloaded yet (zeros) waited for; and what SkipMarkerWatch makes of them.
//

import XCTest
import Foundation
@testable import PopcornKit

final class MatroskaChaptersTests: XCTestCase {

    // MARK: EBML bytes

    private static func size(_ value: Int) -> [UInt8] {
        // 8-byte VINT: always valid.
        var bytes: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { bytes.append(UInt8((value >> shift) & 0xFF)) }
        return bytes
    }

    private static func el(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] { id + size(payload.count) + payload }

    private static func uint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        return bytes
    }

    private static func atom(_ start: Double, _ end: Double? = nil, titles: [String], hidden: Bool = false,
                             children: [[UInt8]] = []) -> [UInt8] {
        var body = el([0x73, 0xC4], uint(UInt64(start * 1000) + 1))                       // ChapterUID
        body += el([0x91], uint(UInt64(start * 1_000_000_000)))                            // ChapterTimeStart (ns)
        if let end = end { body += el([0x92], uint(UInt64(end * 1_000_000_000))) }        // ChapterTimeEnd
        if hidden { body += el([0x98], [1]) }                                              // ChapterFlagHidden
        for title in titles {
            body += el([0x80], el([0x85], Array(title.utf8)) + el([0x43, 0x7C], Array("eng".utf8)))   // ChapterDisplay
        }
        for child in children { body += child }
        return el([0xB6], body)
    }

    private static func edition(_ atoms: [[UInt8]], isDefault: Bool = false, ordered: Bool = false) -> [UInt8] {
        var body: [UInt8] = []
        if isDefault { body += el([0x45, 0xDB], [1]) }
        if ordered { body += el([0x45, 0xDD], [1]) }
        return el([0x45, 0xB9], body + atoms.flatMap { $0 })
    }

    private static func chapters(_ editions: [[UInt8]]) -> [UInt8] {
        el([0x10, 0x43, 0xA7, 0x70], editions.flatMap { $0 })
    }

    /// EBML header, Segment (unknown size), [SeekHead], Info (duration), Tracks (one video
    /// track), `between`, a Cluster, `tail`.
    private static func file(between: [UInt8], tail: [UInt8] = [], seekToTail: Bool = false) -> [UInt8] {
        let header = el([0x1A, 0x45, 0xDF, 0xA3], el([0x42, 0x82], Array("matroska".utf8)))
        var info = el([0x2A, 0xD7, 0xB1], uint(1_000_000))
        info += el([0x44, 0x89], withUnsafeBytes(of: (2_640_000.0).bitPattern.bigEndian, Array.init))   // Duration: 2640 s in 1 ms ticks
        let infoElement = el([0x15, 0x49, 0xA9, 0x66], info)
        let track = el([0xAE], el([0xD7], [1]) + el([0x73, 0xC5], [1]) + el([0x83], [1]) + el([0x86], Array("V_MPEG4/ISO/AVC".utf8)))
        let tracks = el([0x16, 0x54, 0xAE, 0x6B], track)
        let cluster = el([0x1F, 0x43, 0xB6, 0x75], el([0xE7], [0]))
        // SeekHead sized the same with or without an entry (positions relative to the Segment's data).
        func seekHead(tailPosition: Int?) -> [UInt8] {
            guard let position = tailPosition else { return el([0xEC], Array(repeating: 0, count: 34)) }   // Void
            let seek = el([0x4D, 0xBB], el([0x53, 0xAB], [0x10, 0x43, 0xA7, 0x70]) + el([0x53, 0xAC], size(position).dropFirst().map { $0 }))
            return el([0x11, 0x4D, 0x9B, 0x74], seek)
        }
        let probe = seekHead(tailPosition: seekToTail ? 0 : nil)
        let bodyBeforeTail = probe.count + infoElement.count + tracks.count + between.count + cluster.count
        let head = seekHead(tailPosition: seekToTail ? bodyBeforeTail : nil)
        precondition(head.count == probe.count)
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        return header + segment + head + infoElement + tracks + between + cluster + tail
    }

    private var files: [URL] = []
    private var handles: [FileHandle] = []

    override func tearDown() {
        handles.forEach { try? $0.close() }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func load(_ bytes: [UInt8], complete: Bool = true) throws -> MatroskaDemuxer.ChapterLoad {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chapters-\(UUID().uuidString).mkv")
        try Data(bytes).write(to: url)
        files.append(url)
        let handle = try FileHandle(forReadingFrom: url)
        handles.append(handle)
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { UInt64(bytes.count) }))
        demuxer.assumeFullyDownloaded = complete
        XCTAssertTrue(demuxer.parseHeaders())
        return demuxer.loadChapters()
    }

    private static let episode = chapters([edition([
        atom(0, 45, titles: ["Recap", "Résumé"]),
        atom(45, 135, titles: ["Intro"]),
        atom(135, titles: ["Chapter 1"], children: [atom(600, titles: ["Nested"])]),
        atom(1000, titles: ["Hidden"], hidden: true),
        atom(2580, titles: ["Credits"]),
    ], isDefault: true)])

    func testChaptersBetweenTheHeadersAndTheFirstCluster() throws {
        guard case .available(let list) = try load(Self.file(between: Self.episode)) else { return XCTFail("no chapters") }
        XCTAssertEqual(list.map(\.title), ["Recap / Résumé", "Intro", "Chapter 1", "Nested", "Credits"])
        XCTAssertEqual(list.map(\.startSeconds), [0, 45, 135, 600, 2580])
        XCTAssertEqual(list[1].endSeconds, 135)
        XCTAssertNil(list[2].endSeconds)
    }

    func testChaptersAfterTheClustersThroughTheSeekHead() throws {
        guard case .available(let list) = try load(Self.file(between: [], tail: Self.episode, seekToTail: true)) else {
            return XCTFail("no chapters")
        }
        XCTAssertEqual(list.count, 5)
    }

    func testNoChapters() throws {
        XCTAssertEqual(try load(Self.file(between: [])), .unavailable("no Chapters element"))
    }

    func testTheDefaultEditionAndNeverAnOrderedOne() throws {
        let editions = Self.chapters([
            Self.edition([Self.atom(0, titles: ["Ordered"])], isDefault: true, ordered: true),
            Self.edition([Self.atom(0, titles: ["First"])]),
            Self.edition([Self.atom(0, titles: ["Default"])], isDefault: true),
        ])
        guard case .available(let list) = try load(Self.file(between: editions)) else { return XCTFail("no chapters") }
        XCTAssertEqual(list.map(\.title), ["Default"])

        let orderedOnly = Self.chapters([Self.edition([Self.atom(0, titles: ["Ordered"])], ordered: true)])
        XCTAssertEqual(try load(Self.file(between: orderedOnly)), .unavailable("ordered chapters only"))
    }

    func testAChaptersBodyNotDownloadedYetIsWaitedFor() throws {
        let element = Self.episode
        // The body zero-filled from its middle (a preallocated torrent file).
        var holed = element
        for index in (element.count / 2)..<element.count { holed[index] = 0 }
        XCTAssertEqual(try load(Self.file(between: holed), complete: false), .notYet)
        XCTAssertNil(MatroskaDemuxer.parseChapters(Data(holed.dropFirst(12))))
    }

    func testWhatTheMarkersMakeOfThem() throws {
        guard case .available(let list) = try load(Self.file(between: Self.episode)) else { return XCTFail("no chapters") }
        let chapters = list.map { PlaybackChapter(title: $0.title, start: $0.startSeconds, end: $0.endSeconds) }
        let markers = IntroMarkers.fromChapters(chapters, duration: 2640)
        XCTAssertEqual(markers.markers.map(\.kind), [.recap, .intro, .credits])
        XCTAssertEqual(markers.creditsStart, 2580)
    }
}
