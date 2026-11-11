import SwiftUI
import UIKit

// MARK: - 单章文字视图

/// 一章正文。用系统 `UITextView`（TextKit 1）承载，**不再自己画字**。
///
/// 这样长按选字、放大镜、左右选中手柄、复制 / 查询 / 翻译全部是系统行为，
/// 手感和别家阅读器一致；我们只在编辑菜单最前面加一个「从这里朗读」。
/// 自己用 CoreText 画字 + 自绘选中框，永远做不出系统那套选中手感。
final class ChapterTextView: UITextView, UITextViewDelegate {

    /// 点「从这里朗读」的回调，参数是选中区间（章内字符坐标）
    var onSpeakSelection: ((NSRange) -> Void)?

    /// 当前朗读高亮区间，避免重复写 textStorage
    private var speechRange: NSRange?

    init(attributed: NSAttributedString, width: CGFloat, theme: ReadingTheme) {
        super.init(frame: .zero, textContainer: nil)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        // 容器尺寸自己说了算：跟随视图宽度会在 sizeThatFits 时把高度截断
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.size = CGSize(width: max(1, width), height: 100_000)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        dataDetectorTypes = []
        // 拖拽会和滚动抢手势，阅读场景用不上
        textDragInteraction?.isEnabled = false
        tintColor = theme.uiAccent
        delegate = self

        attributedText = attributed
        // UITextView 是 UIScrollView，会在内部把 textContainer.size 按 bounds 重置
        // （此时 bounds 还是 .zero），容器高度变 0 就只排出十几行，整章被裁掉大半。
        // 因此排版前必须把容器尺寸再钉一次。
        layoutManager.allowsNonContiguousLayout = false
        textContainer.size = CGSize(width: max(1, width), height: 100_000)
        layoutManager.ensureLayout(for: textContainer)
        var textHeight = ceil(layoutManager.usedRect(for: textContainer).height) + 2
        if textHeight < 2 {
            textHeight = ceil(sizeThatFits(CGSize(width: max(1, width), height: 100_000)).height)
        }
        frame = CGRect(x: 0, y: 0, width: max(1, width), height: max(1, textHeight))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 朗读高亮

    /// 用背景色属性做高亮，系统选中时两者不会互相打架
    func setSpeechHighlight(_ range: NSRange?, color: UIColor) {
        guard range != speechRange else { return }
        let length = textStorage.length
        textStorage.beginEditing()
        if let old = speechRange, old.length > 0, old.location + old.length <= length {
            textStorage.removeAttribute(.backgroundColor, range: old)
        }
        if let range, range.length > 0, range.location + range.length <= length {
            textStorage.addAttribute(.backgroundColor, value: color, range: range)
        }
        textStorage.endEditing()
        speechRange = range
    }

    // MARK: 坐标换算

    /// 视图内坐标 → 章内字符
    func characterIndex(atLocalPoint point: CGPoint) -> Int {
        guard textStorage.length > 0 else { return 0 }
        let p = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let pos = closestPosition(to: p) else { return 0 }
        return offset(from: beginningOfDocument, to: pos)
    }

    /// 某字符所在行的顶部（视图坐标，原点左上）
    func topOffset(forCharacter index: Int) -> CGFloat {
        let length = textStorage.length
        guard length > 0 else { return 0 }
        let clamped = min(max(0, index), length - 1)
        let rect = lineRect(forCharacter: clamped)
        if !rect.isEmpty { return rect.minY }
        // 换行符这类没有实体字形的位置，退回前一个字符所在行
        if clamped > 0 {
            let prev = lineRect(forCharacter: clamped - 1)
            if !prev.isEmpty { return prev.minY }
        }
        return 0
    }

    private func lineRect(forCharacter index: Int) -> CGRect {
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return .zero }
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    }

    // MARK: 编辑菜单

