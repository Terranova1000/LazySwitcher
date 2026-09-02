import Cocoa

// Иллюстрации к историям в окне «что нового».
//
// Жанр выбран под возможности: плоская одноцветная виньетка в том же стиле, что
// значок в строке меню, а не комикс. Одна фигура, узнаваемый силуэт, никаких
// полутонов — так рисунок из кода выглядит намеренным, а не неумелым.
//
// Рисуем в PDF: вектор масштабируется под любой экран и весит килобайты.
// Цвет один и берётся из системного, поэтому картинка живёт и в тёмной теме.

let W: CGFloat = 456
let H: CGFloat = 168

// MARK: - Ленивец

/// Голова ленивца: круг, две наклонные полосы маски, нос, улыбка.
/// Та же геометрия, что в значке, — узнаётся как один и тот же персонаж.
func slothHead(_ ctx: CGContext, at c: CGPoint, r: CGFloat) {
    let k = r / 18.0
    ctx.setLineWidth(2.0 * k)
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r * 0.86,
                                 width: r * 2, height: r * 1.72))
    for mirrored in [false, true] {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        if mirrored { ctx.scaleBy(x: -1, y: 1) }
        let patch = CGMutablePath()
        // Крупная наклонная полоса от переносицы вниз-наружу к щеке. Мелкие
        // пятна у центра читались бабочкой, а круглые — пандой; узнаётся
        // ленивец именно по наклону и размаху.
        patch.move(to: CGPoint(x: -0.08 * r, y: 0.56 * r))
        patch.addCurve(to: CGPoint(x: -0.10 * r, y: 0.06 * r),
                       control1: CGPoint(x: 0.06 * r, y: 0.40 * r),
                       control2: CGPoint(x: 0.02 * r, y: 0.18 * r))
        patch.addCurve(to: CGPoint(x: -0.62 * r, y: -0.34 * r),
                       control1: CGPoint(x: -0.22 * r, y: -0.10 * r),
                       control2: CGPoint(x: -0.40 * r, y: -0.32 * r))
        patch.addCurve(to: CGPoint(x: -0.92 * r, y: 0.06 * r),
                       control1: CGPoint(x: -0.80 * r, y: -0.36 * r),
                       control2: CGPoint(x: -0.92 * r, y: -0.14 * r))
        patch.addCurve(to: CGPoint(x: -0.66 * r, y: 0.46 * r),
                       control1: CGPoint(x: -0.92 * r, y: 0.26 * r),
                       control2: CGPoint(x: -0.82 * r, y: 0.38 * r))
        patch.addCurve(to: CGPoint(x: -0.08 * r, y: 0.56 * r),
                       control1: CGPoint(x: -0.48 * r, y: 0.54 * r),
                       control2: CGPoint(x: -0.28 * r, y: 0.58 * r))
        patch.closeSubpath()
        ctx.addPath(patch)
        ctx.fillPath()
        ctx.restoreGState()
    }
    // Нос и улыбка — то, что делает морду доброй, а не просто полосатой.
    ctx.fillEllipse(in: CGRect(x: c.x - 0.13 * r, y: c.y - 0.18 * r,
                               width: 0.26 * r, height: 0.20 * r))
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: c.x - 0.30 * r, y: c.y - 0.34 * r))
    smile.addQuadCurve(to: CGPoint(x: c.x + 0.30 * r, y: c.y - 0.34 * r),
                       control: CGPoint(x: c.x, y: c.y - 0.60 * r))
    ctx.addPath(smile)
    ctx.setLineWidth(1.7 * k)
    ctx.strokePath()
}

