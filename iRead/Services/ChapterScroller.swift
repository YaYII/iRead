import SwiftUI
import UIKit
import CoreText

// MARK: - 整章排版结果

/// 把整章文本在固定宽度下排成「一整条」，不做分页。
/// 与 Paginator 共用同一份带属性字符串，所以字形、行距、首行缩进完全一致。
final class ChapterLayout {
    let attributed: NSAttributedString
    let width: CGFloat
    let height: CGFloat
    let frame: CTFrame

    private let lineTops: [CGFloat]
    private let lineRanges: [NSRange]
    /// 行高（ascent + descent + leading），供高亮矩形使用
    private let lineHeights: [CGFloat]
    /// 缓存的 CTLine，供命中测试/高亮复用
    private let lines: [CTLine]

    init(attributed: NSAttributedString, width: CGFloat) {
        self.attributed = attributed
        self.width = max(1, width)

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: self.width, height: .greatestFiniteMagnitude),
            &fitRange
        )
        let textHeight = max(1, ceil(suggested.height) + 4)
        self.height = textHeight

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: self.width, height: textHeight), transform: nil)
        self.frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )

        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        }

        var tops: [CGFloat] = []
        var ranges: [NSRange] = []
        var heights: [CGFloat] = []
        tops.reserveCapacity(lines.count)
        ranges.reserveCapacity(lines.count)
        heights.reserveCapacity(lines.count)

        for (i, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // CoreText 的行原点是基线（以路径左下角为原点），换算成内容顶部的 y
            let baselineFromTop = textHeight - origins[i].y
            tops.append(max(0, baselineFromTop - ascent))
            heights.append(max(1, ascent + descent + leading))

            let r = CTLineGetStringRange(line)
            ranges.append(NSRange(location: max(0, r.location), length: max(0, r.length)))
        }

        self.lineTops = tops
        self.lineRanges = ranges
        self.lineHeights = heights
        self.lines = lines
    }

    /// 某字符区间在内容坐标系（原点左上）里的高亮矩形，每行一块。
    /// 只做几何换算，不重新排版，因此可以每读一句刷一次。
    func highlightRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0, !lines.isEmpty else { return [] }
        var out: [CGRect] = []
        let lower = max(0, range.location)
        let upper = range.location + range.length

        for (i, line) in lines.enumerated() {
            let r = lineRanges[i]
            guard r.length > 0 else { continue }
            let lo = max(lower, r.location)
            let hi = min(upper, r.location + r.length)
            guard hi > lo else { continue }
            let x0 = CTLineGetOffsetForStringIndex(line, lo, nil)
            var x1 = CTLineGetOffsetForStringIndex(line, hi, nil)
            if x1 <= x0 { x1 = x0 + 6 }
            out.append(
                CGRect(
                    x: x0,
                    y: lineTops[i] - 1,
                    width: x1 - x0,
                    height: lineHeights[i] + 1
                )
            )
        }
        return out
    }

    /// 点（内容坐标系，原点左上）落在哪个字符上
    func characterIndex(at point: CGPoint) -> Int {
        guard !lineRanges.isEmpty else { return 0 }
        var idx = 0
        for (i, top) in lineTops.enumerated() {
            if top <= point.y + 2 {
                idx = i
            } else {
                break
            }
        }
        guard idx < lines.count else { return lineRanges[0].location }
        let line = lines[idx]
        let hit = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, point.x), y: 0))
        guard hit != kCFNotFound else { return lineRanges[idx].location }
        return min(max(0, hit), max(0, attributed.length - 1))
    }

    /// 某个字符所在行的顶部偏移（内容坐标系，原点在顶部）
    func topOffset(forCharacter index: Int) -> CGFloat {
        guard !lineRanges.isEmpty else { return 0 }
        let clamped = min(max(0, index), max(0, attributed.length - 1))
        var low = 0
        var high = lineRanges.count - 1
        while low < high {
            let mid = (low + high) / 2
            let r = lineRanges[mid]
            if r.location + max(1, r.length) <= clamped {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return lineTops[low]
    }

    /// 内容坐标 y 处（顶部）对应的字符位置
    func characterIndex(atY y: CGFloat) -> Int {
        guard !lineTops.isEmpty else { return 0 }
        var idx = 0
        for (i, top) in lineTops.enumerated() {
            if top <= y + 2 {
                idx = i
            } else {
                break
            }
        }
        return lineRanges[idx].location
    }
}

// MARK: - 单章绘制视图

final class ChapterTextView: UIView {
    var layout: ChapterLayout?

    /// 正在朗读的字符区间（章内坐标）。只重绘，不重排版。
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

    /// 长按选中的区间（章内坐标）
    var selectionRange: NSRange? {
        didSet {
            guard oldValue != selectionRange else { return }
            setNeedsDisplay()
        }
    }
    var selectionColor: UIColor = .clear {
        didSet {
            guard oldValue != selectionColor else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let layout else { return }

        // 选中 / 朗读高亮都画在文字之下，文字本身不变色，读起来不刺眼
        func fill(_ range: NSRange?, _ color: UIColor) {
            guard let range, range.length > 0, color.cgColor.alpha > 0 else { return }
            let rects = layout.highlightRects(for: range)
            guard !rects.isEmpty else { return }
            context.saveGState()
            context.setFillColor(color.cgColor)
            for r in rects {
                // 必须走 CGContext.fillPath：UIBezierPath.fill() 用的是 UIKit 当前填充色，
                // 会忽略上面设的 CGContext 颜色，导致高亮串色。
                context.addPath(UIBezierPath(roundedRect: r.insetBy(dx: -2, dy: 0), cornerRadius: 3).cgPath)
                context.fillPath()
            }
            context.restoreGState()
        }
        fill(selectionRange, selectionColor)
        fill(highlightRange, highlightColor)

        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(layout.frame, context)
    }
}

// MARK: - 全书连续滚动容器

/// 把多章竖向拼成一条连续的滚动流，滑到章末自然接上下一章，
/// 不再出现「一章到底就跳一下」的割裂感。
///
/// 内存策略：只保留当前阅读位置附近的一个章节窗口（默认前后各 2–3 章），
/// 滑到边界时向对应方向追加一章、并裁掉远端章节；插入/裁剪时同步修正
/// `contentOffset`，保证用户视线中的内容不会跳动。
final class BookScrollContainer: UIScrollView, UIScrollViewDelegate {

    // 数据源（由 SwiftUI 侧注入）
    private var chapterCount = 0
    private var attributedProvider: ((Int) -> NSAttributedString)?
    private var contentWidth: CGFloat = 320
    private var horizontalInset: CGFloat = 0

    /// 章与章之间的留白
    private let chapterGap: CGFloat = 10
    /// 距离边界多少时开始预加载
    private let prefetchMargin: CGFloat = 1400
    /// 窗口远端保留多少章
    private let keepBehind = 3
    private let keepAhead = 4

    private var layouts: [Int: ChapterLayout] = [:]
    private var views: [Int: ChapterTextView] = [:]
    private var tops: [Int: CGFloat] = [:]
    /// 当前已加载的连续章节区间
    private var loadedRange: ClosedRange<Int>?
    private var lastSignature = ""
    private var didConfigure = false

    private var reportedChapter = -1
    private var reportedChar = -1
    private var pendingRestore: (chapter: Int, char: Int)?
    private var isAdjusting = false

    var onPositionChange: ((Int, Int) -> Void)?
    var onTap: (() -> Void)?
    /// 双击正文：回调（章号，章内字符位置），用于「从这里开始朗读」
    var onDoubleTap: ((Int, Int) -> Void)?

    /// 当前主题，供选中气泡取色
    private var currentTheme: ReadingTheme = .paper
    /// 长按选中状态
    private var selection: (chapter: Int, range: NSRange)?
    private lazy var bubble: SelectionBubble = {
        let view = SelectionBubble()
        view.onPlay = { [weak self] in
            guard let self, let selection = self.selection else { return }
            self.clearSelection()
            self.onDoubleTap?(selection.chapter, selection.range.location)
        }
        view.onCopy = { [weak self] in
            guard let self, let selection = self.selection,
                  let layout = self.layouts[selection.chapter] else { return }
            let text = layout.attributed.attributedSubstring(from: selection.range).string
            UIPasteboard.general.string = text
            self.clearSelection()
        }
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        addGestureRecognizer(doubleTap)
        // 双击优先：单击要等双击失败才触发，避免双击时工具栏闪两下
        tap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = false
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap() {
        if selection != nil { clearSelection(); return }
        onTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        clearSelection()
        guard let hit = characterIndex(near: gesture.location(in: self)) else { return }
        onDoubleTap?(hit.chapter, hit.char)
    }

    /// 长按：选中手指下这一句，弹出「从这里读 / 复制」
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        selectSentence(at: gesture.location(in: self))
    }

    /// 选中某一句（也供自测注入）
    func selectSentence(at pointInView: CGPoint) {
        guard let hit = characterIndex(near: pointInView),
              let layout = layouts[hit.chapter] else { return }

        let range = SentenceRange.containing(hit.char, in: layout.attributed.string as NSString)
        guard range.length > 0 else { return }

        clearSelection(keepBubble: true)
        selection = (hit.chapter, range)
        if let view = views[hit.chapter] {
            view.selectionColor = currentTheme.uiSelection
            view.selectionRange = range
        }

        let rects = layout.highlightRects(for: range)
        guard let first = rects.first, let top = tops[hit.chapter] else { return }
        // 转成滚动容器的内容坐标，气泡跟着这段文字走
        let rect = first.offsetBy(dx: horizontalInset, dy: top)
        bubble.present(above: rect, in: self, theme: currentTheme)
    }

    func clearSelection(keepBubble: Bool = false) {
        selection = nil
        for (_, view) in views where view.selectionRange != nil {
            view.selectionRange = nil
        }
        if !keepBubble { bubble.dismiss() }
    }

    /// 视图坐标（含滚动偏移）→（章，字符）
    func characterIndex(near pointInView: CGPoint) -> (chapter: Int, char: Int)? {
        let contentPoint = CGPoint(
            x: pointInView.x - horizontalInset,
            y: pointInView.y + contentOffset.y + contentInset.top
        )
        return characterIndex(at: contentPoint)
    }

    /// 内容坐标 → （章，字符）
    private func characterIndex(at point: CGPoint) -> (chapter: Int, char: Int)? {
        guard let loadedRange else { return nil }
        for ch in loadedRange {
            guard let top = tops[ch], let layout = layouts[ch] else { continue }
            if point.y >= top, point.y <= top + layout.height {
                return (ch, layout.characterIndex(at: CGPoint(x: point.x, y: point.y - top)))
            }
        }
        return nil
    }

    /// 更新朗读高亮（只影响一章，不触发重排）
    func setHighlight(chapter: Int, range: NSRange?, color: UIColor) {
        for (ch, view) in views {
            if ch == chapter, let range {
                view.highlightColor = color
                view.highlightRange = range
            } else if view.highlightRange != nil {
                view.highlightRange = nil
            }
        }
    }

    /// 让某个字符所在行保持可见（朗读跟随用）
    func ensureVisible(chapter: Int, char: Int, animated: Bool = true) {
        guard let layout = layouts[chapter], let top = tops[chapter] else { return }
        let y = top + layout.topOffset(forCharacter: char)
        let visibleTop = contentOffset.y + contentInset.top
        let visibleBottom = contentOffset.y + bounds.height - contentInset.bottom
        let upper = visibleBottom - 90
        guard y < visibleTop + 20 || y > upper else { return }
        let maxY = max(0, contentSize.height - (bounds.height - contentInset.top - contentInset.bottom))
        let target = min(max(0, y - 60), maxY)
        setContentOffset(CGPoint(x: 0, y: target - contentInset.top), animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 首次拿到尺寸时补一次定位：否则要等下一次 SwiftUI 刷新才跳到上次阅读位置
        if let pending = pendingRestore, bounds.height > 40 {
            pendingRestore = nil
            applyPosition(chapter: pending.chapter, char: pending.char)
        }
    }

    // MARK: 配置

    func configure(
        chapterCount: Int,
        attributedProvider: @escaping (Int) -> NSAttributedString,
        theme: ReadingTheme,
        contentWidth: CGFloat,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        startChapter: Int,
        startCharacter: Int,
        signature: String
    ) {
        backgroundColor = theme.uiBackground
        currentTheme = theme

        let width = max(120, contentWidth)
        let needsRebuild = !didConfigure
            || signature != lastSignature
            || loadedRange == nil
            || !(loadedRange?.contains(startChapter) ?? false)

        self.chapterCount = max(1, chapterCount)
        self.attributedProvider = attributedProvider
        self.contentWidth = width
        self.horizontalInset = horizontalInset

        let inset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if contentInset != inset { contentInset = inset }

        if needsRebuild {
            lastSignature = signature
            didConfigure = true
            rebuild(center: startChapter, restoreChar: startCharacter)
        } else {
            // 宽度或内边距变化时只需要重新摆放
            relayoutPositions()
        }

        if let pending = pendingRestore, bounds.height > 40 {
            pendingRestore = nil
            applyPosition(chapter: pending.chapter, char: pending.char)
        }
    }

    /// 重建窗口：以 center 为中心装载若干章
    private func rebuild(center: Int, restoreChar: Int) {
        for (_, v) in views { v.removeFromSuperview() }
        views.removeAll()
        layouts.removeAll()
        tops.removeAll()

        let lo = max(0, center - 1)
        let hi = min(chapterCount - 1, center + 2)
        loadedRange = lo...hi
        for ch in lo...hi { loadChapter(ch) }

        relayoutPositions()
        pendingRestore = (center, max(0, restoreChar))
        if bounds.height > 40 {
            pendingRestore = nil
            applyPosition(chapter: center, char: max(0, restoreChar))
        }
    }

    @discardableResult
    private func loadChapter(_ ch: Int) -> ChapterLayout? {
        if let existing = layouts[ch] { return existing }
        guard ch >= 0, ch < chapterCount, let provider = attributedProvider else { return nil }
        let layout = ChapterLayout(attributed: provider(ch), width: contentWidth)
        layouts[ch] = layout
        let view = ChapterTextView(frame: .zero)
        view.layout = layout
        addSubview(view)
        views[ch] = view
        return layout
    }

    /// 重新计算各章 y 坐标并摆放视图
    private func relayoutPositions() {
        guard let loadedRange else { return }
        var y: CGFloat = 0
        var newTops: [Int: CGFloat] = [:]
        for ch in loadedRange {
            guard let layout = layouts[ch] else { continue }
            newTops[ch] = y
            views[ch]?.frame = CGRect(x: horizontalInset, y: y, width: contentWidth, height: layout.height)
            y += layout.height + chapterGap
        }
        tops = newTops
        contentSize = CGSize(width: contentWidth + horizontalInset * 2, height: max(1, y))
    }

    // MARK: 动态扩缩窗口

    private func appendNextIfNeeded() {
        guard let loadedRange, loadedRange.upperBound + 1 < chapterCount else { return }
        let next = loadedRange.upperBound + 1
        guard loadChapter(next) != nil else { return }
        self.loadedRange = loadedRange.lowerBound...next
        relayoutPositions()
        trimTopIfNeeded()
    }

    private func prependPreviousIfNeeded() {
        guard let loadedRange, loadedRange.lowerBound > 0 else { return }
        let prev = loadedRange.lowerBound - 1
        guard let layout = loadChapter(prev) else { return }

        let shift = layout.height + chapterGap
        self.loadedRange = prev...loadedRange.upperBound
        relayoutPositions()

        // 前插后整体下移，等量修正 offset，视觉位置保持不变
        isAdjusting = true
        contentOffset.y += shift
        isAdjusting = false
        trimBottomIfNeeded()
    }

    /// 裁掉离视口过远的上方章节
    private func trimTopIfNeeded() {
        guard let loadedRange else { return }
        let visibleTop = contentOffset.y + contentInset.top
        var lo = loadedRange.lowerBound
        while lo < loadedRange.upperBound {
            guard let top = tops[lo], let layout = layouts[lo] else { break }
            if top + layout.height + chapterGap < visibleTop - CGFloat(keepBehind) * 2000 {
                views[lo]?.removeFromSuperview()
                views[lo] = nil
                layouts[lo] = nil
                lo += 1
            } else {
                break
            }
        }
        if lo != loadedRange.lowerBound {
            self.loadedRange = lo...loadedRange.upperBound
            relayoutPositions()
        }
    }

    private func trimBottomIfNeeded() {
        guard let loadedRange else { return }
        let visibleBottom = contentOffset.y + bounds.height - contentInset.bottom
        var hi = loadedRange.upperBound
        while hi > loadedRange.lowerBound {
            guard let top = tops[hi], let layout = layouts[hi] else { break }
            if top > visibleBottom + CGFloat(keepAhead) * 2000 {
                views[hi]?.removeFromSuperview()
                views[hi] = nil
                layouts[hi] = nil
                hi -= 1
            } else {
                break
            }
        }
        if hi != loadedRange.upperBound {
            self.loadedRange = loadedRange.lowerBound...hi
            relayoutPositions()
        }
    }

    // MARK: 位置换算

    /// 当前视口顶部所在的 (章, 章内字符)
    var position: (chapter: Int, char: Int) {
        guard let loadedRange, !tops.isEmpty else { return (0, 0) }
        let y = contentOffset.y + contentInset.top
        var best = loadedRange.lowerBound
        for ch in loadedRange {
            if let top = tops[ch], top <= y + 1 { best = ch } else { break }
        }
        let local = y - (tops[best] ?? 0)
        let char = layouts[best]?.characterIndex(atY: max(0, local)) ?? 0
        return (best, char)
    }

    private func applyPosition(chapter: Int, char: Int) {
        guard let layout = layouts[chapter], let top = tops[chapter] else {
            // 目标章不在窗口内：重建
            rebuild(center: chapter, restoreChar: char)
            return
        }
        let visible = max(1, bounds.height - contentInset.top - contentInset.bottom)
        let target = top + layout.topOffset(forCharacter: char)
        let maxY = max(0, contentSize.height - visible)
        let y = min(max(0, target), maxY)
        isAdjusting = true
        setContentOffset(CGPoint(x: 0, y: y - contentInset.top), animated: false)
        isAdjusting = false
        report(force: true)
    }

    func scroll(toChapter chapter: Int, char: Int, animated: Bool) {
        guard chapter >= 0, chapter < chapterCount else { return }
        if layouts[chapter] == nil || tops[chapter] == nil {
            rebuild(center: chapter, restoreChar: char)
            return
        }
        guard let layout = layouts[chapter], let top = tops[chapter] else { return }
        let visible = max(1, bounds.height - contentInset.top - contentInset.bottom)
        // 让目标行落在视口上方 18% 处，读起来更舒服
        let target = top + layout.topOffset(forCharacter: char) - visible * 0.18
        let maxY = max(0, contentSize.height - visible)
        let y = min(max(0, target), maxY)
        setContentOffset(CGPoint(x: 0, y: y - contentInset.top), animated: animated)
        report(force: true)
    }

    /// 相对当前位置向下滚动 `distance` 点。
    /// - Returns: false 表示已经到内容末尾（自动阅读据此停止）
    @discardableResult
    func scrollBy(_ distance: CGFloat, animated: Bool) -> Bool {
        let visible = max(1, bounds.height - contentInset.top - contentInset.bottom)
        let maxY = max(0, contentSize.height - visible)
        let current = contentOffset.y + contentInset.top
        let target = current + distance
        if target >= maxY - 0.5 {
            setContentOffset(CGPoint(x: 0, y: maxY - contentInset.top), animated: animated)
            return false
        }
        setContentOffset(CGPoint(x: 0, y: target - contentInset.top), animated: animated)
        return true
    }

    private func report(force: Bool) {
        let pos = position
        if !force && pos.chapter == reportedChapter && abs(pos.char - reportedChar) < 6 { return }
        reportedChapter = pos.chapter
        reportedChar = pos.char
        onPositionChange?(pos.chapter, pos.char)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjusting else { return }
        if selection != nil { clearSelection() }
        report(force: false)

        let visibleBottom = contentOffset.y + bounds.height - contentInset.bottom
        let maxY = contentSize.height - contentInset.bottom
        if maxY - visibleBottom < prefetchMargin {
            appendNextIfNeeded()
        }
        let visibleTop = contentOffset.y + contentInset.top
        if visibleTop < prefetchMargin {
            prependPreviousIfNeeded()
        }
    }
}

// MARK: - 控制代理

/// 让 SwiftUI 侧能命令滚动视图跳转，而不必把滚动位置放进 @State（避免每帧重绘）。
final class ScrollProxy: ObservableObject {
    weak var container: BookScrollContainer?

    /// 当前视口顶部的章号
    var chapter: Int = 0
    /// 当前视口顶部在该章内的字符位置
    var characterIndex: Int = 0
    /// 最近一次保存时间（用于节流）
    var lastSaveAt: Date = .distantPast
    /// 最近一次用于保存的分页数量
    var lastPageCount: Int = 1

    var hasRendered: Bool { container != nil }

    func scroll(toChapter chapter: Int, char: Int, animated: Bool = true) {
        container?.scroll(toChapter: chapter, char: char, animated: animated)
    }

    /// 相对滚动一屏；返回 false 表示已经到全书末尾
    @discardableResult
    func scrollBy(_ distance: CGFloat, animated: Bool = true) -> Bool {
        container?.scrollBy(distance, animated: animated) ?? false
    }

    func refreshPosition() {
        guard let container else { return }
        let pos = container.position
        chapter = pos.chapter
        characterIndex = pos.char
    }

    /// 朗读跟随时让目标行留在视口内
    func ensureVisible(chapter: Int, char: Int) {
        container?.ensureVisible(chapter: chapter, char: char)
    }

    /// 命中测试（视图坐标），供调试注入/外部手势复用
    func characterIndex(near point: CGPoint) -> (chapter: Int, char: Int)? {
        container?.characterIndex(near: point)
    }

    /// 自测：直接选中某一句
    func selectSentence(at point: CGPoint) {
        container?.selectSentence(at: point)
    }
}

// MARK: - SwiftUI 包装

struct BookScrollView: UIViewRepresentable {
    let chapterCount: Int
    let attributedProvider: (Int) -> NSAttributedString
    let theme: ReadingTheme
    let contentWidth: CGFloat
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let startChapter: Int
    let startCharacter: Int
    let signature: String
    let proxy: ScrollProxy

    /// 朗读高亮：章号 + 章内字符区间
    let highlightChapter: Int
    let highlightRange: NSRange?
    let highlightColor: UIColor

    var onPositionChange: (Int, Int) -> Void
    var onTap: () -> Void
    var onDoubleTap: (Int, Int) -> Void

    func makeUIView(context: Context) -> BookScrollContainer {
        let view = BookScrollContainer()
        view.onPositionChange = onPositionChange
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        proxy.container = view
        return view
    }

    func updateUIView(_ view: BookScrollContainer, context: Context) {
        view.onPositionChange = onPositionChange
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        proxy.container = view
        view.configure(
            chapterCount: chapterCount,
            attributedProvider: attributedProvider,
            theme: theme,
            contentWidth: contentWidth,
            horizontalInset: horizontalInset,
            topInset: topInset,
            bottomInset: bottomInset,
            startChapter: startChapter,
            startCharacter: startCharacter,
            signature: signature
        )
        view.setHighlight(chapter: highlightChapter, range: highlightRange, color: highlightColor)
    }
}
