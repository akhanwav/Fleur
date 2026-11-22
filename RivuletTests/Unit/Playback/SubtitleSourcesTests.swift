import Compression
import XCTest
@testable import Rivulet

@MainActor
final class SubtitleSourcesTests: XCTestCase {

    private func candidate(_ release: String, hash: Bool = false, downloads: Int? = nil,
                           rating: Double? = nil, origin: SubtitleOrigin = .openSubtitles) -> SubtitleCandidate {
        SubtitleCandidate(id: release, origin: origin, release: release, language: "en", isHearingImpaired: false,
                          isForced: false, downloads: downloads, rating: rating, isHashMatch: hash,
                          payload: .openSubtitles(fileID: 1))
    }

    // MARK: Ranking

    func test_ranking_hashMatchFirst_thenRelease_thenDownloads_thenRating() {
        let file = "Shivers.1975.720p.BluRay.x264-AMIABLE.mkv"
        let ranked = SubtitleRanking.sorted([
            candidate("Shivers 1975 DVDRip", downloads: 90_000),
            candidate("Shivers.1975.720p.BluRay.x264-AMIABLE", downloads: 10),
            candidate("Something.Else", hash: true),
            candidate("Shivers 1975 DVDRip.", downloads: 90_000, rating: 9),
        ], fileName: file).map(\.release)
        XCTAssertEqual(ranked, ["Something.Else", "Shivers.1975.720p.BluRay.x264-AMIABLE",
                                "Shivers 1975 DVDRip.", "Shivers 1975 DVDRip"])
    }

    func test_releaseScore_groupMatchCountsExtra() {
        let file = "Movie.2020.1080p.WEB-DL.x264-GRP.mkv"
        XCTAssertGreaterThan(SubtitleRanking.releaseScore("Movie.2020.1080p.WEB-DL.x264-GRP", fileName: file),
                             SubtitleRanking.releaseScore("Movie.2020.1080p.WEB-DL.x264-OTHER", fileName: file))
        XCTAssertEqual(SubtitleRanking.releaseScore("", fileName: file), 0)
    }

    // MARK: Hash

    func test_hash_isSizePlusLittleEndianWords() {
        var head = Data(count: 65_536), tail = Data(count: 65_536)
        head[0] = 1          // word 1
        tail[8] = 2          // word 2
        tail[65_535] = 0x80  // last word's high byte: wraps past 2^64 with the size
        let size = 1 << 20
        let expected = UInt64(size) &+ 1 &+ 2 &+ (UInt64(0x80) << 56)
        XCTAssertEqual(OpenSubtitlesHash.hash(size: size, head: head, tail: tail),
                       String(format: "%016llx", expected))
        XCTAssertNil(OpenSubtitlesHash.hash(size: 100_000, head: head, tail: tail))
    }

    // MARK: ZIP

    private func zip(_ entries: [(String, Data, deflate: Bool)]) -> Data {
        var out = Data(), central = Data()
        func put(_ data: inout Data, _ fields: [(Int, Int)]) {
            for (value, width) in fields { for i in 0..<width { data.append(UInt8(value >> (8 * i) & 0xff)) } }
        }
        for (name, data, deflate) in entries {
            var body = data
            if deflate {
                var buffer = [UInt8](repeating: 0, count: data.count + 64)
                let n = data.withUnsafeBytes {
                    compression_encode_buffer(&buffer, buffer.count, $0.bindMemory(to: UInt8.self).baseAddress!,
                                              data.count, nil, COMPRESSION_ZLIB)
                }
                body = Data(buffer[0..<n])
            }
            let name8 = Data(name.utf8)
            let offset = out.count
            let method = deflate ? 8 : 0
            put(&out, [(0x0403_4b50, 4), (20, 2), (0, 2), (method, 2), (0, 4), (0, 4),
                       (body.count, 4), (data.count, 4), (name8.count, 2), (0, 2)])
            out.append(name8)
            out.append(body)
            put(&central, [(0x0201_4b50, 4), (20, 2), (20, 2), (0, 2), (method, 2), (0, 4), (0, 4),
                           (body.count, 4), (data.count, 4), (name8.count, 2), (0, 2), (0, 2), (0, 2), (0, 2),
                           (0, 4), (offset, 4)])
            central.append(name8)
        }
        let cdOffset = out.count
        out.append(central)
        put(&out, [(0x0605_4b50, 4), (0, 2), (0, 2), (entries.count, 2), (entries.count, 2),
                   (central.count, 4), (cdOffset, 4), (0, 2)])
        return out
    }

