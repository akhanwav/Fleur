// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// `/library/sections` decodes every section whatever its type, and the
/// sidebar and Settings then list the types tvOS has a page for (#33, #325).
final class PlexLibrarySectionListTests: XCTestCase {
    private func sections() throws -> [PlexLibrary] {
        let json = """
        {"MediaContainer":{"size":4,"Directory":[
          {"key":"1","type":"movie","title":"Movies","agent":"tv.plex.agents.movie","scanner":"Plex Movie","language":"en-US","uuid":"u1","hidden":0},
          {"key":"3","type":"artist","title":"Music","agent":"tv.plex.agents.music","scanner":"Plex Music","language":"en-US","uuid":"u3","hidden":2},
          {"key":"6","type":"photo","title":"Photos","agent":"com.plexapp.agents.none","scanner":"Plex Photo Scanner","language":"xn","uuid":"u6"},
          {"key":"7","type":"show","title":"Shared TV","uuid":"u7"}
        ]}}
        """
        return try JSONDecoder().decode(PlexLibraryContainer.self, from: Data(json.utf8)).MediaContainer.Directory ?? []
    }

    func test_everySectionDecodes_evenWithoutAgentScannerLanguage() throws {
        XCTAssertEqual(try sections().map(\.key), ["1", "3", "6", "7"])
    }

    func test_photoSectionsHaveNoBrowseSurface_serverHiddenFlagDoesNotCount() throws {
        XCTAssertEqual(try sections().filter(\.hasBrowseSurface).map(\.title), ["Movies", "Music", "Shared TV"])
    }
}
