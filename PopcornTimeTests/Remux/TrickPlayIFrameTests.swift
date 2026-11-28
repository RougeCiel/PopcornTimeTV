//
//  TrickPlayIFrameTests.swift
//  PopcornTimeTests
//
//  Trick play (`RemuxIFrames`): the I-frame stream of the master playlist (CODECS,
//  SUPPLEMENTAL-CODECS and VIDEO-RANGE of Dolby Vision, HDR10+, HLG, SDR), the I-frame playlist
//  (the video's EXTINF list, `#EXT-X-I-FRAMES-ONLY`), the keyframe read back from an fMP4
//  segment, and `RemuxPlayback` serving `iframe{K}.m4s` from the segments on disk only — the
//  nearest one standing in for a segment not remuxed yet, never a 404, never a held request.
//

import XCTest
import Foundation
import AVFoundation

final class TrickPlayIFrameTests: RemuxSessionTestCase {

    // MARK: - Master playlist

    private func video(codecs: String, supplemental: String? = nil, range: String) -> MKVToHLSRemuxSession.VideoRendition {
        MKVToHLSRemuxSession.VideoRendition(codecs: codecs, supplementalCodecs: supplemental, videoRange: range,
                                            width: 3840, height: 2160, frameRate: 23.976, summary: "test")
    }

    private let eac3 = MKVToHLSRemuxSession.AudioRendition(index: 0, name: "Français", language: "fr", isDefault: true,
                                                           autoselect: true, channels: "16/JOC", codecs: "ec-3",
                                                           isAtmos: true, summary: "E-AC-3 Atmos")

    private func iFrameLine(_ master: String) -> String? {
        master.split(separator: "\n").map(String.init).first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
    }

    func testNoIFrameStreamUnlessAsked() {
        let master = HLSPlaylists.master(video: video(codecs: "hvc1.2.4.L153.B0", range: "PQ"), audio: [eac3],
                                         subtitles: [], external: [], bandwidth: 20_000_000)
        check(iFrameLine(master) == nil, "no I-frame stream by default (the existing callers)", master)
    }

    func testDolbyVisionIFramesCarryTheVideoCodecsAndPQ() {
        let dv = video(codecs: "hvc1.2.4.L153.B0", supplemental: "dvh1.08.06/db1p", range: "PQ")
        let master = HLSPlaylists.master(video: dv, audio: [eac3], subtitles: [], external: [], bandwidth: 20_000_000,
                                         iFrames: .init(bandwidth: 800_000, uri: RemuxIFrames.playlistName))
        guard let line = iFrameLine(master) else { return check(false, "an I-frame stream", master) }
        eq(line, "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=800000,CODECS=\"hvc1.2.4.L153.B0\","
           + "SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\",RESOLUTION=3840x2160,VIDEO-RANGE=PQ,URI=\"iframes.m3u8\"",
           "Dolby Vision 8.1: the HDR10 base layer's CODECS, Dolby Vision as SUPPLEMENTAL-CODECS, PQ, no audio codec")
        check(!line.contains("ec-3"), "an I-frame stream has no audio")
        check(!line.contains("AUDIO=") && !line.contains("CLOSED-CAPTIONS") && !line.contains("FRAME-RATE"),
              "only the attributes EXT-X-I-FRAME-STREAM-INF allows", line)
        // After the variant and its URI: AVPlayer reads the tag anywhere in the master.
        let lines = master.split(separator: "\n").map(String.init)
        check(lines.firstIndex(of: line)! > lines.firstIndex(of: "video.m3u8")!, "after the video variant", master)
    }

