import XCTest
@testable import Rivulet

/// The Dubbing Database: a dub page is matched to its original strictly, and
/// its cast read in order. Page text abridged from the wiki (October 2026).
final class DubDatabaseTests: XCTestCase {

    private typealias Client = DubDatabaseClient

    private let arcoFrench = Client.Page(title: "Arco", text: """
    {{Infobox media
    |title = Arco
    |media = Arco
    |country = France
    |language = French
    |release = May 16, 2025 {{note|(Cannes)}}<br>October 22, 2025
    }}
    ==Cast==
    {{cast list/character|Iris
    |actor = [[Marfot Ringard Oldra]]
    }}
    """)

    private let arcoEnglish = Client.Page(title: "Arco (English)", text: """
    {{Infobox_media
    |title = Arco
    |media = Arco
    |country = United States
    |language = English
    |release = January 23, 2026
    }}
    {{Article/dubbing start
    |title = Arco
    |language = English
    |film = Arco
    }}
    ==Cast==
    {{Cast list/start}}
    {{Cast list/character|Iris
    |actor = [[Romy Fay]]
    }}
    {{Cast list/character|Iris' father
    |actor = [[Mark Ruffalo]]
    }}
    {{Cast list/character|Dougie
    |actor = [[Will Ferrell]]
    |file=Dougie (Arco).png}}
    {{Cast list/character|Mikki
    |actor = [[Mark Ruffalo]]
    |actor2 = [[Natalie Portman]]
    }}
    |}
    """)

    func test_original_matchesLanguageAndYear() {
        XCTAssertTrue(Client.isOriginal(arcoFrench, languageName: "French", year: 2025))
        XCTAssertFalse(Client.isOriginal(arcoFrench, languageName: "Spanish", year: 2025))
        XCTAssertFalse(Client.isOriginal(arcoFrench, languageName: "French", year: 1999), "a film of the same name")
        XCTAssertFalse(Client.isOriginal(arcoEnglish, languageName: "French", year: 2025))
    }

    func test_languageName_asTheWikiWritesIt() {
        XCTAssertEqual(Client.languageName("fr"), "French")
        XCTAssertEqual(Client.languageName("da"), "Danish")
    }

    func test_englishDub_namesTheSameWork() {
        XCTAssertTrue(Client.isEnglishDub(arcoEnglish, of: arcoFrench))
        let otherWork = Client.Page(title: "Sonic the Hedgehog (film)", text: """
        |media = Sonic the Hedgehog
        |language = English
        """)
        XCTAssertFalse(Client.isEnglishDub(otherWork, of: arcoFrench), "a page that only links to the original")
    }

    /// Miraculous: both pages name the work "Miraculous Ladybug", which is
    /// neither page's title.
    func test_englishDub_bySharedWorkKey() {
        let french = Client.Page(title: "Miraculous, les aventures de Ladybug et Chat Noir", text: """
        |title = Miraculous, les aventures de Ladybug et Chat Noir
        |media = Miraculous Ladybug
        |language = French
        |release = October 19, 2015 - present
        """)
        let english = Client.Page(title: "Miraculous: Tales of Ladybug & Cat Noir", text: """
        |title = Miraculous: Tales of Ladybug & Cat Noir
        |media = Miraculous Ladybug
        |language = English
        """)
        XCTAssertTrue(Client.isOriginal(french, languageName: "French", year: 2015))
        XCTAssertTrue(Client.isEnglishDub(english, of: french))
    }

    /// Ernest & Celestine: the English page carries the English title and
    /// names its original, which is how the original's page is found.
    func test_englishPage_namesItsOriginal() {
        let english = """
        |title = Ernest & Celestine
        |media = Ernest et Célestine
        |language = English
        |release = {{Flag icon|United States}} February 23, 2014<br>{{Flag icon|Australia}} June 19, 2014
        """
        XCTAssertEqual(Client.workTitle(of: english), "Ernest et Célestine")
        let original = Client.Page(title: "Ernest et Célestine", text: """
        |media = Ernest et Célestine
        |language = French
        |release = {{Flag icon|France}} December 12, 2012<br>{{Flag icon|Canada}} February 28, 2022
        """)
        XCTAssertTrue(Client.isOriginal(original, languageName: "French", year: 2012))
    }

    func test_roles_inOrder_firstActor() {
        let roles = Client.roles(arcoEnglish.text)
        XCTAssertEqual(roles.map(\.character), ["Iris", "Iris' father", "Dougie", "Mikki"])
        XCTAssertEqual(roles.map(\.actor), ["Romy Fay", "Mark Ruffalo", "Will Ferrell", "Mark Ruffalo"])
    }

    /// Persepolis: an actor line with its own template before the link.
    func test_roles_keepAnActorAfterATemplate() {
        let text = """
        {{Cast list/character|Grandmother
        |file = Grandma (Persepolis).png
        |actor = {{flag icon|US}} [[Gena Rowlands]]
        }}
        {{cast list/character|Marjane
        |actor = [[Chiara Mastroianni]]
        |actor2 = [[Amethyste Frezignac]] {{note|(younger)}}
        }}
        """
        XCTAssertEqual(Client.roles(text), [.init(character: "Grandmother", actor: "Gena Rowlands"),
                                            .init(character: "Marjane", actor: "Chiara Mastroianni")])
    }

    func test_credits_eachActorOnce_withTheirCharacters() {
        let credits = EnglishDubCast.credits(Client.roles(arcoEnglish.text))
        XCTAssertEqual(credits.map(\.name), ["Romy Fay", "Mark Ruffalo", "Will Ferrell"])
        XCTAssertEqual(credits[1].characters, ["Iris' father", "Mikki"])
        XCTAssertEqual(credits[1].key, "dubdb:Mark Ruffalo")
    }
}
