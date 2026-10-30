import XCTest
@testable import Rivulet

/// Wikipedia's rendered cast tables: only a table with a Character (or Role)
/// column and a column headed English is read. HTML abridged from the
/// articles' rendered sections (October 2026).
final class WikipediaCastTests: XCTestCase {

    private typealias Client = WikipediaCastClient

    /// Arco: two header rows, "Voice actor" spanning French and English;
    /// row-header characters; a surnames-only cell; a note after a name.
    private let arco = """
    <table class="wikitable plainrowheaders">
    <tbody><tr>
    <th rowspan="2">Character
    </th>
    <th colspan="2">Voice actor
    </th></tr>
    <tr>
    <th>French
    </th>
    <th>English
    </th></tr>
    <tr>
    <th scope="row">Iris
    </th>
    <td>Margot Ringard Oldra</td>
    <td>Romy Fay
    </td></tr>
    <tr>
    <th scope="row">Jeanne, Iris' mother
    </th>
    <td><a href="/wiki/Alma_Jodorowsky" title="Alma Jodorowsky">Alma Jodorowsky</a></td>
    <td><a href="/wiki/Natalie_Portman" title="Natalie Portman">Natalie Portman</a>
    </td></tr>
    <tr>
    <th scope="row">Mikki<sup id="cite&#95;ref-1" class="reference"><a href="#cite_note-1"><span class="cite-bracket">&#91;</span>a<span class="cite-bracket">&#93;</span></a></sup>
    </th>
    <td>Jodorowsky<br />Arlaud</td>
    <td>Portman<br />Ruffalo
    </td></tr>
    <tr>
    <th scope="row">Ada
    </th>
    <td>Joséphine Mancini</td>
    <td>Zoya Bogomolova (child)<br />Michaela Celella (adult)
    </td></tr></tbody></table>
    """

    func test_arco_spannedHeaders_rowHeaderCharacters() {
        let roles = Client.roles(inHTML: arco)
        XCTAssertEqual(roles.map(\.character), ["Iris", "Jeanne, Iris' mother", "Mikki", "Ada"])
        XCTAssertEqual(roles.map(\.actor), ["Romy Fay", "Natalie Portman", "Natalie Portman", "Zoya Bogomolova"],
                       "a surname alone names the actor listed in full above; a note is dropped")
    }

    /// Ernest & Celestine: the English column's header carries a reference.
    func test_headerWithAReference() {
        let html = """
        <table class="wikitable">
        <tbody><tr>
        <th>Character</th>
        <th>French <br />voice actor</th>
        <th>English dubbing actor<sup class="reference"><a href="#cite_note-2">[2]</a></sup></th></tr>
        <tr><td>Ernest</td><td>Lambert Wilson</td><td><a href="/wiki/Forest_Whitaker">Forest Whitaker</a></td></tr>
        <tr><td>Celestine</td><td>Pauline Brunner</td><td>Mackenzie Foy</td></tr>
        </tbody></table>
        """
        XCTAssertEqual(Client.roles(inHTML: html), [.init(character: "Ernest", actor: "Forest Whitaker"),
                                                    .init(character: "Celestine", actor: "Mackenzie Foy")])
    }

    /// Checkered Ninja heads its character column "Role".
    func test_roleColumn() {
        let html = """
        <table class="wikitable mw-collapsible"><caption>Cast</caption>
        <tbody><tr><th>Role</th><th>Danish</th><th>English</th></tr>
        <tr><td>Alex Stenstrøm (Aske Stenstrøm)</td><td>Villads Bøye</td><td>Cameron Simpson</td></tr></tbody></table>
        """
        XCTAssertEqual(Client.roles(inHTML: html), [.init(character: "Alex Stenstrøm", actor: "Cameron Simpson")])
    }

    /// Marona's Fantastic Tale: a dub column not labelled English is not read.
    func test_unlabelledDubColumn_isNotRead() {
        let html = """
        <table class="wikitable"><tbody>
        <tr><th>Character</th><th>Original Actor</th><th>Dub Actor</th></tr>
        <tr><td>Marona</td><td>Lizzie Brocheré</td><td>Someone</td></tr>
        </tbody></table>
        """
        XCTAssertTrue(Client.roles(inHTML: html).isEmpty)
    }

    func test_tableWithoutACharacterColumn_isNotRead() {
        let html = """
        <table class="wikitable"><tbody><tr><th>Year</th><th>English title</th></tr>
        <tr><td>2019</td><td>I Lost My Body</td></tr></tbody></table>
        """
        XCTAssertTrue(Client.roles(inHTML: html).isEmpty)
    }

    /// Persepolis: the cast is a list of the original actors.
    func test_castList_isNotATable() {
        XCTAssertTrue(Client.roles(inHTML: "<ul><li>Chiara Mastroianni as Marjane</li></ul>").isEmpty)
    }

    func test_placeholderActors_areSkipped_andARowSpanCarries() {
        let html = """
        <table class="wikitable"><tbody>
        <tr><th>Character</th><th>Spanish voice actor</th><th>English voice actor</th></tr>
        <tr><td rowspan="2">Tad</td><td>Óscar Barberán</td><td>Trevor White</td></tr>
        <tr><td>Óscar Barberán</td><td>—</td></tr>
        <tr><td>Sara</td><td>Michelle Jenner</td><td>Ariel Winter</td></tr>
        </tbody></table>
        """
        XCTAssertEqual(Client.roles(inHTML: html), [.init(character: "Tad", actor: "Trevor White"),
                                                    .init(character: "Sara", actor: "Ariel Winter")])
    }

    func test_entities() {
        XCTAssertEqual(Client.decodeEntities("Ernest &amp; C&#233;lestine &#x26; &#91;a&#93;"), "Ernest & Célestine & [a]")
    }
}