/// Тело, висящее на одной руке. Вторая рука свободна — ею персонаж и «делает».
func hangingBody(_ ctx: CGContext, head: CGPoint, r: CGFloat,
                 grip: CGPoint, freeHand: CGPoint) {
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Плечи чуть ниже и правее головы, чтобы рука уходила к ветке мимо морды,
    // а не поперёк неё.
    let shoulder = CGPoint(x: head.x + r * 0.30, y: head.y - r * 0.80)

    // Туловище — цельная каплевидная форма, сужающаяся книзу. Штрихом
    // постоянной толщины получалась колбаса, а поджатая лапа читалась как
    // culotte: на плоском силуэте лишняя деталь только мешает.
    let body = CGMutablePath()
    let top = CGPoint(x: head.x + r * 0.16, y: head.y - r * 0.70)
    let bottom = CGPoint(x: head.x + r * 0.50, y: head.y - r * 2.10)
    body.move(to: CGPoint(x: top.x - r * 0.46, y: top.y))
    body.addCurve(to: CGPoint(x: bottom.x - r * 0.20, y: bottom.y),
                  control1: CGPoint(x: top.x - r * 0.52, y: top.y - r * 0.9),
                  control2: CGPoint(x: bottom.x - r * 0.36, y: bottom.y + r * 0.5))
    body.addQuadCurve(to: CGPoint(x: bottom.x + r * 0.20, y: bottom.y),
                      control: CGPoint(x: bottom.x, y: bottom.y - r * 0.28))
    body.addCurve(to: CGPoint(x: top.x + r * 0.50, y: top.y),
                  control1: CGPoint(x: bottom.x + r * 0.40, y: bottom.y + r * 0.5),
                  control2: CGPoint(x: top.x + r * 0.60, y: top.y - r * 0.9))
    body.closeSubpath()
    ctx.addPath(body)
    ctx.fillPath()

    // Рука, которой держится: длинная пологая дуга к ветке.
    ctx.setLineWidth(r * 0.28)
    ctx.move(to: CGPoint(x: shoulder.x - r * 0.1, y: shoulder.y + r * 0.15))
    ctx.addQuadCurve(to: grip,
                     control: CGPoint(x: (shoulder.x + grip.x) / 2 - r * 0.15,
                                      y: shoulder.y + r * 0.75))
    ctx.strokePath()

    // Свободная рука — тянется к делу и дотягивается.
    // Почти прямая: заметная дуга здесь читалась канатом, а не рукой.
    // Отходит от правого бока, ниже головы: из-за плеча рука шла поперёк
    // морды и сливалась с ней.
    ctx.move(to: CGPoint(x: shoulder.x + r * 0.50, y: shoulder.y - r * 0.45))
    ctx.addQuadCurve(to: freeHand,
                     control: CGPoint(x: (shoulder.x + freeHand.x) / 2 + r * 0.35,
                                      y: (shoulder.y + freeHand.y) / 2 - r * 0.30))
    ctx.strokePath()

    // Когти: три штриха, направленных «в хват».
    for (point, toward) in [(grip, CGPoint(x: grip.x, y: grip.y + r)),
                            (freeHand, CGPoint(x: freeHand.x + r, y: freeHand.y))] {
        let base = atan2(toward.y - point.y, toward.x - point.x)
        ctx.setLineWidth(r * 0.11)
        for i in -1...1 {
            let a = base + CGFloat(i) * 0.40
            ctx.move(to: point)
            ctx.addLine(to: CGPoint(x: point.x + cos(a) * r * 0.40,
                                    y: point.y + sin(a) * r * 0.40))
            ctx.strokePath()
        }
    }
}

// MARK: - Сцена: молния

