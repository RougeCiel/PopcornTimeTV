import Foundation

// Trick play (5.5.1): the I-frame rendition that gives AVPlayer its preview
// thumbnails while the viewer scrubs, fast-forwards or rewinds — on Apple TV
// the pictures above the transport bar.
//
// Served by `RemuxPlayback`, next to the video rendition:
//  - `iframes.m3u8`: `#EXT-X-I-FRAMES-ONLY` VOD playlist, one entry per video
//    segment of the frozen list (same EXTINF, same count: each video segment
//    starts at a keyframe, so its I-frame stands for the whole segment), the
//    video init segment as `#EXT-X-MAP` — listed in the master with
//    `#EXT-X-I-FRAME-STREAM-INF`, carrying the video's own CODECS,
//    SUPPLEMENTAL-CODECS (Dolby Vision) and VIDEO-RANGE (PQ / HLG / SDR);
//  - `iframe{K}.m4s`: one moof + mdat holding a single sample — the keyframe
//    that opens `vseg{K}.m4s`, copied byte for byte from that file. The
//    samples are the ones the video rendition plays (Dolby Vision RPUs kept,
//    converted to HDR10+ or stripped exactly as the setting made them), so
//    the I-frames decode with the same init segment and the same codecs.
//
// What the I-frames never do: read the torrent, wait, steer the remux or
// answer 404. An I-frame is made from a segment the remux already wrote and
// still keeps. When `vseg{K}` is not there — not remuxed yet (the download
// hasn't reached it), a hole a jump skipped, a segment the disk budget
// deleted — `iframe{K}` is made from the nearest segment that is, its
// timestamps moved to K's start (`sourceOrder`): the thumbnail stops at the
// edge of what is on disk instead of failing. The players hand over to VLC
// on any HTTP 404 in an AVPlayer error (404 means « gone for good » on this
// server), and an I-frame request must not anchor the remux's lookahead nor
// hold a GCDWebServer connection: the I-frame requests go through their own
// handler, never through the media segments' long-poll.
//
// Not covered (no change there): EVENT sessions (no Duration in the header,
// the list grows: no I-frame stream is announced), MP4 files AVPlayer reads
// straight from the torrent (no playlist of ours — AVFoundation makes its own
// thumbnails only for HLS I-frame streams), and VLC.

enum RemuxIFrames {

    static let playlistName = "iframes.m3u8"
    static let segmentPrefix = "iframe"
    static let segmentExtension = "m4s"

    /// The user default that turns the I-frame stream off (`YES`): no
    /// `#EXT-X-I-FRAME-STREAM-INF` in the master, AVPlayer scrubs without
    /// thumbnails, as before 5.5.1.
    static let disabledDefaultsKey = "PTTrickPlayDisabled"

    static var isDisabled: Bool { UserDefaults.standard.bool(forKey: disabledDefaultsKey) }