    func test_zip_readsStoredAndDeflated_andPicksTheEpisode() {
        let text = Data(String(repeating: "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n", count: 40).utf8)
        let archive = zip([("readme.txt", Data("x".utf8), false),
                           ("Show.S01E01.srt", Data("one".utf8), false),
                           ("Show.S01E02.srt", text, true)])
        let entries = ZipArchive.entries(in: archive)
        XCTAssertEqual(entries.map(\.name), ["readme.txt", "Show.S01E01.srt", "Show.S01E02.srt"])
        XCTAssertEqual(entries.last?.data, text)
        let pick = ZipArchive.subtitleFile(in: archive, season: 1, episode: 2)
        XCTAssertEqual(pick?.data, text)
        XCTAssertEqual(pick?.format, "srt")
        XCTAssertEqual(ZipArchive.subtitleFile(in: archive, season: nil, episode: nil)?.data, Data("one".utf8))
        XCTAssertNil(ZipArchive.subtitleFile(in: Data("not a zip".utf8), season: nil, episode: nil))
    }

    // MARK: Text

    func test_text_stripsBOM_andReadsWindows1252() {
        XCTAssertEqual(SubtitleText.decode(Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8)), "Hi")
        XCTAssertEqual(SubtitleText.decode(Data([0x43, 0x61, 0x66, 0xE9])), "Café")
    }

    // MARK: Origin and labels

    private func stream(key: String?, title: String? = nil, sourceKey: String? = nil,
                        provider: String? = nil, hi: Bool = false) -> PlexStream {
        var stream = PlexStream(
            _id: 7, streamType: 3, index: key == nil ? 3 : nil, codec: "srt", codecID: nil,
            language: "English", languageCode: "eng", languageTag: "en", displayTitle: "English", title: title,
            default: false, forced: false, selected: false, bitDepth: nil, chromaLocation: nil,
            chromaSubsampling: nil, colorPrimaries: nil, colorRange: nil, colorSpace: nil, colorTrc: nil,
            DOVIBLCompatID: nil, DOVIBLPresent: nil, DOVIELPresent: nil, DOVILevel: nil, DOVIPresent: nil,
            DOVIProfile: nil, DOVIRPUPresent: nil, DOVIVersion: nil, frameRate: nil, height: nil, width: nil,
            level: nil, profile: nil, refFrames: nil, scanType: nil, audioChannelLayout: nil, channels: nil,
            bitrate: nil, samplingRate: nil, format: "srt", key: key, extendedDisplayTitle: nil,
            hearingImpaired: hi)
        stream.sourceKey = sourceKey
        stream.providerTitle = provider
        return stream
    }

    func test_origin() {
        XCTAssertEqual(SubtitleOrigin(stream(key: nil)), .embedded)
        XCTAssertEqual(SubtitleOrigin(stream(key: "/library/streams/1")), .externalFile)
        XCTAssertEqual(SubtitleOrigin(stream(key: "/library/streams/1", sourceKey: "/library/streams/9",
                                             provider: "OpenSubtitles")), .plexSearch)
        XCTAssertEqual(SubtitleOrigin(stream(key: "file:///x/1.srt", provider: "SubSource")), .subSource)
        XCTAssertEqual(SubtitleOrigin(stream(key: "file:///x/1.srt", provider: "OpenSubtitles")), .openSubtitles)
    }

    func test_playerRow_namesOrigin_downloaded_andRelease() {
        let track = MediaTrack(from: stream(key: "/library/streams/1", title: "Shivers.1975.720p-AMIABLE",
                                            sourceKey: "/library/streams/9", provider: "OpenSubtitles", hi: true))
        XCTAssertEqual(SubtitleLabels.title(track), "English SDH · SRT")
        XCTAssertEqual(SubtitleLabels.detail(track), "Plex search · Downloaded · Shivers.1975.720p-AMIABLE")
        // A title that only repeats the language is not a release name.
        XCTAssertEqual(SubtitleLabels.detail(MediaTrack(from: stream(key: nil, title: "English"))), "Embedded")
    }

    func test_resultDetail() {
        let row = SubtitleLabels.resultDetail(candidate("R", hash: true, downloads: 1234, rating: 8.5))
        XCTAssertEqual(row, "OpenSubtitles · Exact match · 1,234 downloads · ★ 8.5 · English")
    }

    func test_quotaMessage() {
        XCTAssertEqual(SubtitleSourceError.quotaExceeded(resets: "5 hours").message(.openSubtitles),
                       "OpenSubtitles daily download limit reached. It resets in 5 hours.")
        XCTAssertEqual(SubtitleSourceError.rateLimited(retryAfter: 600).message(.subSource),
                       "SubSource is busy. Try again in 10 minutes.")
    }
}
