import AppKit
import XCTest
@testable import Lazy_Switcher

/// Рисует окно в файл, чтобы на него можно было посмотреть.
///
/// Не проверка, а инструмент: интерфейс собирается кодом, и единственный способ
/// убедиться, что он выглядит как задумано, — увидеть его. Снимок пишется рядом
/// со сборкой и в самой сборке никого не касается.
final class WindowSnapshotTests: XCTestCase {

    func testDumpWhatsNewWindow() throws {
        // Во временную папку: переменные окружения до тестового процесса
        // xcodebuild не доносит, а фиксированный путь работает всегда.
        let dir = NSTemporaryDirectory()
        let notes = try XCTUnwrap(ReleaseNotes.text())
        let controller = WhatsNewWindowController(notes: notes)
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()

        // Размеры важнее картинки: снимок может не нарисовать содержимое
        // прокрутки, а нулевая рамка — это уже настоящая поломка вёрстки.
        func walk(_ v: NSView, _ depth: Int) {
            let kind = String(describing: type(of: v))
            var label = ""
            if let f = v as? NSTextField { label = String(f.stringValue.prefix(28)) }
            if v is NSImageView { label = "<картинка>" }
            if !label.isEmpty || v is NSScrollView {
                print(String(repeating: "  ", count: depth)
                      + "\(kind) \(Int(v.frame.width))×\(Int(v.frame.height)) \(label)")
            }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        walk(view, 0)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("lazyswitcher-whatsnew.png")
        try png.write(to: url)
        print("СНИМОК: \(url.path)")
        controller.close()
    }
}
