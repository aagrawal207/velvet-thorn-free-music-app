import Foundation

/// Consecutive complete elementary audio frames: two at the response boundary (optionally after one bounded ID3
/// tag), or three from the first sync word when a server joins its stream mid-frame, as Icecast often does.
struct LiveRadioElementaryProof: Sendable {
    enum Format: String, Sendable { case mp3, adts }
    static let maximumBytes = 8_192
    static let maximumID3Bytes = 4_096
    /// A mid-stream join lands inside at most one frame (MP3 tops out near 1.4 KiB); the rest is margin.
    static let maximumSyncSearchBytes = 4_096
    let format: Format
    private let probedURL: URL

    private init(format: Format, probedURL: URL) {
        self.format = format
        self.probedURL = probedURL
    }

    func matches(_ url: URL) -> Bool { probedURL == url && LiveRadioURLPolicy.permits(url) }

    static let mp3ContentTypes: Set<String> = ["audio/mpeg", "audio/mp3", "audio/mpeg3", "audio/x-mpeg", "audio/x-mp3", "audio/mpg"]
    static let adtsContentTypes: Set<String> = ["audio/aac", "audio/aacp", "audio/x-aac", "audio/x-aacp"]

    /// The frame format a response claims. A generic binary type falls back to the directory codec, which the
    /// frame check then has to confirm.
    static func format(contentType: String, stationCodec: String) -> Format? {
        let type = contentType.lowercased()
        if mp3ContentTypes.contains(type) { return .mp3 }
        if adtsContentTypes.contains(type) { return .adts }
        guard type == "application/octet-stream" else { return nil }
        switch stationCodec {
        case "MP3": return .mp3
        case "AAC", "AAC+", "HE-AAC", "HE-AACV2": return .adts
        default: return nil
        }
    }

    static func inspect(_ data: Data, contentType: String, url: URL, stationCodec: String = "") -> Self? {
        guard data.count <= maximumBytes, LiveRadioURLPolicy.permits(url),
              let format = format(contentType: contentType, stationCodec: stationCodec) else { return nil }
        let bytes = Array(data)
        guard !startsWithContainer(bytes), let start = audioOffset(bytes) else { return nil }
        // Some servers label AAC as MPEG audio; the frames, not the header, decide which decoder AVPlayer needs.
        for candidate in [format, format == .mp3 ? Format.adts : .mp3] {
            if let proof = inspect(bytes, from: start, format: candidate, url: url) { return proof }
        }
        return nil
    }

    private static func inspect(_ bytes: [UInt8], from start: Int, format: Format, url: URL) -> Self? {
        if chain(bytes, from: start, format: format, count: 2) { return Self(format: format, probedURL: url) }
        // Three frames from an arbitrary sync word keep a chance 0xFF byte in the payload from passing.
        let end = min(bytes.count, start + maximumSyncSearchBytes)
        var offset = start + 1
        while offset < end {
            if bytes[offset] == 0xFF, chain(bytes, from: offset, format: format, count: 3) {
                return Self(format: format, probedURL: url)
            }
            offset += 1
        }
        return nil
    }

