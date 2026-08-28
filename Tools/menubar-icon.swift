import Cocoa

/// Рисует мордочку ленивца как шаблон для строки меню.
///
/// Ограничение жанра: 18 точек по высоте и один цвет. Всё, что не читается на
/// таком размере, читаться и не будет, поэтому от ленивца остаётся только то,
/// по чему его узнают, — тёмная маска вокруг глаз, расходящаяся вниз к щекам,
/// и нос. Голова обведена контуром, иначе маска повисает в воздухе.
func drawSlothTinted(in size: CGFloat, context ctx: CGContext, tint: NSColor) {
    // Рисуем ту же мордочку выбранным цветом: система перекрашивает шаблон,
    // и проверять надо именно перекрашенный вариант, а не исходный чёрный.
    let layerCS = CGColorSpaceCreateDeviceRGB()
    let px = Int(size)
    let temp = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                         bytesPerRow: 0, space: layerCS,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawSloth(in: size, context: temp)
    guard let mask = temp.makeImage() else { return }
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: size, height: size), mask: mask)
    ctx.setFillColor(tint.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}

func drawSloth(in size: CGFloat, context ctx: CGContext) {
    let s = size / 36.0                       // рисуем в сетке 36×36
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

    ctx.setFillColor(NSColor.black.cgColor)
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Голова: заметно шире, чем высокая. Ушей нет — на иконке приложения их
    // тоже не видно, они в шерсти, а пририсованные читаются как крючки.
    let head = CGRect(x: 1.8 * s, y: 5.6 * s, width: 32.4 * s, height: 25.2 * s)
    ctx.setLineWidth(2.0 * s)
    ctx.strokeEllipse(in: head)

    // Маска: крупные полосы от переносицы вниз и наружу, к щекам. Наклон и
    // размер — то, по чему ленивца узнают; круглые пятна дают панду.
    for mirrored in [false, true] {
        ctx.saveGState()
        if mirrored { ctx.translateBy(x: size, y: 0); ctx.scaleBy(x: -1, y: 1) }
        let patch = CGMutablePath()
        patch.move(to: p(15.2, 25.6))
        patch.addCurve(to: p(16.0, 21.0), control1: p(16.4, 24.6), control2: p(16.5, 22.6))
        patch.addCurve(to: p(11.6, 14.6), control1: p(15.4, 18.4), control2: p(13.8, 15.2))
        patch.addCurve(to: p(8.0, 18.2), control1: p(9.9, 14.0), control2: p(8.2, 15.6))
        patch.addCurve(to: p(10.0, 23.8), control1: p(7.8, 20.6), control2: p(8.6, 22.4))
        patch.addCurve(to: p(15.2, 25.6), control1: p(11.4, 25.0), control2: p(13.4, 26.0))
        patch.closeSubpath()
        ctx.addPath(patch)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Закрытые глаза: дуга уголками вверх — «доволен», а не «щурится».
    // Вырез, а не светлая линия: шаблон одноцветный.
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(2.3 * s)
    for mirrored in [false, true] {
        ctx.saveGState()
        if mirrored { ctx.translateBy(x: size, y: 0); ctx.scaleBy(x: -1, y: 1) }
        let eye = CGMutablePath()
        eye.move(to: p(9.4, 19.6))
        eye.addQuadCurve(to: p(14.4, 19.6), control: p(11.9, 22.4))
        ctx.addPath(eye)
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Нос.
    let nose = CGRect(x: 16.0 * s, y: 13.6 * s, width: 4.0 * s, height: 3.0 * s)
    ctx.fillEllipse(in: nose)

    // Улыбка: широкая дуга уголками вверх, с просветом до контура. Ради неё
    // голова и приплюснута — слитая с контуром улыбка читается как утолщение
    // линии, то есть как грязь.
    ctx.setLineWidth(1.8 * s)
    let smile = CGMutablePath()
    smile.move(to: p(13.2, 11.8))
    smile.addQuadCurve(to: p(18.0, 9.4), control: p(15.4, 9.5))
    smile.addQuadCurve(to: p(22.8, 11.8), control: p(20.6, 9.5))
    ctx.addPath(smile)
    ctx.strokePath()
}

// ── PDF (вектор, для каталога ассетов) ──────────────────────────────────────
let side: CGFloat = 36
var box = CGRect(x: 0, y: 0, width: side, height: side)
let pdf = CFDataCreateMutable(nil, 0)!
let consumer = CGDataConsumer(data: pdf)!
let pdfCtx = CGContext(consumer: consumer, mediaBox: &box, nil)!
pdfCtx.beginPDFPage(nil)
drawSloth(in: side, context: pdfCtx)
pdfCtx.endPDFPage()
pdfCtx.closePDF()
try! (pdf as Data).write(to: URL(fileURLWithPath: "sloth-template.pdf"))

// ── Как это выглядит в строке меню: 18 точек на Retina, оба фона ───────────
do {
    let bar: CGFloat = 44          // высота строки меню на Retina
    let icon: CGFloat = 36         // 18 точек × 2
    let width = 260
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: Int(bar) * 2, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // светлая строка сверху, тёмная снизу
    ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: bar, width: CGFloat(width), height: bar))
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: bar))

    for (index, dark) in [false, true].enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: 40, y: dark ? (bar - icon) / 2 : bar + (bar - icon) / 2)
        // шаблон перекрашивается системой: тёмный на светлом, светлый на тёмном
        ctx.setFillColor((dark ? NSColor.white : NSColor.black).cgColor)
        ctx.setStrokeColor((dark ? NSColor.white : NSColor.black).cgColor)
        drawSlothTinted(in: icon, context: ctx, tint: dark ? .white : .black)
        ctx.restoreGState()
        _ = index
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "sloth-menubar.png"))
}

// ── PNG для просмотра, в тех размерах, где иконка реально живёт ─────────────
for preview: CGFloat in [18, 36, 144] {
    let px = Int(preview)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: preview, height: preview))
    drawSloth(in: preview, context: ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "sloth-\(px).png"))
}
print("готово")
