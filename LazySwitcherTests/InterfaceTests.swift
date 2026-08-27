import AppKit
import XCTest
@testable import Lazy_Switcher

/// Smoke tests for the windows.
///
/// They cannot judge whether a layout looks right, but they catch the failures
/// that make a settings screen useless: a pane that crashes while building, a
/// missing image, a control wired to a selector nobody implements. Those are
/// otherwise found by opening the window — which is exactly what nobody does
/// after changing an unrelated file.
final class InterfaceSmokeTests: XCTestCase {

    func testEveryAssetTheInterfaceAsksForExists() {
        XCTAssertNotNil(NSImage(named: "Banner"), "Баннер не попал в каталог ассетов")
        XCTAssertNotNil(NSImage(named: NSImage.applicationIconName))
    }

    /// The toolbar symbols are SF Symbols by name; a typo shows up as a blank
    /// toolbar button and nothing else.
    func testToolbarSymbolsResolve() {
        for symbol in ["gearshape", "keyboard", "speaker.wave.2", "app.badge", "info.circle",
                       "character.cursor.ibeam", "lock.fill", "pause.circle",
                       "exclamationmark.triangle"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                            "Нет системного символа «\(symbol)»")
        }
    }

    /// Builds every pane. A broken constraint or a nil unwrap in any of them
    /// throws here rather than when somebody opens that tab.
    @MainActor
    func testSettingsWindowBuildsEveryPane() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate,
                                     "Тест-хост должен быть нашим приложением")
        let controller = SettingsWindowController(app: delegate)
        XCTAssertNotNil(controller.window)
        for pane in ["general", "keys", "sound", "apps", "about"] {
            controller.window?.toolbar?.selectedItemIdentifier = .init(pane)
        }
        controller.showAboutPane()
        XCTAssertNotNil(controller.window?.contentView)
        controller.close()
    }

    @MainActor
    func testOnboardingBuildsAllSteps() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = OnboardingWindowController(app: delegate)
        XCTAssertNotNil(controller.window)
        controller.close()
    }

    /// A stray `NSBox()` renders as a titled box — its default title localises
    /// to «Название» — which is where the mystery captions and the strip under
    /// them came from. There is no legitimate use of a default-initialised box
    /// in this project.
    func testNoDefaultInitialisedBoxesInTheInterface() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LazySwitcher/App")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Comments are skipped — this very rule is explained in one, and a
            // check that trips over its own documentation teaches people to
            // delete the documentation.
            let code = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.joined(separator: "\n")
            XCTAssertFalse(code.contains("NSBox()"),
                           "\(file.lastPathComponent): NSBox() рисуется рамкой с подписью «Название»")
        }
    }
}
