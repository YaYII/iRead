import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 生成 App 图标：暖纸色书 + 陶土色底，配色取自阅读主题（paper / accentHex）。
// 用法：swift scripts/make-app-icon.swift <输出路径>
//
// 为什么用代码画而不是找图：图标会被系统缩到 60pt，细节全糊，只有两三种颜色、
// 大块剪影才立得住；而且这个工程没有设计资源，代码画的可复现、能改色。
//
// 造型取舍：整本书画成一条连续轮廓（外缘外鼓、中缝上下各凹一个 V），
// 再压一层中缝阴影。两片各自独立的圆角矩形在小尺寸下会读成"两张卡片"，不是书。

let side = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "iRead/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let cream = color(0xFFFBF3)          // 纸面
let creamShade = color(0xE7D5B6)     // 纸上淡纹
let clayTop = color(0xCB7550)        // 底色渐变：上
let clayBottom = color(0x923D1C)     // 底色渐变：下
let ribbonRed = color(0x7A2C11)      // 书签

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: side, height: side,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("context")
}

// 用左上角为原点思考，画之前翻一次
ctx.translateBy(x: 0, y: CGFloat(side))
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// 1. 底色：斜向渐变。必须带 extend，否则起止点之外不铺色，四角会漏出黑底。
let bg = CGGradient(colorsSpace: space,
                    colors: [clayTop, clayBottom] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg,
                       start: CGPoint(x: 80, y: 0),
                       end: CGPoint(x: 950, y: 1024),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// 2. 左上角一团柔光，避免整块死板
let glow = CGGradient(colorsSpace: space,
                      colors: [color(0xFFFFFF, 0.13), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: 280, y: 150), startRadius: 0,
                       endCenter: CGPoint(x: 280, y: 150), endRadius: 700,
                       options: [])

// 3. 书本轮廓
let cx: CGFloat = 512
let leftX: CGFloat = 176
let rightX: CGFloat = 848
let topY: CGFloat = 316
let bottomY: CGFloat = 704
let gutterTopY: CGFloat = 368
let gutterBottomY: CGFloat = 756
let bow: CGFloat = 32

let book = CGMutablePath()
book.move(to: CGPoint(x: leftX, y: topY))
// 上缘：外高、中缝低
book.addCurve(to: CGPoint(x: cx, y: gutterTopY),
              control1: CGPoint(x: cx - 158, y: topY + 8),
              control2: CGPoint(x: cx - 74, y: gutterTopY - 14))
book.addCurve(to: CGPoint(x: rightX, y: topY),
              control1: CGPoint(x: cx + 74, y: gutterTopY - 14),
              control2: CGPoint(x: cx + 158, y: topY + 8))
// 右外缘：向外鼓一点，像一叠页
book.addCurve(to: CGPoint(x: rightX, y: bottomY),
              control1: CGPoint(x: rightX + bow, y: topY + 96),
              control2: CGPoint(x: rightX + bow, y: bottomY - 96))
// 下缘：同样在中缝处往下走
book.addCurve(to: CGPoint(x: cx, y: gutterBottomY),
              control1: CGPoint(x: cx + 158, y: bottomY - 8),
              control2: CGPoint(x: cx + 74, y: gutterBottomY + 14))
book.addCurve(to: CGPoint(x: leftX, y: bottomY),
              control1: CGPoint(x: cx - 74, y: gutterBottomY + 14),
              control2: CGPoint(x: cx - 158, y: bottomY - 8))
// 左外缘
book.addCurve(to: CGPoint(x: leftX, y: topY),
              control1: CGPoint(x: leftX - bow, y: bottomY - 96),
              control2: CGPoint(x: leftX - bow, y: topY + 96))
book.closeSubpath()

// 3a. 投影：CTM 是翻转的（y 向下），但 setShadow 的 offset 仍按设备方向走，dy 取正才是往下
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 44, color: color(0x35170A, 0.42))
ctx.beginPath()
ctx.addPath(book)
ctx.setFillColor(color(0x000000, 0.001))
ctx.fillPath()
ctx.restoreGState()

// 3b. 本体
ctx.beginPath()
ctx.addPath(book)
ctx.setFillColor(cream)
ctx.fillPath()

// 3c. 纸上淡纹：内外都裁进书里，免得压到轮廓外
ctx.saveGState()
ctx.addPath(book)
ctx.clip()

ctx.setLineWidth(9)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0xE7D5B6, 0.9))
for i in 0..<3 {
    let y = 588 + CGFloat(i) * 26
    // 左页：越靠中缝越低
    ctx.move(to: CGPoint(x: 262, y: y))
    ctx.addLine(to: CGPoint(x: 458, y: y + 8))
    // 右页镜像
    ctx.move(to: CGPoint(x: 566, y: y + 8))
    ctx.addLine(to: CGPoint(x: 762, y: y))
}
ctx.strokePath()

// 3d. 中缝：横向渐变压一道阴影，两半才读成同一本
let gutterGrad = CGGradient(colorsSpace: space,
                            colors: [color(0x7A4A26, 0), color(0x7A4A26, 0.26), color(0x7A4A26, 0)] as CFArray,
                            locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gutterGrad,
                       start: CGPoint(x: cx - 36, y: 0),
                       end: CGPoint(x: cx + 36, y: 0),
                       options: [])

// 4. 书签：从右页上部垂下来，底端切 V
let mark = CGMutablePath()
mark.move(to: CGPoint(x: 626, y: 344))
mark.addLine(to: CGPoint(x: 692, y: 344))
mark.addLine(to: CGPoint(x: 692, y: 588))
mark.addLine(to: CGPoint(x: 659, y: 546))
mark.addLine(to: CGPoint(x: 626, y: 588))
mark.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: color(0x4A1D09, 0.38))
ctx.beginPath()
ctx.addPath(mark)
ctx.setFillColor(ribbonRed)
ctx.fillPath()
ctx.restoreGState()
ctx.restoreGState()   // 结束 3c 的裁剪

// 5. 出图
guard let image = ctx.makeImage() else { fatalError("image") }
let url = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write") }
print("icon -> \(url.path)")
