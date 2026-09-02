import Foundation

/// Небольшие истории про лень, которая двигала прогресс.
///
/// Живут в окне «что нового» под списком изменений. Смысл не в украшении:
/// приложение называется Lazy Switcher и существует ровно потому, что
/// переключать раскладку руками — скучно. История про то, как чужая лень
/// довела дело до застёжки-молнии, объясняет замысел лучше, чем описание
/// возможностей.
///
/// Одна история на версию, по кругу. Текст локализован обычным способом и
/// лежит в сборке — в сеть за ним никто не ходит (Р13).
enum Stories {

    struct Story {
        /// Ключ заголовка в `Localizable.strings`.
        let title: String
        /// Ключ текста.
        let body: String
        /// Имя картинки в ресурсах, если она нарисована. Истории без картинки
        /// показываются одним текстом — это нормально и выглядит нормально.
        let art: String?
    }

    /// Порядок задан вручную: он определяет, какая история достанется какой
    /// версии, и менять его задним числом — значит переписать историю у уже
    /// вышедших сборок.
    static let all: [Story] = [
        Story(title: "story.zipper.title", body: "story.zipper.body", art: "story-zipper"),
        Story(title: "story.remote.title", body: "story.remote.body", art: nil),
        Story(title: "story.virtues.title", body: "story.virtues.body", art: nil),
        Story(title: "story.sloth.title", body: "story.sloth.body", art: nil),
    ]

    /// Какая история достаётся этой версии.
    ///
    /// Считается из самой версии, а не из счётчика в настройках: одна и та же
    /// сборка обязана показывать одно и то же. Иначе человек, открывший окно
    /// второй раз, увидит другую историю и решит, что первую ему померещилось.
    static func forVersion(_ version: String) -> Story {
        precondition(!all.isEmpty)
        return all[index(for: version, count: all.count)]
    }

    /// Веса подобраны так, чтобы соседние версии не попадали на одну историю.
    /// Первая попытка складывала разряды с одинаковым шагом и чередовала всего
    /// две истории из четырёх — проверено перебором, не на глаз.
    static func index(for version: String, count: Int) -> Int {
        let parts = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return abs(major &* 31 &+ minor &* 7 &+ patch) % count
    }
}