    /// 在系统菜单最前面插入「从这里朗读」。
    /// 放在后面会被系统折叠到第二页，用户根本翻不到。
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        makeEditMenu(for: range, suggestedActions: suggestedActions)
    }

    /// iOS 26 起改用多区间版本；不实现它，系统会回落到上面那个已废弃的方法
    @available(iOS 26.0, *)
    func textView(
        _ textView: UITextView,
        editMenuForTextInRanges ranges: [NSValue],
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let first = ranges.first?.rangeValue else { return nil }
        var lo = first.location
        var hi = first.location + first.length
        for value in ranges.dropFirst() {
            let r = value.rangeValue
            lo = min(lo, r.location)
            hi = max(hi, r.location + r.length)
        }
        return makeEditMenu(for: NSRange(location: lo, length: max(0, hi - lo)), suggestedActions: suggestedActions)
    }

    private func makeEditMenu(for range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return nil }
        let speak = UIAction(
            title: "从这里朗读",
            image: UIImage(systemName: "play.fill")
        ) { [weak self] _ in
            guard let self else { return }
            let start = SentenceRange.readableStart(at: range.location, in: self.text as NSString)
            self.onSpeakSelection?(NSRange(location: start, length: max(1, range.length)))
        }
        return UIMenu(children: [speak] + suggestedActions)
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

    private var views: [Int: ChapterTextView] = [:]
    private var heights: [Int: CGFloat] = [:]
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
    /// 编辑菜单「从这里朗读」的回调（章号，选中句在章内的起点）
    var onStartSpeech: ((Int, Int) -> Void)?

    /// 当前主题
    private var currentTheme: ReadingTheme = .paper
    /// 是否跟随朗读自动滚动。用户手动滚一下就把控制权交还给他。
    private(set) var isFollowingSpeech = true
    /// 当前朗读高亮（重建窗口后要补画回去）
    private var highlight: (chapter: Int, range: NSRange?, color: UIColor) = (0, nil, .clear)

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

        // 双击不再承担任何功能（不再「点屏幕就开始朗读」），
        // 留着识别器只为让单击失败，避免双击把工具栏闪两下。
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(ignoreDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap() {
        if hasSelection { clearSelection(); return }
        onTap?()
    }

    /// 双击不再触发朗读；识别器只用来让上面的单击失败
    @objc private func ignoreDoubleTap() {}

    // MARK: 选中

    var hasSelection: Bool {
        views.values.contains { $0.selectedRange.length > 0 }
    }

    func clearSelection() {
        for (_, view) in views where view.selectedRange.length > 0 {
            view.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    /// 选中某一句（仅供自测注入：`--longpress x,y`）
    func selectSentence(at pointInView: CGPoint) {
        guard let hit = characterIndex(near: pointInView),
              let view = views[hit.chapter] else {
            #if DEBUG
            print("[Select] MISS point=\(pointInView) offset=\(contentOffset.y) inset=\(contentInset.top)")
            #endif
            return
        }
        let range = SentenceRange.containing(hit.char, in: view.text as NSString)
        guard range.length > 0 else { return }
        view.selectedRange = range
        view.becomeFirstResponder()
        #if DEBUG
        // 自测注入：选中后直接打印结果，系统编辑菜单只认真实触摸，这里不做模拟
        print("[Select] point=\(pointInView) ch=\(hit.chapter) char=\(hit.char) range=\(range)")
        #endif
    }

    /// 视图坐标（含滚动偏移）→（章，字符）
    func characterIndex(near pointInView: CGPoint) -> (chapter: Int, char: Int)? {
        let contentPoint = CGPoint(
            x: pointInView.x - horizontalInset,
            y: pointInView.y + contentOffset.y
        )
        return characterIndex(at: contentPoint)
    }

    /// 内容坐标 → （章，字符）
    private func characterIndex(at point: CGPoint) -> (chapter: Int, char: Int)? {
        guard let loadedRange else { return nil }
        for ch in loadedRange {
            guard let top = tops[ch], let height = heights[ch], let view = views[ch] else { continue }
            if point.y >= top, point.y <= top + height {
                return (ch, view.characterIndex(atLocalPoint: CGPoint(x: point.x, y: point.y - top)))
            }
        }
        return nil
    }

    // MARK: 朗读高亮

    func setHighlight(chapter: Int, range: NSRange?, color: UIColor) {
        highlight = (chapter, range, color)
        for (ch, view) in views {
            if ch == chapter, let range {
                view.setSpeechHighlight(range, color: color)
            } else {
                view.setSpeechHighlight(nil, color: .clear)
            }
        }
    }

    /// 让某个字符所在行保持可见（朗读跟随用）
    ///
    /// 用户一旦手动滚动就交还控制权：不再自动拽回朗读位置，
    /// 只有等他滚回朗读行附近才自动恢复跟随。
    func ensureVisible(chapter: Int, char: Int, animated: Bool = true) {
        guard let view = views[chapter], let top = tops[chapter] else { return }
        let y = top + view.topOffset(forCharacter: char)
        let visibleTop = contentOffset.y + contentInset.top
        let visibleBottom = contentOffset.y + bounds.height - contentInset.bottom

        if !isFollowingSpeech {
            if y >= visibleTop, y <= visibleBottom - 40 {
                isFollowingSpeech = true
            }
            return
        }

        let upper = visibleBottom - 90
        guard y < visibleTop + 20 || y > upper else { return }
        let maxY = max(0, contentSize.height - (bounds.height - contentInset.top - contentInset.bottom))
        let target = min(max(0, y - 60), maxY)
        setContentOffset(CGPoint(x: 0, y: target - contentInset.top), animated: animated)
    }

    /// 听书换段时把视口带到朗读位置。用户正在别处看时什么都不做。
    func follow(chapter: Int, char: Int) {
        guard isFollowingSpeech else { return }
        if views[chapter] != nil, tops[chapter] != nil {
            ensureVisible(chapter: chapter, char: char, animated: true)
        } else {
            scroll(toChapter: chapter, char: char, animated: false)
        }
    }

    /// 用户主动开播 / 重新点「从这儿读」时恢复跟随
    func resumeFollowing() {
        isFollowingSpeech = true
    }

    /// 用户主动回到原阅读进度时交出跟随控制权，别把人又拽回朗读位置
    func pauseFollowing() {
        isFollowingSpeech = false
    }

    #if DEBUG
    /// 自测：模拟用户手动滚开（会像真拖动一样交出跟随控制权）
    func simulateUserScroll(by dy: CGFloat) {
        isFollowingSpeech = false
        setContentOffset(CGPoint(x: 0, y: contentOffset.y + dy), animated: false)
    }
    #endif

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
        heights.removeAll()
        tops.removeAll()

        let lo = max(0, center - 1)
        let hi = min(chapterCount - 1, center + 2)
        loadedRange = lo...hi
        for ch in lo...hi { loadChapter(ch) }

        relayoutPositions()
        // 重建后把朗读高亮补回去
        if let view = views[highlight.chapter], let range = highlight.range {
            view.setSpeechHighlight(range, color: highlight.color)
        }

        pendingRestore = (center, max(0, restoreChar))
        if bounds.height > 40 {
            pendingRestore = nil
            applyPosition(chapter: center, char: max(0, restoreChar))
        }
    }

    @discardableResult
    private func loadChapter(_ ch: Int) -> ChapterTextView? {
        if let existing = views[ch] { return existing }
        guard ch >= 0, ch < chapterCount, let provider = attributedProvider else { return nil }

        let view = ChapterTextView(
            attributed: provider(ch),
            width: contentWidth,
            theme: currentTheme
        )
        view.onSpeakSelection = { [weak self] range in
            guard let self else { return }
            self.clearSelection()
            self.onStartSpeech?(ch, range.location)
        }
        addSubview(view)
        views[ch] = view
        heights[ch] = view.frame.height
        return view
    }

    /// 重新计算各章 y 坐标并摆放视图
    private func relayoutPositions() {
        guard let loadedRange else { return }
        var y: CGFloat = 0
        var newTops: [Int: CGFloat] = [:]
        for ch in loadedRange {
            guard let height = heights[ch] else { continue }
            newTops[ch] = y
            views[ch]?.frame = CGRect(x: horizontalInset, y: y, width: contentWidth, height: height)
            y += height + chapterGap
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
        guard let height = heights[prev] ?? loadChapter(prev)?.frame.height else { return }

        let shift = height + chapterGap
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
            guard let top = tops[lo], let height = heights[lo] else { break }
            if top + height + chapterGap < visibleTop - CGFloat(keepBehind) * 2000 {
                views[lo]?.removeFromSuperview()
                views[lo] = nil
                heights[lo] = nil
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
            guard let top = tops[hi], heights[hi] != nil else { break }
            if top > visibleBottom + CGFloat(keepAhead) * 2000 {
                views[hi]?.removeFromSuperview()
                views[hi] = nil
                heights[hi] = nil
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
        let char = views[best]?.characterIndex(atLocalPoint: CGPoint(x: 0, y: max(0, local))) ?? 0
        return (best, char)
    }

    private func applyPosition(chapter: Int, char: Int) {
        guard let view = views[chapter], let top = tops[chapter] else {
            // 目标章不在窗口内：重建
            rebuild(center: chapter, restoreChar: char)
            return
        }
        let visible = max(1, bounds.height - contentInset.top - contentInset.bottom)
        let target = top + view.topOffset(forCharacter: char)
        let maxY = max(0, contentSize.height - visible)
        let y = min(max(0, target), maxY)
        isAdjusting = true
        setContentOffset(CGPoint(x: 0, y: y - contentInset.top), animated: false)
        isAdjusting = false
        report(force: true)
    }

    func scroll(toChapter chapter: Int, char: Int, animated: Bool) {
        guard chapter >= 0, chapter < chapterCount else { return }
        if views[chapter] == nil || tops[chapter] == nil {
            rebuild(center: chapter, restoreChar: char)
            return
        }
        guard let view = views[chapter], let top = tops[chapter] else { return }
        let visible = max(1, bounds.height - contentInset.top - contentInset.bottom)
        // 让目标行落在视口上方 18% 处，读起来更舒服
        let target = top + view.topOffset(forCharacter: char) - visible * 0.18
        let maxY = max(0, contentSize.height - visible)
        let y = min(max(0, target), maxY)
        setContentOffset(CGPoint(x: 0, y: y - contentInset.top), animated: animated)
        report(force: true)
    }

    private func report(force: Bool) {
        let pos = position
        if !force && pos.chapter == reportedChapter && abs(pos.char - reportedChar) < 6 { return }
        reportedChapter = pos.chapter
        reportedChar = pos.char
        onPositionChange?(pos.chapter, pos.char)
    }

    // MARK: UIScrollViewDelegate

    /// 开始拖动就取消选中：选中状态下滚动会留下一个错位的高亮框。
    /// 同时把「跟随朗读」的控制权交还用户 —— 否则读下一句时会把页面拽回去。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isFollowingSpeech = false
        if hasSelection { clearSelection() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjusting else { return }
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

    var hasRendered: Bool { container != nil }

    func scroll(toChapter chapter: Int, char: Int, animated: Bool = true) {
        container?.scroll(toChapter: chapter, char: char, animated: animated)
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

    /// 听书换段：把视口带到朗读位置（用户手动滚开后自动跳过）
    func follow(chapter: Int, char: Int) {
        container?.follow(chapter: chapter, char: char)
    }

    /// 是否仍在跟随朗读
    var isFollowingSpeech: Bool { container?.isFollowingSpeech ?? true }

    /// 用户主动开播时恢复跟随
    func resumeFollowing() {
        container?.resumeFollowing()
    }

    /// 回到原阅读进度：停止自动跟随
    func pauseFollowing() {
        container?.pauseFollowing()
    }

    /// 命中测试（视图坐标），供调试注入/外部手势复用
    func characterIndex(near point: CGPoint) -> (chapter: Int, char: Int)? {
        container?.characterIndex(near: point)
    }

    /// 自测：直接选中某一句
    func selectSentence(at point: CGPoint) {
        container?.selectSentence(at: point)
    }

    #if DEBUG
    /// 自测：模拟手动滚开
    func simulateUserScroll(by dy: CGFloat) {
        container?.simulateUserScroll(by: dy)
    }
    #endif
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
    var onStartSpeech: (Int, Int) -> Void

    func makeUIView(context: Context) -> BookScrollContainer {
        let view = BookScrollContainer()
        view.onPositionChange = onPositionChange
        view.onTap = onTap
        view.onStartSpeech = onStartSpeech
        proxy.container = view
        return view
    }

    func updateUIView(_ view: BookScrollContainer, context: Context) {
        view.onPositionChange = onPositionChange
        view.onTap = onTap
        view.onStartSpeech = onStartSpeech
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
