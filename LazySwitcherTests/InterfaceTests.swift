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

/// Uninstall, and the promise it makes.
final class UninstallerTests: XCTestCase {

    /// Dragging an app to the Trash leaves its preferences behind — so the list
    /// of places to clean has to actually name them, or "remove settings" is a
    /// button that does nothing visible.
    func testLeftoversPointAtRealLocations() {
        let support = Uninstaller.supportDirectory
        XCTAssertTrue(support.path.contains("Application Support"))
        XCTAssertTrue(support.lastPathComponent == "Lazy Switcher")
    }

    /// The menu bar icon is our own drawing, and a template one: if it ever
    /// loses that flag it stops inverting on a dark menu bar and turns into a
    /// black smudge there.
    func testMenuBarIconExistsAndIsATemplate() throws {
        let image = try XCTUnwrap(NSImage(named: "MenuBarIcon"),
                                  "Иконка строки меню не попала в каталог ассетов")
        XCTAssertTrue(image.isTemplate, "Иконка обязана быть шаблоном, иначе не перекрасится")
        XCTAssertGreaterThan(image.size.width, 0)
    }

    /// The banner had black rounded corners baked into it, which showed through
    /// as dark wedges. Fixed by cropping; this checks the corners are light so
    /// the crop cannot be lost in a future re-export.
    func testBannerCornersAreNotBlack() throws {
        let banner = try XCTUnwrap(NSImage(named: "Banner"))
        guard let tiff = banner.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return XCTFail("Баннер не читается как растр")
        }
        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        for (x, y, corner) in [(2, 2, "верх-лево"), (w - 3, 2, "верх-право"),
                               (2, h - 3, "низ-лево"), (w - 3, h - 3, "низ-право")] {
            let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            let brightness = colour?.brightnessComponent ?? 0
            XCTAssertGreaterThan(brightness, 0.12,
                                 "Угол «\(corner)» тёмный — вернулись запечённые чёрные скругления")
        }
    }
}

/// Version numbers, which have four places to disagree.
final class VersionTests: XCTestCase {

    /// `Info.plist` used to carry the number as a literal while the project
    /// carried `MARKETING_VERSION` separately, and the two drifted apart in
    /// silence: the image was named one version, About showed another, and the
    /// update check compared a third. The plist now takes the build setting, and
    /// this checks the substitution actually happened — an unexpanded
    /// `$(MARKETING_VERSION)` looks fine in the file and ships as literal text.
    func testBundleVersionIsARealNumber() {
        let version = UpdateChecker.currentVersion
        XCTAssertFalse(version.contains("$"), "Подстановка не сработала: «\(version)»")
        XCTAssertFalse(version.isEmpty)
        let parts = version.split(separator: ".")
        XCTAssertFalse(parts.isEmpty)
        for part in parts {
            XCTAssertNotNil(Int(part), "«\(version)» — не номер версии")
        }
    }

    /// Every configuration in the project has to agree, or a Debug build reports
    /// a different version from the Release one and nobody notices until an
    /// update check misfires.
    func testAllProjectConfigurationsCarryTheSameVersion() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LazySwitcher.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        let found = Set(text.components(separatedBy: "MARKETING_VERSION = ").dropFirst()
            .compactMap { $0.split(separator: ";").first.map(String.init) })
        XCTAssertEqual(found.count, 1,
                       "Версии разошлись между конфигурациями: \(found.sorted())")
        XCTAssertEqual(found.first, UpdateChecker.currentVersion,
                       "Проект и собранный бандл не согласны о версии")
    }
}

/// Holding keystrokes while a replacement is on the wire.
///
/// The defect this guards against was reported as "the change grabs the space
/// and part of the previous word and makes a mess", and it was exactly that.
/// A replacement is a sequence of backspaces and characters with pauses between
/// them, and the user keeps typing through it — so our deletions counted
/// characters that were correct when we decided and were not by the time they
/// landed.
///
/// Checking "has anything been typed" before starting was already there and was
/// not the answer: the check was right, the window it guarded was the wrong one.
/// The dangerous interval is not before the replacement but during it.
final class ReplacementHoldTests: XCTestCase {

    func testHoldFlagStartsClear() {
        let tap = KeyTapService()
        XCTAssertEqual(tap.replacementInFlight.value, 0)
    }

    func testBeginAndEndToggleTheFlag() {
        let tap = KeyTapService()
        tap.beginReplacement()
        XCTAssertNotEqual(tap.replacementInFlight.value, 0, "Во время замены нажатия обязаны удерживаться")
        tap.endReplacement()
        XCTAssertEqual(tap.replacementInFlight.value, 0)
    }

    /// Nothing held means nothing replayed — the handler must not be called with
    /// an empty list, or every ordinary replacement would schedule pointless work.
    func testNothingIsReplayedWhenNothingWasHeld() {
        let tap = KeyTapService()
        var replayed = false
        tap.onReplayHeldKeys = { _ in replayed = true }
        tap.beginReplacement()
        tap.endReplacement()
        XCTAssertFalse(replayed)
    }
}