    func testHDR10PlusHLGAndSDRRanges() {
        let cases: [(MKVToHLSRemuxSession.VideoRendition, String)] = [
            (video(codecs: "hvc1.2.4.L153.B0", supplemental: "hvc1.2.4.L153.B0/cdm4", range: "PQ"),
             "SUPPLEMENTAL-CODECS=\"hvc1.2.4.L153.B0/cdm4\",RESOLUTION=3840x2160,VIDEO-RANGE=PQ"),
            (video(codecs: "hvc1.2.4.L150.B0", range: "HLG"), "CODECS=\"hvc1.2.4.L150.B0\",RESOLUTION=3840x2160,VIDEO-RANGE=HLG"),
            (video(codecs: "avc1.640028", range: "SDR"), "CODECS=\"avc1.640028\",RESOLUTION=3840x2160,VIDEO-RANGE=SDR"),
            (video(codecs: "avc1.640028", range: "whatever"), "VIDEO-RANGE=SDR"),
        ]
        for (rendition, expected) in cases {
            let line = HLSPlaylists.iFrameStreamInf(video: rendition, stream: .init(bandwidth: 0, uri: "iframes.m3u8"))
            check(line.contains(expected), "\(rendition.videoRange): \(expected)", line)
            check(line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,"), "BANDWIDTH at least 1", line)
            let master = HLSPlaylists.master(video: rendition, audio: [], subtitles: [], external: [], bandwidth: 1_000,
                                             iFrames: .init(bandwidth: 10, uri: "iframes.m3u8"))
            let variant = master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:") }.map(String.init) ?? ""
            let range = "VIDEO-RANGE=" + (line.components(separatedBy: "VIDEO-RANGE=").last?.prefix { $0 != "," } ?? "")
            check(variant.contains(range), "the same VIDEO-RANGE as the video variant", variant)
        }
    }

    // MARK: - I-frame playlist

    func testIFramePlaylistMirrorsTheVideoPlaylist() {
        let durations = [6.006, 5.839, 6.507, 4.2]
        let videoPlaylist = HLSPlaylists.media(mapURI: "video_init.mp4", segmentPrefix: "vseg", segmentExtension: "m4s",
                                               actualDurations: durations, expectedSegments: 0, targetDuration: 6)
        let iFrames = HLSPlaylists.media(mapURI: "video_init.mp4", segmentPrefix: "iframe", segmentExtension: "m4s",
                                         actualDurations: durations, expectedSegments: 0, targetDuration: 6, iFramesOnly: true)
        let lines = iFrames.split(separator: "\n").map(String.init)
        eq(Array(lines.prefix(7)), ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:8", "#EXT-X-MEDIA-SEQUENCE:0",
                                    "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-I-FRAMES-ONLY", "#EXT-X-MAP:URI=\"video_init.mp4\""],
           "header: VOD, I-frames only, the video init segment")
        eq(lines.last, "#EXT-X-ENDLIST", "ENDLIST")
        let extinf = { (text: String) in text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") } }
        eq(extinf(iFrames), extinf(videoPlaylist), "the same EXTINF list as the video: same timeline")
        eq(lines.filter { $0.hasPrefix("iframe") }, ["iframe0.m4s", "iframe1.m4s", "iframe2.m4s", "iframe3.m4s"], "one I-frame per segment")
        check(!iFrames.contains("BYTERANGE"), "each I-frame is a resource of its own")
        // EVENT: never I-frames only (the session announces none then).
        let event = HLSPlaylists.media(mapURI: "video_init.mp4", segmentPrefix: "iframe", segmentExtension: "m4s",
                                       actualDurations: durations, expectedSegments: 0, targetDuration: 6,
                                       type: .event(ended: false), iFramesOnly: true)
        check(!event.contains("I-FRAMES-ONLY"), "no I-FRAMES-ONLY on an EVENT playlist", event)
    }

    func testSegmentNames() {
        eq(RemuxIFrames.segmentIndex("iframe0.m4s"), 0, "iframe0")
        eq(RemuxIFrames.segmentIndex("iframe1234.m4s"), 1234, "iframe1234")
        for bad in ["iframe.m4s", "iframe-1.m4s", "vseg3.m4s", "iframe3.mp4", "iframe1x.m4s", "iframe12345678901.m4s"] {
            check(RemuxIFrames.segmentIndex(bad) == nil, "not an I-frame name: \(bad)")
        }
    }

    // MARK: - Reading the keyframe of a segment

    private let videoTrack = FMP4Muxer.TrackConfig(trackID: 1, timescale: 90_000, handler: .video,
                                                   width: 1920, height: 1080, sampleEntry: Data([0, 0, 0, 8, 0x61, 0x76, 0x63, 0x31]))

    private func segment(samples: [FMP4Muxer.Sample], decodeTime: UInt64 = 540_000) -> Data {
        FMP4Muxer.mediaSegment(sequence: 7, trackSamples: [(config: videoTrack, baseDecodeTime: decodeTime, samples: samples)])
    }

    private let gop: [FMP4Muxer.Sample] = [
        FMP4Muxer.Sample(data: Data(repeating: 0xAB, count: 1_000), duration: 3_754, sync: true, compositionOffset: 7_508),
        FMP4Muxer.Sample(data: Data(repeating: 0x01, count: 200), duration: 3_754, sync: false, compositionOffset: -3_754),
        FMP4Muxer.Sample(data: Data(repeating: 0x02, count: 300), duration: 3_754, sync: false),
    ]

    func testTheFirstKeyframeOfASegment() {
        let data = segment(samples: gop)
        guard let keyframe = RemuxIFrames.firstKeyframe(inSegmentHeader: data) else { return check(false, "a keyframe") }
        eq(keyframe.trackID, 1, "track")
        eq(keyframe.baseDecodeTime, 540_000, "tfdt")
        eq(keyframe.duration, 3_754, "duration")
        eq(keyframe.compositionOffset, 7_508, "composition offset (open GOP / B-frames)")
        eq(keyframe.size, 1_000, "size")
        eq(data.subdata(in: keyframe.dataOffset..<(keyframe.dataOffset + keyframe.size)), gop[0].data, "its bytes")
        // A slice of a larger buffer reads the same.
        let padded = Data([9, 9, 9]) + data
        eq(RemuxIFrames.firstKeyframe(inSegmentHeader: padded.dropFirst(3)), keyframe, "a slice")
        // Only the moof is needed.
        guard let moofEnd = RemuxIFrames.bytesThroughFirstMoof(data.prefix(16)) else { return check(false, "moof size from its header") }
        eq(RemuxIFrames.firstKeyframe(inSegmentHeader: data.prefix(moofEnd)), keyframe, "parsed from the moof alone")
        check(RemuxIFrames.firstKeyframe(inSegmentHeader: data.prefix(moofEnd - 1)) == nil, "a truncated moof: nil")
        check(RemuxIFrames.bytesThroughFirstMoof(data.prefix(4)) == nil, "no box header yet: nil")
    }

    func testASegmentThatDoesNotStartWithAKeyframe() {
        let filler = [FMP4Muxer.Sample(data: Data(repeating: 0, count: 50), duration: 90_000, sync: false)]
        check(RemuxIFrames.firstKeyframe(inSegmentHeader: segment(samples: filler)) == nil, "a tail filler: no I-frame")
        check(RemuxIFrames.firstKeyframe(inSegmentHeader: Data()) == nil, "empty: nil")
        check(RemuxIFrames.firstKeyframe(inSegmentHeader: Data(repeating: 0xFF, count: 64)) == nil, "garbage: nil")
    }

    func testTheIFrameFragmentRoundTrips() {
        let data = segment(samples: gop)
        guard let keyframe = RemuxIFrames.firstKeyframe(inSegmentHeader: data) else { return check(false, "a keyframe") }
        let fragment = RemuxIFrames.fragment(keyframe: keyframe, sample: gop[0].data, sequence: 3, baseDecodeTime: 1_080_000)
        eq(fragment, FMP4Muxer.mediaSegment(sequence: 3, trackSamples: [(config: videoTrack, baseDecodeTime: 1_080_000,
                                                                          samples: [gop[0]])]),
           "one moof + mdat, the keyframe alone, as the muxer writes a segment")
        guard let back = RemuxIFrames.firstKeyframe(inSegmentHeader: fragment) else { return check(false, "parsed back") }
        eq(back.baseDecodeTime, 1_080_000, "moved tfdt")
        eq(back.compositionOffset, 7_508, "composition offset kept")
        eq(fragment.subdata(in: back.dataOffset..<(back.dataOffset + back.size)), gop[0].data, "the same bytes")
        let unmoved = RemuxIFrames.fragment(keyframe: keyframe, sample: gop[0].data, sequence: 3)
        eq(RemuxIFrames.firstKeyframe(inSegmentHeader: unmoved)?.baseDecodeTime, 540_000, "its own tfdt by default")
    }

    func testReadingFromAFileSkipsBoxesBeforeTheMoof() throws {
        guard let files = temporaryInput(Data()) else { return }
        let styp = Data([0, 0, 0, 16]) + Data("stypmsdh".utf8) + Data([0, 0, 0, 0])
        let url = files.input.deletingLastPathComponent().appendingPathComponent("vseg3.m4s")
        try (styp + segment(samples: gop)).write(to: url)
        guard let read = RemuxIFrames.readKeyframe(segmentAt: url) else { return check(false, "read from the file") }
        eq(read.sample, gop[0].data, "the keyframe's bytes")
        eq(read.keyframe.baseDecodeTime, 540_000, "its tfdt")
        // Truncated inside the keyframe (never on this server: segments are written atomically).
        let whole = styp + segment(samples: gop)
        try whole.prefix(whole.count - 1_200).write(to: url)
        check(RemuxIFrames.readKeyframe(segmentAt: url) == nil, "a keyframe cut short: nil")
        check(RemuxIFrames.readKeyframe(segmentAt: url.appendingPathExtension("missing")) == nil, "no file: nil")
    }

    func testTimescaleOfTheInitSegment() {
        eq(RemuxIFrames.timescale(ofInitSegment: FMP4Muxer.initSegment(tracks: [videoTrack])), 90_000, "mdhd timescale")
        let other = FMP4Muxer.TrackConfig(trackID: 1, timescale: 24_000, handler: .video, width: 1, height: 1, sampleEntry: Data([0, 0, 0, 8, 0x68, 0x76, 0x63, 0x31]))
        eq(RemuxIFrames.timescale(ofInitSegment: FMP4Muxer.initSegment(tracks: [other], extraBrands: ["dby1"])), 24_000, "another")
        check(RemuxIFrames.timescale(ofInitSegment: Data()) == nil, "nothing: nil")
    }

    func testSourceOrderAndMovedTimes() {
        eq(RemuxIFrames.sourceOrder(requested: 3, count: 6), [3, 2, 4, 1, 5, 0], "nearest first, the earlier one on a tie")
        eq(RemuxIFrames.sourceOrder(requested: 40, count: 4), [3, 2, 1, 0], "past the frontier: its last segment first")
        eq(RemuxIFrames.sourceOrder(requested: 0, count: 3), [0, 1, 2], "from the start")
        eq(RemuxIFrames.sourceOrder(requested: 2, count: 0), [], "nothing written")
        eq(RemuxIFrames.movedDecodeTime(900_000, sourceStart: 10, targetStart: 70, timescale: 90_000), 6_300_000, "60 s later")
        eq(RemuxIFrames.movedDecodeTime(900_000, sourceStart: 70, targetStart: 10, timescale: 90_000), 0, "never below 0")
        eq(RemuxIFrames.movedDecodeTime(900_000, sourceStart: 70, targetStart: 65, timescale: 90_000), 450_000, "earlier")
        eq(RemuxIFrames.bandwidth(keyframeBytes: 250_000, secondsPerKeyframe: 6), 666_667, "8 × bytes / s, twice as headroom")
        check(RemuxIFrames.bandwidth(keyframeBytes: 0, secondsPerKeyframe: 6) == nil, "no keyframe: nil")
        check(RemuxIFrames.bandwidth(keyframeBytes: 10, secondsPerKeyframe: .nan) == nil, "no duration: nil")
    }

    // MARK: - Served by RemuxPlayback

    private struct Clock { var now: TimeInterval = 1_000 }
    private var clock = Clock()

    override func setUp() {
        super.setUp()
        RemuxPlayback.uptimeProvider = { [unowned self] in self.clock.now }
        RemuxPlayback.freeSpaceProvider = { _ in 1 << 42 }
    }

    override func tearDown() {
        RemuxPlayback.uptimeProvider = nil
        RemuxPlayback.freeSpaceProvider = nil
        super.tearDown()
    }

    func testIFramesAreServedFromTheSegmentsOnDiskOnly() {
        let stream = RemuxTestStreams.make { $0.clusterCount = 120; $0.videoCodec = .hevc; $0.audioCodec = .eac3
            $0.videoFrameBytes = 600; $0.cues = .front }
        let layout = stream.layout()
        guard let files = temporaryInput(layout.data) else { return }
        let remux = RemuxPlayback(localFile: files.input, streamer: nil)
        remux.startsTicksOnDemand = false
        defer { remux.stop(); remux.runTick(timer: false) }
        var ticks = 0
        while (remux.session?.progress.segmentsWritten ?? 0) < 3, ticks < 50 {
            clock.now += 1
            remux.runTick(timer: false)
            ticks += 1
        }
        guard let session = remux.session, session.progress.segmentsWritten >= 3 else {
            return check(false, "the remux writes its first segments", "\(ticks) ticks")
        }
        guard let playlist = session.iFramePlaylist(), let list = session.playerTimelineDurations() else {
            return check(false, "an I-frame playlist (VOD session)")
        }
        check(playlist.contains("#EXT-X-I-FRAMES-ONLY") && playlist.contains("iframe\(list.count - 1).m4s"),
              "every segment of the frozen list has its I-frame", playlist)
        eq(playlist.replacingOccurrences(of: "iframe", with: "vseg").replacingOccurrences(of: "#EXT-X-I-FRAMES-ONLY\n", with: ""),
           session.mediaPlaylist(named: "video.m3u8"), "the video playlist, I-frames only")

        let output = remux.outputDirectory
        let written = session.progress.segmentsWritten
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])

