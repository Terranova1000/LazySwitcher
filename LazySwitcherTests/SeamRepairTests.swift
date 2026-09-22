import XCTest
@testable import Lazy_Switcher

/// Words cut in half by a layout switch, and which half of the truth wins.
final class SeamRepairTests: XCTestCase {

    /// Дела/как/google are words; the mixed readings are not.
    private func known(_ text: String, _ language: String) -> Bool {
        let dictionary: [String: Set<String>] = ["ru": ["как", "дела", "привет"],
                                                 "en": ["google", "hello"]]
        return dictionary[language]?.contains(text.lowercased()) ?? false
    }

    private func candidates(_ russian: String, _ latin: String) -> [SeamRepair.Candidate] {
        [.init(text: russian, language: "ru"), .init(text: latin, language: "en")]
    }

    /// The switch landed after the first key: «rак» was meant to be «как».
    func testTheLayoutInForceWinsWhenItGivesAWord() {
        let meant = SeamRepair.meant(onScreen: "rак", candidates: candidates("как", "rfr"),
                                     isKnownWord: known)
        XCTAssertEqual(meant, .init(text: "как", language: "ru"))
    }

    /// A brand typed after we had switched: «пщщпду» was meant to be «google».
    func testTheOtherLayoutWinsForANameTypedAfterTheSwitch() {
        let meant = SeamRepair.meant(onScreen: "пщщпду", candidates: candidates("пщщпду", "google"),
                                     isKnownWord: known)
        XCTAssertEqual(meant, .init(text: "google", language: "en"))
    }

    /// Neither reading is a word: leave it exactly as it is.
    func testNonsenseInBothLayoutsIsLeftAlone() {
        XCTAssertNil(SeamRepair.meant(onScreen: "кfr", candidates: candidates("кфк", "rfr"),
                                      isKnownWord: known))
    }

    /// The word already says what it should — a replacement here would delete
    /// and retype the same characters for nothing.
    func testAWordThatIsAlreadyRightIsNotRewritten() {
        XCTAssertNil(SeamRepair.meant(onScreen: "как", candidates: candidates("как", "rfr"),
                                      isKnownWord: known))
    }

    func testEmptyReadingsAreIgnored() {
        XCTAssertNil(SeamRepair.meant(onScreen: "abc", candidates: candidates("", ""),
                                      isKnownWord: known))
    }
}
