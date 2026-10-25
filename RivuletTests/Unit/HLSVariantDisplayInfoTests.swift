// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class HLSVariantDisplayInfoTests: XCTestCase {

    /// The shape PMS serves for a transcode (measured, 1.43.x).
    func test_plexTranscodeMaster_givesRateRangeAndSize() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=7553000,RESOLUTION=1920x1080,FRAME-RATE=23.976000,VIDEO-RANGE=PQ,SUBTITLES="vtt-base"
        session/abc/base/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:RESOLUTION=320x180,BANDWIDTH=1000000,URI="session/abc/keyframes/index.m3u8"
        """
        XCTAssertEqual(HLSVariantDisplayInfo.parse(master: master),
                       HLSVariantDisplayInfo(frameRate: 23.976, range: .pq, width: 1920, height: 1080))
    }

    func test_noVideoRange_isSDR_andQuotedCommasDoNotSplit() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=25.000
        index.m3u8
        """
        let info = HLSVariantDisplayInfo.parse(master: master)
        XCTAssertEqual(info?.range, .sdr)
        XCTAssertEqual(info?.frameRate, 25)
        XCTAssertNil(info?.width)
    }

    func test_hlg_andMissingRate() {
        let info = HLSVariantDisplayInfo.parse(master: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=HLG\nv.m3u8")
        XCTAssertEqual(info?.range, .hlg)
        XCTAssertNil(info?.frameRate)
    }

    func test_mediaPlaylist_hasNoVariant() {
        XCTAssertNil(HLSVariantDisplayInfo.parse(master: "#EXTM3U\n#EXTINF:5,\n0.ts"))
    }
}