        // A segment on disk: its own keyframe, its own tfdt.
        guard let own = remux.iFrameSegment(index: 1),
              let vseg1 = RemuxIFrames.readKeyframe(segmentAt: output.appendingPathComponent("vseg1.m4s")),
              let ownKey = RemuxIFrames.firstKeyframe(inSegmentHeader: own) else { return check(false, "iframe1 from vseg1") }
        eq(own.subdata(in: ownKey.dataOffset..<(ownKey.dataOffset + ownKey.size)), vseg1.sample, "vseg1's keyframe, byte for byte")
        eq(ownKey.baseDecodeTime, vseg1.keyframe.baseDecodeTime, "vseg1's tfdt")

        // Far past the remux frontier: the last segment written, moved to the requested start.
        let far = list.count - 2
        guard let stand = remux.iFrameSegment(index: far), let standKey = RemuxIFrames.firstKeyframe(inSegmentHeader: stand),
              let last = RemuxIFrames.readKeyframe(segmentAt: output.appendingPathComponent("vseg\(written - 1).m4s"))
        else { return check(false, "iframe\(far) stands in from the frontier") }
        eq(stand.subdata(in: standKey.dataOffset..<(standKey.dataOffset + standKey.size)), last.sample,
           "the frontier's keyframe (the thumbnail stops at the edge of what is remuxed)")
        let shift = (list.prefix(far).reduce(0, +) - list.prefix(written - 1).reduce(0, +)) * 90_000
        check(abs(Double(standKey.baseDecodeTime) - (Double(last.keyframe.baseDecodeTime) + shift)) <= 1,
              "its tfdt moved to iframe\(far)'s start", "\(standKey.baseDecodeTime)")
        check(remux.iFrameSegment(index: list.count + 50) != nil, "past the list's end: still an answer, never a 404")