func drawZipper(_ ctx: CGContext) {
    // Молния лежит высоко и служит веткой: ленивец висит под ней, как и
    // положено ленивцу, а свободной рукой ведёт бегунок. Так обе половины
    // картинки заняты и понятно, кто здесь работает.
    let midY = H * 0.78
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let sliderX = W * 0.60
    ctx.setLineWidth(5)
    for side in [1.0, -1.0] as [CGFloat] {
        let tape = CGMutablePath()
        tape.move(to: CGPoint(x: 22, y: midY + side * 5))
        tape.addLine(to: CGPoint(x: sliderX - 26, y: midY + side * 5))
        tape.addQuadCurve(to: CGPoint(x: W - 26, y: midY + side * 30),
                          control: CGPoint(x: sliderX + 66, y: midY + side * 9))
        ctx.addPath(tape)
        ctx.strokePath()
    }

    ctx.setLineWidth(4)
    var x: CGFloat = 32
    while x < sliderX - 32 {
        for side in [1.0, -1.0] as [CGFloat] {
            ctx.move(to: CGPoint(x: x, y: midY + side * 5))
            ctx.addLine(to: CGPoint(x: x + 5, y: midY - side * 2))
            ctx.strokePath()
        }
        x += 13
    }
    var t: CGFloat = 0.14
    while t < 1.0 {
        for side in [1.0, -1.0] as [CGFloat] {
            let px = sliderX - 26 + (W - 26 - (sliderX - 26)) * t
            let py = midY + side * (5 + 25 * t * t)
            ctx.move(to: CGPoint(x: px, y: py))
            ctx.addLine(to: CGPoint(x: px + 6, y: py - side * 7))
            ctx.strokePath()
        }
        t += 0.15
    }

    let slider = CGMutablePath()
    slider.move(to: CGPoint(x: sliderX - 30, y: midY + 15))
    slider.addLine(to: CGPoint(x: sliderX + 15, y: midY + 10))
    slider.addLine(to: CGPoint(x: sliderX + 15, y: midY - 10))
    slider.addLine(to: CGPoint(x: sliderX - 30, y: midY - 15))
    slider.closeSubpath()
    ctx.addPath(slider)
    ctx.fillPath()

    // Ушко свисает вниз-вправо — под собственным весом и подальше от ленивца.
    ctx.setLineWidth(5)
    let pullEnd = CGPoint(x: sliderX + 16, y: midY - 40)
    ctx.move(to: CGPoint(x: sliderX - 4, y: midY - 14))
    ctx.addQuadCurve(to: pullEnd, control: CGPoint(x: sliderX + 2, y: midY - 30))
    ctx.strokePath()
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: CGRect(x: pullEnd.x - 11, y: pullEnd.y - 20, width: 22, height: 24))

    // Ленивец висит на сомкнутой части — там, где держаться надёжно.
    let r: CGFloat = 26
    // Висит вплотную к бегунку: тянуться недалеко, и рука остаётся рукой.
    // Когда ленивец был дальше, длинная пологая дуга читалась канатом.
    let head = CGPoint(x: sliderX - 96, y: midY - 50)
    hangingBody(ctx, head: head, r: r,
                grip: CGPoint(x: sliderX - 124, y: midY - 7),
                freeHand: CGPoint(x: sliderX - 36, y: midY - 6))
    slothHead(ctx, at: head, r: r)
}

// MARK: - Вывод

func render(_ name: String, _ body: (CGContext) -> Void) {
    var box = CGRect(x: 0, y: 0, width: W, height: H)
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    // PDF для сборки
    let pdf = CGContext(out.appendingPathComponent("\(name).pdf") as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil)
    pdf.setFillColor(NSColor.black.cgColor)
    pdf.setStrokeColor(NSColor.black.cgColor)
    body(pdf)
    pdf.endPDFPage()
    pdf.closePDF()
    // PNG на белом — чтобы посмотреть глазами, что получилось
    let scale = 2
    let bmp = CGContext(data: nil, width: Int(W) * scale, height: Int(H) * scale,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bmp.setFillColor(NSColor.white.cgColor)
    bmp.fill(CGRect(x: 0, y: 0, width: W * CGFloat(scale), height: H * CGFloat(scale)))
    bmp.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    bmp.setFillColor(NSColor.black.cgColor)
    bmp.setStrokeColor(NSColor.black.cgColor)
    body(bmp)
    let png = NSBitmapImageRep(cgImage: bmp.makeImage()!)
    try! png.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("\(name).png"))
    print("· \(name)")
}

render("story-zipper", drawZipper)
