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

    func test_sort_byPercent_thenDownloads_andByColumn() {
        func scored(_ name: String, _ percent: Int, downloads: Int? = nil, rating: Double? = nil) -> SubtitleCandidate {
            var c = candidate(name, downloads: downloads, rating: rating)
            c.matchPercent = percent
            return c
        }
        let list = [scored("a", 40, downloads: 900), scored("b", 95, downloads: 1), scored("c", 40, downloads: 5, rating: 9)]
        XCTAssertEqual(SubtitleSort.sorted(list).map(\.release), ["b", "a", "c"])
        XCTAssertEqual(SubtitleSort.sorted(list, by: .downloads).map(\.release), ["a", "c", "b"])
        XCTAssertEqual(SubtitleSort.sorted(list, by: .rating).map(\.release), ["c", "b", "a"])
    }

    // MARK: Release names

    func test_parse_sceneEpisode() {
        let i = ReleaseParser.parse("Chainsaw.Man.S01E01.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG.mkv")
        XCTAssertEqual(i.season, 1); XCTAssertEqual(i.episode, 1)
        XCTAssertEqual(i.source, "WEB-DL"); XCTAssertEqual(i.service, "CR")
        XCTAssertEqual(i.resolution, "1080p"); XCTAssertEqual(i.codec, "H.264")
        XCTAssertEqual(i.group, "VARYG")
        XCTAssertEqual(i.cleanName, "VARYG · CR WEB-DL · 1080p")
    }

    func test_parse_animeGroupInBrackets_absoluteEpisode() {
        let i = ReleaseParser.parse("[SubsPlease] Chainsaw Man - 01 (1080p) [A1B2C3D4].mkv")
        XCTAssertEqual(i.group, "SubsPlease"); XCTAssertNil(i.season); XCTAssertEqual(i.episode, 1)
        XCTAssertEqual(i.resolution, "1080p")
    }

    func test_parse_seasonPack_andKinds() {
        let pack = ReleaseParser.parse("Chainsaw.Man.S01.1080p.BluRay.x265-Group")
        XCTAssertTrue(pack.isSeasonPack); XCTAssertEqual(pack.season, 1); XCTAssertNil(pack.episode)
        XCTAssertEqual(pack.source, "BluRay"); XCTAssertEqual(pack.codec, "H.265")
        XCTAssertTrue(ReleaseParser.parse("Show.S01E01.Signs.and.Songs").isSignsAndSongs)
        XCTAssertTrue(ReleaseParser.parse("Show S01E01 Dubtitles").isDubtitle)
        XCTAssertTrue(ReleaseParser.parse("Movie.2020.1080p.WEB.SDH").isHearingImpaired)
        XCTAssertTrue(ReleaseParser.parse("Movie.2020.1080p.WEB-GRP.eng.HI").isHearingImpaired)
        XCTAssertTrue(ReleaseParser.parse("Movie [HI] 1080p").isHearingImpaired)
        XCTAssertTrue(ReleaseParser.parse("Movie.2020.Hearing.Impaired").isHearingImpaired)
        XCTAssertFalse(ReleaseParser.parse("Movie.2020.1080p.WEB-GRP").isHearingImpaired)
        XCTAssertNil(ReleaseParser.parse("Movie.2020.1080p.WEB-DL.DD5.1").group)
        XCTAssertTrue(ReleaseParser.parse("Chainsaw Man Ep 1-12").isSeasonPack)
        XCTAssertEqual(ReleaseParser.parse("Chainsaw Man Ep02").episode, 2)
        XCTAssertEqual(ReleaseParser.parse("Chainsaw.Man.S01E01.(480p-720p-1080p).[SubsPlease]").group, "SubsPlease")
        let cr = ReleaseParser.parse("[CR] Chainsaw Man S01E01 DOG & CHAINSAW.en-US")
        XCTAssertEqual(cr.service, "CR"); XCTAssertNil(cr.group)
        XCTAssertEqual(ReleaseParser.parse("Chainsaw Man (2022) - S01E01.001 - DOG [Bluray-1080p Remux][AVC]-E.N.D.mkv").group, "E.N.D")
    }

    // MARK: Match %

    private let file = SubtitleMatch.FileFacts(
        release: ReleaseParser.parse("Chainsaw.Man.S01E01.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG.mkv"),
        frameRate: 23.976, season: 1, episode: 1, isEpisode: true)

    private func percent(_ name: String, season: Int? = nil, episode: Int? = nil, fps: Double? = nil,
                         hash: Bool = false) -> Int {
        SubtitleMatch.percent(ReleaseParser.parse(name), frameRate: fps, season: season, episode: episode,
                              isHashMatch: hash, file: file)
    }

    func test_percent_hashIs100_wrongEpisodeIs0_packCounts() {
        XCTAssertEqual(percent("anything", hash: true), 100)
        XCTAssertEqual(percent("Chainsaw.Man.S01E02.1080p.CR.WEB-DL.H.264-VARYG"), 0)
        XCTAssertEqual(percent("Chainsaw.Man.S02E01.1080p.WEB-DL-VARYG"), 0)
        XCTAssertGreaterThan(percent("Chainsaw.Man.S01.1080p.CR.WEB-DL.H.264-VARYG"), 0)
    }

    func test_percent_groupAndSourceWeighMost() {
        let same = percent("Chainsaw.Man.S01E01.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG", fps: 23.976)
        let otherResolution = percent("Chainsaw.Man.S01E01.720p.CR.WEB-DL.H.265-VARYG")
        let otherGroup = percent("Chainsaw.Man.S01E01.1080p.CR.WEB-DL.H.264-SubsPlease")
        let bluray = percent("Chainsaw.Man.S01E01.1080p.BluRay.H.264-VARYG")
        XCTAssertEqual(same, 99)
        XCTAssertGreaterThanOrEqual(otherResolution, 90)
        XCTAssertLessThan(otherGroup, 75)
        XCTAssertLessThan(bluray, otherResolution)
        XCTAssertLessThan(percent("Chainsaw Man 01"), 40)
        XCTAssertEqual(SubtitleMatch.kind(ReleaseParser.parse("Chainsaw.Man.S01E01.720p.WEB-VARYG"),
                                          isHashMatch: false, file: file), .release)
        XCTAssertEqual(SubtitleMatch.kind(ReleaseParser.parse("Chainsaw.Man.S01E01.BluRay-VARYG"),
                                          isHashMatch: false, file: file), .title)
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

    // MARK: Filter

    func test_filterTabs_countEachSearchedSource() {
        let results = [candidate("a"), candidate("b"), candidate("c", origin: .subSource)]
        let tabs = SubtitleResultFilter.tabs(for: results, searched: [.plexSearch, .openSubtitles, .subSource])
        XCTAssertEqual(tabs.map(\.title), ["All (3)", "Plex (0)", "OpenSubtitles (2)", "SubSource (1)"])
        XCTAssertEqual(results.filter(SubtitleResultFilter.source(.subSource).matches).map(\.release), ["c"])
        XCTAssertEqual(results.filter(SubtitleResultFilter.all.matches).count, 3)
    }

    // MARK: Stuck menu

    /// A menu of status lines only (a failed download) must still hold focus,
    /// or Menu never reaches it and the screen is stuck.
    func test_menuWithNoEnabledRow_stillOffersFocus() throws {
        let popup = TileMenuPopupViewController(sections: [[
            TileMenuAction(title: "SubSource isn't responding.", systemImage: "exclamationmark.circle",
                           isEnabled: false) {},
        ]])
        popup.loadViewIfNeeded()
        let preferred = try XCTUnwrap(popup.preferredFocusEnvironments.first as? UIView)
        XCTAssertTrue(preferred.canBecomeFocused)
    }

    func test_menuWithAnEnabledRow_focusesTheRow_notTheAnchor() throws {
        let popup = TileMenuPopupViewController(sections: [[
            TileMenuAction(title: "Note", systemImage: "circle", isEnabled: false) {},
            TileMenuAction(title: "Pick", systemImage: "circle") {},
        ]])
        popup.loadViewIfNeeded()
        let preferred = try XCTUnwrap(popup.preferredFocusEnvironments.first as? UIView)
        XCTAssertTrue(preferred.canBecomeFocused)
        XCTAssertNotNil(preferred.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Pick" })
    }

    // MARK: Store

    func test_store_writesToCaches() throws {
        let saved = try LocalSubtitleStore.save(text: "1\n00:00:01,000 --> 00:00:02,000\nHi\n", format: "srt",
                                                server: "test-server", ratingKey: "unit-\(UUID().uuidString)",
                                                origin: .subSource, release: "R", language: "en",
                                                isHearingImpaired: false, isForced: false)
        let url = LocalSubtitleStore.fileURL(saved)
        XCTAssertTrue(url.path.contains("/Library/Caches/Subtitles/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Table

    func test_table_hidesOtherEpisodes_untilAsked_andFilters() {
        func c(_ name: String, origin: SubtitleOrigin = .openSubtitles, language: String = "en", hi: Bool = false) -> SubtitleCandidate {
            SubtitleCandidate(id: name, origin: origin, release: name, language: language, isHearingImpaired: hi,
                              isForced: false, downloads: nil, rating: nil, isHashMatch: false,
                              payload: .openSubtitles(fileID: 1))
        }
        let list = [c("Chainsaw.Man.S01E01.WEB-VARYG"), c("Chainsaw.Man.S01E02.WEB-VARYG"),
                    c("Chainsaw.Man.S01.BluRay-X", origin: .subSource), c("Chainsaw Man Ep01", language: "es", hi: true)]
        var state = SubtitleTableState()
        XCTAssertEqual(state.rows(list, file: file).map(\.id).sorted(),
                       ["Chainsaw Man Ep01", "Chainsaw.Man.S01.BluRay-X", "Chainsaw.Man.S01E01.WEB-VARYG"])
        state.showsOtherEpisodes = true
        XCTAssertEqual(state.rows(list, file: file).count, 4)
        state.language = "es"
        XCTAssertEqual(state.rows(list, file: file).map(\.id), ["Chainsaw Man Ep01"])
        state.language = nil
        state.sdh = true
        XCTAssertEqual(state.rows(list, file: file).map(\.id), ["Chainsaw Man Ep01"])
        state.sdh = false
        XCTAssertEqual(state.rows(list, file: file).count, 3)
        state.sdh = nil
        state.source = .source(.subSource)
        XCTAssertEqual(state.rows(list, file: file).map(\.id), ["Chainsaw.Man.S01.BluRay-X"])
        // A movie hides nothing.
        XCTAssertEqual(SubtitleTableState(showsOtherEpisodes: false).rows(list, file: nil).count, 4)
    }

    func test_columns_fillTheRow() {
        let columns = SubtitleColumn.columns(isEpisode: true)
        let frames = SubtitleColumn.frames(width: 1760, columns: columns)
        let last = frames[.percent]!
        XCTAssertEqual(last.x + last.width, 1760 - SubtitleColumn.rowPadding, accuracy: 0.5)
        XCTAssertGreaterThan(frames[.release]!.width, 350)
        XCTAssertNil(SubtitleColumn.frames(width: 1760, columns: SubtitleColumn.columns(isEpisode: false))[.episode])
    }
}