        // Nothing written, nothing steered: the I-frames read the output folder, no more.
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
        eq(after, before, "no segment written for an I-frame request")
        eq(session.progress.segmentsWritten, written, "the remux didn't move")

        // A deleted segment: the nearest one still there.
        try? FileManager.default.removeItem(at: output.appendingPathComponent("vseg1.m4s"))
        guard let replaced = remux.iFrameSegment(index: 1), let replacedKey = RemuxIFrames.firstKeyframe(inSegmentHeader: replaced),
              let vseg0 = RemuxIFrames.readKeyframe(segmentAt: output.appendingPathComponent("vseg0.m4s")) else {
            return check(false, "iframe1 without vseg1")
        }
        eq(replaced.subdata(in: replacedKey.dataOffset..<(replacedKey.dataOffset + replacedKey.size)), vseg0.sample,
           "vseg0 stands in (the earlier one on a tie)")
    }

    // MARK: - A real AVPlayer (PT_TRICKPLAY_MKV)

    /// With `PT_TRICKPLAY_MKV=<a real MKV, video + AC-3 / E-AC-3>`: the remux served on 127.0.0.1,
    /// an AVPlayer on its master playlist. AVFoundation must accept the I-frame stream
    /// (`canPlayFastForward` / `canPlayFastReverse`), fetch I-frames when played at 8× and −8×,
    /// keep the item playable, and log no error. Skipped without the variable.
    func testAVPlayerTrickPlaysTheIFrameStream() throws {
        guard let path = ProcessInfo.processInfo.environment["PT_TRICKPLAY_MKV"], !path.isEmpty else {
            throw XCTSkip("set PT_TRICKPLAY_MKV to a real MKV file")
        }
        RemuxPlayback.uptimeProvider = nil // real time: the server's holds run on it
        let remux = RemuxPlayback(localFile: URL(fileURLWithPath: path), streamer: nil)
        var ready: URL?
        remux.onReady = { ready = $0 }
        remux.start()
        defer { remux.stop() }
        func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            return condition()
        }
        guard wait(60, until: { ready != nil }), let url = ready else { return check(false, "the remux gets ready") }
        let master = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        print("[TrickPlay] master:\n\(master)")
        check(master.contains("#EXT-X-I-FRAME-STREAM-INF:"), "the master announces the I-frame stream", master)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        guard wait(30, until: { item.status != .unknown }), item.status == .readyToPlay else {
            return check(false, "the item gets ready", "\(item.status.rawValue) \(String(describing: item.error))")
        }
        check(item.canPlayFastForward, "AVPlayer can fast-forward (I-frame stream accepted)")
        check(item.canPlayFastReverse, "AVPlayer can rewind fast")
        player.play()
        _ = wait(3, until: { false })
        // A consumer of the pictures, as a screen would be: without one AVPlayer (macOS) accepts 8× but
        // doesn't move the playhead.
        item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        player.rate = 8
        _ = wait(6, until: { false })
        let forward = item.currentTime().seconds
        print("[TrickPlay] 8×: at \(forward) s, rate \(player.rate), \(remux.iFramesServed) I-frames served")
        player.rate = -8
        _ = wait(4, until: { false })
        let back = item.currentTime().seconds
        print("[TrickPlay] −8×: at \(back) s, \(remux.iFramesServed) I-frames served")
        player.rate = 1
        _ = wait(4, until: { false })
        check(item.status == .readyToPlay, "still playable", "\(String(describing: item.error))")
        check(remux.iFramesServed > 0, "AVPlayer fetched I-frames", "\(remux.iFramesServed)")
        check(forward > 20, "8× moved the playhead well ahead", "\(forward)")
        check(back < forward, "−8× moved it back", "\(back) < \(forward)")
        let errors = item.errorLog()?.events ?? []
        for event in errors { print("[TrickPlay] error log: \(event.errorStatusCode) \(event.errorDomain) \(event.uri ?? "") \(event.errorComment ?? "")") }
        check(errors.isEmpty, "no error in AVPlayer's log", "\(errors.count)")
        player.pause()
    }

    /// With `PT_TRICKPLAY_MKV` and `PT_TRICKPLAY_SERVE=<seconds>`: serves that MKV's remux on
    /// 127.0.0.1 for that long and writes its master URL to `PT_TRICKPLAY_URL_FILE` (when set) —
    /// for an `AVPlayerViewController` in the Apple TV simulator, which reaches the Mac's loopback,
    /// to show the scrubbing thumbnails. Skipped without both variables.
    func testServesTheRemuxForASimulator() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PT_TRICKPLAY_MKV"], !path.isEmpty,
              let seconds = environment["PT_TRICKPLAY_SERVE"].flatMap(Double.init), seconds > 0 else {
            throw XCTSkip("set PT_TRICKPLAY_MKV and PT_TRICKPLAY_SERVE")
        }
        RemuxPlayback.uptimeProvider = nil
        let remux = RemuxPlayback(localFile: URL(fileURLWithPath: path), streamer: nil)
        var ready: URL?
        remux.onReady = { ready = $0 }
        remux.start()
        defer { remux.stop() }
        let deadline = Date(timeIntervalSinceNow: 60)
        while ready == nil, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard let url = ready else { return check(false, "the remux gets ready") }
        print("[TrickPlay] serving \(url) for \(Int(seconds)) s")
        if let file = environment["PT_TRICKPLAY_URL_FILE"] { try url.absoluteString.write(toFile: file, atomically: true, encoding: .utf8) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        print("[TrickPlay] \(remux.iFramesServed) I-frames served")
    }

    func testNoIFramesBeforeTheSessionIsReady() {
        guard let files = temporaryInput(Data()) else { return }
        let remux = RemuxPlayback(localFile: files.input, streamer: nil)
        remux.startsTicksOnDemand = false
        defer { remux.stop() }
        check(remux.iFrameSegment(index: 0) == nil, "no session: nil (the handler answers 503, not 404)")
    }
}