    /// Frames found inside a container or a web page do not make the response an elementary stream.
    private static func startsWithContainer(_ bytes: [UInt8]) -> Bool {
        let magic: [[UInt8]] = [Array("OggS".utf8), Array("RIFF".utf8), Array("fLaC".utf8), [0, 0, 1, 0xBA], [0, 0, 0, 1],
                                Array("<".utf8)]
        if magic.contains(where: { bytes.starts(with: $0) }) { return true }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return true }
        return bytes.first == 0x47 && bytes.count > 188 && bytes[188] == 0x47
    }

    private static func chain(_ bytes: [UInt8], from start: Int, format: Format, count: Int) -> Bool {
        var offset = start
        var identity: Int?
        for _ in 0..<count {
            guard let next = frame(bytes, at: offset, format: format), next.length <= bytes.count - offset,
                  identity == nil || identity == next.identity else { return false }
            identity = next.identity
            offset += next.length
        }
        return true
    }

    private struct Frame {
        let length: Int
        let identity: Int
    }

    private static func audioOffset(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 3 else { return nil }
        guard bytes.starts(with: [0x49, 0x44, 0x33]) else { return 0 }
        guard bytes.count >= 10, (2...4).contains(bytes[3]), bytes[4] != 0xFF,
              bytes[6...9].allSatisfy({ $0 < 128 }) else { return nil }
        let flagsMask: UInt8 = bytes[3] == 2 ? 0xC0 : bytes[3] == 3 ? 0xE0 : 0xF0
        guard bytes[5] & ~flagsMask == 0 else { return nil }
        let size = bytes[6...9].reduce(0) { ($0 << 7) | Int($1) }
        let hasFooter = bytes[3] == 4 && bytes[5] & 0x10 != 0
        let end = 10 + size + (hasFooter ? 10 : 0)
        guard end <= maximumID3Bytes, end <= bytes.count else { return nil }
        if hasFooter {
            let footer = Array(bytes[(end - 10)..<end])
            guard footer == [0x33, 0x44, 0x49] + Array(bytes[3...9]) else { return nil }
        }
        return end
    }

    private static func frame(_ bytes: [UInt8], at offset: Int, format: Format) -> Frame? {
        switch format {
        case .mp3: mp3Frame(bytes, at: offset)
        case .adts: adtsFrame(bytes, at: offset)
        }
    }

    private static func mp3Frame(_ bytes: [UInt8], at offset: Int) -> Frame? {
        guard offset >= 0, bytes.count - offset >= 4 else { return nil }
        let a = bytes[offset], b = bytes[offset + 1], c = bytes[offset + 2], d = bytes[offset + 3]
        let version = Int((b >> 3) & 3)
        let bitrateIndex = Int(c >> 4)
        let rateIndex = Int((c >> 2) & 3)
        guard a == 0xFF, b & 0xE0 == 0xE0, version != 1, (b >> 1) & 3 == 1,
              (1...14).contains(bitrateIndex), rateIndex < 3, d & 3 != 2 else { return nil }
        let rates = [44_100, 48_000, 32_000]
        let bitrates = version == 3
            ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let sampleRate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let length = (version == 3 ? 144_000 : 72_000) * bitrates[bitrateIndex - 1] / sampleRate + Int((c >> 1) & 1)
        let mono = d >> 6 == 3
        let sideInfo = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        guard length > 4 + (b & 1 == 0 ? 2 : 0) + sideInfo else { return nil }
        return Frame(length: length, identity: version * 100 + rateIndex * 10 + (mono ? 1 : 2))
    }

    private static func adtsFrame(_ bytes: [UInt8], at offset: Int) -> Frame? {
        guard offset >= 0, bytes.count - offset >= 7 else { return nil }
        let b = bytes[offset + 1], c = bytes[offset + 2], d = bytes[offset + 3]
        let rateIndex = Int((c >> 2) & 15)
        let profile = Int(c >> 6)
        let channels = Int((c & 1) << 2 | d >> 6)
        let mpegID = Int((b >> 3) & 1)
        guard bytes[offset] == 0xFF, b & 0xF6 == 0xF0, rateIndex <= 12,
              channels > 0, !(mpegID == 1 && profile == 3), bytes[offset + 6] & 3 == 0 else { return nil }
        let length = Int(d & 3) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5] >> 5)
        let headerLength = b & 1 == 0 ? 9 : 7
        guard length > headerLength else { return nil }
        return Frame(length: length, identity: mpegID * 10_000 + profile * 1_000 + rateIndex * 10 + channels)
    }
}

enum LiveRadioSourceProof: Sendable {
    case unverified
    case hls
    case elementary(LiveRadioElementaryProof)
}