    /// `iframe{K}.m4s` → K.
    static func segmentIndex(_ name: String) -> Int? {
        let suffix = "." + segmentExtension
        guard name.hasPrefix(segmentPrefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(segmentPrefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    // MARK: - Reading the keyframe that opens a video segment

    /// The first sample of the first track of a media segment's first moof.
    struct Keyframe: Equatable {
        let trackID: UInt32
        /// tfdt, in the track's timescale.
        let baseDecodeTime: UInt64
        let duration: UInt32
        let compositionOffset: Int32
        /// Where the sample's bytes are, from the start of the segment file.
        let dataOffset: Int
        let size: Int
    }

    /// Parses the boxes of a media segment up to the end of its first moof
    /// (`data`: at least that much of the file; boxes before the moof — styp,
    /// sidx, emsg — are skipped) → its first sample, when it is a sync sample.
    /// nil: no complete moof in `data`, no sample, or a first sample that is
    /// not a keyframe (a tail filler).
    static func firstKeyframe(inSegmentHeader data: Data) -> Keyframe? {
        let data = zeroBased(data)
        var reader = BoxCursor(data: data)
        while let header = reader.nextBox() {
            guard header.type == "moof" else { reader.skip(header); continue }
            guard header.end <= data.count else { return nil }
            return parseMoof(data, start: header.start, payload: header.payloadStart, end: header.end)
        }
        return nil
    }

    /// Bytes to read from the start of a segment to hold its first moof:
    /// nil when `data` doesn't reach the moof's header yet, else the moof's
    /// end (which may lie past `data`).
    static func bytesThroughFirstMoof(_ data: Data) -> Int? {
        let data = zeroBased(data)
        var reader = BoxCursor(data: data)
        while let header = reader.nextBox() {
            if header.type == "moof" { return header.end }
            reader.skip(header)
        }
        return nil
    }

    /// The video track's timescale, from the init segment's mdhd.
    static func timescale(ofInitSegment data: Data) -> UInt32? {
        let data = zeroBased(data)
        guard let mdhd = findBox(["moov", "trak", "mdia", "mdhd"], in: data, range: 0..<data.count) else { return nil }
        let version = data[mdhd.payloadStart]
        let offset = mdhd.payloadStart + 4 + (version == 1 ? 16 : 8)
        guard offset + 4 <= mdhd.end else { return nil }
        let value = readU32(data, offset)
        return value > 0 ? value : nil
    }

    /// Reads the keyframe that opens the segment file at `url` and its bytes.
    /// nil when the file is missing, truncated or doesn't start with a
    /// keyframe. Reads the moof and the one sample, never the whole segment.
    static func readKeyframe(segmentAt url: URL) -> (keyframe: Keyframe, sample: Data)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: 64 << 10), !head.isEmpty else { return nil }
        guard let moofEnd = bytesThroughFirstMoof(head), moofEnd <= 16 << 20 else { return nil }
        if moofEnd > head.count {
            guard let more = try? handle.read(upToCount: moofEnd - head.count) else { return nil }
            head.append(more)
        }
        guard let keyframe = firstKeyframe(inSegmentHeader: head), keyframe.size > 0, keyframe.size <= 256 << 20 else {
            return nil
        }
        do {
            try handle.seek(toOffset: UInt64(keyframe.dataOffset))
            guard let sample = try handle.read(upToCount: keyframe.size), sample.count == keyframe.size else { return nil }
            return (keyframe, sample)
        } catch {
            return nil
        }
    }

    // MARK: - Writing an I-frame segment

    /// One moof + mdat holding `sample` alone (sync), at `baseDecodeTime`
    /// (the keyframe's own tfdt unless a substitute is moved elsewhere).
    static func fragment(keyframe: Keyframe, sample: Data, sequence: UInt32, baseDecodeTime: UInt64? = nil) -> Data {
        let config = FMP4Muxer.TrackConfig(trackID: keyframe.trackID, timescale: 1, handler: .video, sampleEntry: Data())
        let entry = FMP4Muxer.Sample(data: sample, duration: max(1, keyframe.duration), sync: true,
                                     compositionOffset: keyframe.compositionOffset)
        return FMP4Muxer.mediaSegment(sequence: sequence,
                                      trackSamples: [(config: config, baseDecodeTime: baseDecodeTime ?? keyframe.baseDecodeTime,
                                                      samples: [entry])])
    }

    /// The tfdt of a keyframe borrowed from the segment starting at
    /// `sourceStart` (s, player timeline) to stand for the one starting at
    /// `targetStart`: shifted by the difference, never below 0.
    static func movedDecodeTime(_ time: UInt64, sourceStart: Double, targetStart: Double, timescale: UInt32) -> UInt64 {
        let delta = (targetStart - sourceStart) * Double(timescale)
        guard delta.isFinite else { return time }
        let moved = Double(time) + delta.rounded()
        return moved <= 0 ? 0 : UInt64(min(moved, Double(UInt64.max >> 1)))
    }

    /// The segments to try for `iframe{requested}`, nearest first — the
    /// requested one, then one before, one after, two before… — within
    /// `0 ..< count`: the earlier one wins a tie, so a scrub past the remux
    /// frontier shows its last picture.
    static func sourceOrder(requested: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(0, requested), count - 1)
        var order = [start]
        var distance = 1
        while start - distance >= 0 || start + distance < count {
            if start - distance >= 0 { order.append(start - distance) }
            if start + distance < count { order.append(start + distance) }
            distance += 1
        }
        return order
    }

    /// BANDWIDTH of the I-frame stream (peak bits per second of the I-frames
    /// on the timeline), estimated from one keyframe of `keyframeBytes` per
    /// `secondsPerKeyframe` with twice that as headroom — a larger keyframe
    /// elsewhere in the film. nil without a usable measure.
    static func bandwidth(keyframeBytes: Int, secondsPerKeyframe: Double) -> Int? {
        guard keyframeBytes > 0, secondsPerKeyframe.isFinite, secondsPerKeyframe > 0 else { return nil }
        let bits = Double(keyframeBytes) * 8 / max(1, secondsPerKeyframe) * 2
        return Int(min(bits.rounded(.up), Double(Int32.max)))
    }

    // MARK: - Boxes

    private struct BoxHeader {
        let type: String
        let start: Int
        let payloadStart: Int
        let end: Int
    }

    private struct BoxCursor {
        let data: Data
        var offset: Int
        let limit: Int

        init(data: Data, range: Range<Int>? = nil) {
            self.data = data
            self.offset = range?.lowerBound ?? 0
            self.limit = range?.upperBound ?? data.count
        }

        /// The header of the box at the cursor (its end may lie past `limit`
        /// for the box being read); nil past the end or on a malformed size.
        mutating func nextBox() -> BoxHeader? {
            guard offset + 8 <= limit else { return nil }
            var size = Int(readU32(data, offset))
            var payload = offset + 8
            if size == 1 {
                guard offset + 16 <= limit else { return nil }
                let large = (UInt64(readU32(data, offset + 8)) << 32) | UInt64(readU32(data, offset + 12))
                guard large <= UInt64(Int.max / 2) else { return nil }
                size = Int(large)
                payload = offset + 16
            } else if size == 0 {
                size = limit - offset
            }
            guard size >= payload - offset else { return nil }
            let typeBytes = data[(offset + 4)..<(offset + 8)]
            let type = String(decoding: typeBytes, as: UTF8.self)
            return BoxHeader(type: type, start: offset, payloadStart: payload, end: offset + size)
        }

