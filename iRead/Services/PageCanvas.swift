import Foundation
import SwiftUI
import UIKit
import CoreText

/// 单页 CoreText 绘制视图。传入整章带属性文本 + 本页起始位置，
/// 与 Paginator 的分页计算使用同一份属性，行断位置完全一致。
final class CoreTextPageView: UIView {
    var pageText: NSAttributedString = NSAttributedString() {
        didSet { setNeedsDisplay() }
    }
    var startLocation: Int = 0 {
        didSet { setNeedsDisplay() }
    }
    /// 正在朗读的字符区间（章内坐标）
    var highlightRange: NSRange? {
        didSet {
            guard oldValue != highlightRange else { return }
            setNeedsDisplay()
        }
    }
    var highlightColor: UIColor = .clear {
        didSet {
            guard oldValue != highlightColor else { return }
            setNeedsDisplay()
        }
    }

    /// 长按选中的区间（章内坐标）与配色
    var selectionRange: NSRange? {
        didSet {
            guard oldValue != selectionRange else { return }
            setNeedsDisplay()
        }
    }
    var readingTheme: ReadingTheme = .paper {
        didSet { bubble.apply(theme: readingTheme) }
    }
    /// 点气泡里的播放：回传章内字符位置
    var onStartSpeech: ((Int) -> Void)?

    private lazy var bubble: SelectionBubble = {
        let view = SelectionBubble()
        view.onPlay = { [weak self] in
            guard let self, let range = self.selectionRange else { return }
            self.selectionRange = nil
            self.onStartSpeech?(range.location)
        }
        view.onCopy = { [weak self] in
            guard let self, let range = self.selectionRange else { return }
            UIPasteboard.general.string = (self.pageText.string as NSString)
                .substring(with: range)
            self.selectionRange = nil
        }
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        selectSentence(at: gesture.location(in: self))
    }

    /// 选中某一句（也供自测注入）
    func selectSentence(at point: CGPoint) {
        guard let char = TextHighlight.characterIndex(
            in: pageText, startLocation: startLocation, size: bounds.size, point: point
        ) else { return }
        let range = SentenceRange.containing(char, in: pageText.string as NSString)
        guard range.length > 0, let frame = textFrame(),
              let first = TextHighlight.rects(in: frame, containerHeight: bounds.height, range: range).first
        else { return }

        selectionRange = range
        bubble.present(above: first, in: self, theme: readingTheme)
    }

    /// 与 draw 完全一致的排版结果
    private func textFrame() -> CTFrame? {
        guard pageText.length > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let start = min(max(0, startLocation), max(0, pageText.length - 1))
        let path = CGPath(rect: bounds, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(pageText as CFAttributedString)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), pageText.length > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        guard let frame = textFrame() else { return }

        func fill(_ range: NSRange?, _ color: UIColor) {
            guard let range, range.length > 0, color.cgColor.alpha > 0 else { return }
            let rects = TextHighlight.rects(in: frame, containerHeight: bounds.height, range: range)
            guard !rects.isEmpty else { return }
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            for r in rects {
                ctx.addPath(UIBezierPath(roundedRect: r.insetBy(dx: -2, dy: 0), cornerRadius: 3).cgPath)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        fill(selectionRange, readingTheme.uiSelection)
        fill(highlightRange, highlightColor)

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

struct CoreTextPage: UIViewRepresentable {
    let pageText: NSAttributedString
    let startLocation: Int
    var highlightRange: NSRange? = nil
    var highlightColor: UIColor = .clear
    var readingTheme: ReadingTheme = .paper
    var onStartSpeech: ((Int) -> Void)? = nil
    /// 仅供自测：直接在某点触发长按选中
    var debugLongPress: CGPoint? = nil

    func makeUIView(context: Context) -> CoreTextPageView {
        let view = CoreTextPageView(frame: .zero)
        view.pageText = pageText
        view.startLocation = startLocation
        view.highlightColor = highlightColor
        view.highlightRange = highlightRange
        view.readingTheme = readingTheme
        view.onStartSpeech = onStartSpeech
        if let point = debugLongPress {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak view] in
                view?.selectSentence(at: point)
            }
        }
        return view
    }

    func updateUIView(_ uiView: CoreTextPageView, context: Context) {
        uiView.pageText = pageText
        uiView.startLocation = startLocation
        uiView.highlightColor = highlightColor
        uiView.highlightRange = highlightRange
        uiView.readingTheme = readingTheme
        uiView.onStartSpeech = onStartSpeech
        uiView.setNeedsDisplay()
    }
}

// MARK: - 高亮几何 / 命中测试

enum TextHighlight {
    /// 计算 CTFrame 内某字符区间的绘制矩形（UIKit 坐标，原点左上）
    static func rects(in frame: CTFrame, containerHeight: CGFloat, range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var out: [CGRect] = []
        let lower = max(0, range.location)
        let upper = range.location + range.length

        for (i, line) in lines.enumerated() {
            let r = CTLineGetStringRange(line)
            guard r.length > 0 else { continue }
            let lo = max(lower, r.location)
            let hi = min(upper, r.location + r.length)
            guard hi > lo else { continue }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let top = containerHeight - origins[i].y - ascent

            let x0 = CTLineGetOffsetForStringIndex(line, lo, nil)
            var x1 = CTLineGetOffsetForStringIndex(line, hi, nil)
            if x1 <= x0 { x1 = x0 + 6 }
            out.append(
                CGRect(x: x0, y: top - 1, width: x1 - x0, height: ascent + descent + leading + 1)
            )
        }
        return out
    }

    /// 点（视图坐标，原点左上）落在哪个字符上；返回章内字符位置
    static func characterIndex(
        in text: NSAttributedString,
        startLocation: Int,
        size: CGSize,
        point: CGPoint
    ) -> Int? {
        guard text.length > 0, size.width > 0, size.height > 0 else { return nil }
        let start = min(max(0, startLocation), max(0, text.length - 1))
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        // 找出点所在的行（把 CoreText 的基线坐标换算到顶部坐标系）
        var hitIndex = -1
        for (i, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let top = size.height - origins[i].y - ascent
            let height = ascent + descent + leading
            if point.y >= top - 2, point.y <= top + height + 2 {
                hitIndex = i
                break
            }
        }
        guard hitIndex >= 0 else { return nil }
        let line = lines[hitIndex]
        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, point.x), y: 0))
        guard idx != kCFNotFound else { return nil }
        return min(max(0, idx), max(0, text.length - 1))
    }
}
