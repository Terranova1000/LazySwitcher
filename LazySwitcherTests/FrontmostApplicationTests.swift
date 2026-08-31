import XCTest
@testable import Lazy_Switcher

/// Кого считать «передним приложением».
///
/// Вопрос выглядит бесспорным и дважды оказался неверным, поэтому правило живёт
/// отдельной функцией и проверяется здесь. Цена ошибки — не пропущенная замена, а
/// замена, ушедшая в приложение, в котором человек в этот момент не печатает.
final class FrontmostApplicationTests: XCTestCase {

    /// Ради чего правило вообще существует (Н34): после разблокировки экрана
    /// frontmostApplication бесконечно возвращает loginwindow.
    func testSubstitutesForLockScreen() {
        XCTAssertTrue(AppMonitor.shouldBelieveMenuBarOwner(frontmostBundleID: "com.apple.loginwindow"))
        XCTAssertTrue(AppMonitor.shouldBelieveMenuBarOwner(frontmostBundleID: "com.apple.SecurityAgent"))
    }

    func testSubstitutesWhenThereIsNoAnswerAtAll() {
        XCTAssertTrue(AppMonitor.shouldBelieveMenuBarOwner(frontmostBundleID: nil))
        XCTAssertTrue(AppMonitor.shouldBelieveMenuBarOwner(frontmostBundleID: ""))
    }

    /// Главная проверка этого файла — регрессия версии 1.9.
    ///
    /// Приложение-аксессуар (LSUIElement), держащее клавиатурный фокус, не
    /// владеет строкой меню: menuBarOwningApplication в этот момент называет
    /// приложение ПОЗАДИ него. Измерено на macOS 15 отдельным пробником:
    ///
    ///     frontmost=com.verify.accprobe   menuBar=com.apple.Safari
    ///
    /// Если поверить строке меню, жест перепишет выделенный текст в Safari,
    /// пока человек печатает в панельке лончера.
    func testBelievesAccessoryApplicationsHoldingFocus() {
        for id in ["com.raycast.macos", "com.runningwithcrayons.Alfred",
                   "com.apple.Spotlight", "com.lazyswitcher.app"] {
            XCTAssertFalse(AppMonitor.shouldBelieveMenuBarOwner(frontmostBundleID: id),
                           "\(id) держит фокус — клавиши идут туда, а не владельцу строки меню")
        }
    }

    func testBelievesOrdinaryApplications() {
        for id in ["com.apple.Safari", "com.apple.mail", "com.anthropic.claudefordesktop",
                   "com.apple.Terminal", "com.tinyspeck.slackmacgap"] {
            XCTAssertFalse(AppMonitor.shouldBelieveMenuBarOwner(frontmostBundleID: id))
        }
    }
}

/// Что считать «приложение не может сказать, какое поле в фокусе».
///
/// От этого множества зависит, разрешён ли жест при неопознанном поле, а жест
/// при неудаче AX-пути печатает вслепую — поэтому лишняя роль здесь означает
/// удаление в чужом списке, а не неудачную замену.
final class WebContainerRoleTests: XCTestCase {

    func testOnlyWebAreaCounts() {
        XCTAssertEqual(FocusMonitor.webContainerRoles, ["AXWebArea"])
    }

    /// Роли, которые версия 1.9 ошибочно считала «непостроенным веб-деревом».
    /// Это обычные ответы обычных нативных приложений.
    func testOrdinaryNativeRolesDoNotCount() {
        for role in ["AXScrollArea", "AXGroup", "AXApplication", "AXTable",
                     "AXButton", "AXList", "AXOutline", "AXToolbar"] {
            XCTAssertFalse(FocusMonitor.webContainerRoles.contains(role),
                           "\(role) — обычный ответ нативного приложения, а не веб-контейнер")
        }
    }
}