        mutating func skip(_ header: BoxHeader) { offset = header.end }
    }

    /// Every offset below counts from 0: a slice is copied first.
    private static func zeroBased(_ data: Data) -> Data { data.startIndex == 0 ? data : Data(data) }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16) | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        (UInt64(readU32(data, offset)) << 32) | UInt64(readU32(data, offset + 4))
    }

    /// The box at `path` (each level a child of the previous one).
    private static func findBox(_ path: [String], in data: Data, range: Range<Int>) -> BoxHeader? {
        guard let first = path.first else { return nil }
        var cursor = BoxCursor(data: data, range: range)
        while let header = cursor.nextBox() {
            guard header.end <= range.upperBound else { return nil }
            if header.type == first {
                if path.count == 1 { return header }
                return findBox(Array(path.dropFirst()), in: data, range: header.payloadStart..<header.end)
            }
            cursor.skip(header)
        }
        return nil
    }

    private static func parseMoof(_ data: Data, start: Int, payload: Int, end: Int) -> Keyframe? {
        guard let traf = findBox(["traf"], in: data, range: payload..<end) else { return nil }
        var cursor = BoxCursor(data: data, range: traf.payloadStart..<traf.end)
        var trackID: UInt32?
        var base = start // default-base-is-moof, and the moof without base-data-offset
        var defaultDuration: UInt32 = 0
        var defaultSize: UInt32 = 0
        var defaultFlags: UInt32 = 0
        var decodeTime: UInt64 = 0
        var keyframe: Keyframe?
        while let box = cursor.nextBox() {
            guard box.end <= traf.end else { return nil }
            let p = box.payloadStart
            switch box.type {
            case "tfhd":
                guard p + 8 <= box.end else { return nil }
                let flags = readU32(data, p) & 0x00FF_FFFF
                trackID = readU32(data, p + 4)
                var q = p + 8
                if flags & 0x01 != 0 { guard q + 8 <= box.end else { return nil }; base = Int(clamping: readU64(data, q)); q += 8 }
                if flags & 0x02 != 0 { q += 4 }
                if flags & 0x08 != 0 { guard q + 4 <= box.end else { return nil }; defaultDuration = readU32(data, q); q += 4 }
                if flags & 0x10 != 0 { guard q + 4 <= box.end else { return nil }; defaultSize = readU32(data, q); q += 4 }
                if flags & 0x20 != 0 { guard q + 4 <= box.end else { return nil }; defaultFlags = readU32(data, q); q += 4 }
            case "tfdt":
                guard p + 8 <= box.end else { return nil }
                let version = data[data.startIndex + p]
                if version == 1 {
                    guard p + 12 <= box.end else { return nil }
                    decodeTime = readU64(data, p + 4)
                } else {
                    decodeTime = UInt64(readU32(data, p + 4))
                }
            case "trun":
                guard let id = trackID, p + 8 <= box.end else { return nil }
                let word = readU32(data, p)
                let flags = word & 0x00FF_FFFF
                let count = readU32(data, p + 4)
                guard count > 0 else { return nil }
                var q = p + 8
                var dataOffset: Int32 = 0
                var firstFlags: UInt32?
                if flags & 0x001 != 0 { guard q + 4 <= box.end else { return nil }; dataOffset = Int32(bitPattern: readU32(data, q)); q += 4 }
                if flags & 0x004 != 0 { guard q + 4 <= box.end else { return nil }; firstFlags = readU32(data, q); q += 4 }
                var duration = defaultDuration
                var size = defaultSize
                var sampleFlags = firstFlags ?? defaultFlags
                var composition: Int32 = 0
                if flags & 0x100 != 0 { guard q + 4 <= box.end else { return nil }; duration = readU32(data, q); q += 4 }
                if flags & 0x200 != 0 { guard q + 4 <= box.end else { return nil }; size = readU32(data, q); q += 4 }
                if flags & 0x400 != 0 {
                    guard q + 4 <= box.end else { return nil }
                    let own = readU32(data, q); q += 4
                    if firstFlags == nil { sampleFlags = own }
                }
                if flags & 0x800 != 0 { guard q + 4 <= box.end else { return nil }; composition = Int32(bitPattern: readU32(data, q)) }
                // sample_is_non_sync_sample (bit 16): set → not a keyframe.
                guard sampleFlags & 0x0001_0000 == 0 else { return nil }
                let offset = base + Int(dataOffset)
                guard offset >= 0, size > 0 else { return nil }
                keyframe = Keyframe(trackID: id, baseDecodeTime: decodeTime, duration: duration,
                                    compositionOffset: composition, dataOffset: offset, size: Int(size))
            default:
                break
            }
            if keyframe != nil { break }
            cursor.skip(box)
        }
        return keyframe
    }
}
