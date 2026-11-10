import UIKit

// MARK: - 句子边界

/// 选中/朗读都以「一句」为单位：中文长句里从半句开始读很别扭，
/// 而按整句选又比整段选更精准，接近系统文本选择的手感。
enum SentenceRange {
    private static let terminators: Set<Character> = [
        "。", "！", "？", "；", "…", "\n", "!", "?", ";", "：", ":"
    ]
    private static let closers: Set<Character> = ["」", "』", "”", "’", "）", ")", "】", "》"]

    /// 包含 `index` 这一句的区间
    static func containing(_ index: Int, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let target = min(max(0, index), text.length - 1)

        var start = target
        while start > 0 {
            let prev = text.substring(with: NSRange(location: start - 1, length: 1))
            if let ch = prev.first, terminators.contains(ch) { break }
            start -= 1
        }

        var end = target
        while end < text.length {
            let unit = text.substring(with: NSRange(location: end, length: 1))
            guard let ch = unit.first else { break }
            end += 1
            if terminators.contains(ch) {
                // 把紧跟的右引号/右括号一起选进去
                if end < text.length,
                   let next = text.substring(with: NSRange(location: end, length: 1)).first,
                   closers.contains(next) {
                    end += 1
                }
                break
            }
        }
        return NSRange(location: start, length: max(0, end - start))
    }
}

// MARK: - 选中后的浮动气泡

/// 选中一句后弹出的小气泡：▶ 从这里朗读 / ⧉ 复制。
/// 用图标而不是文字按钮，和整体克制的手感一致。
final class SelectionBubble: UIView {
    var onPlay: (() -> Void)?
    var onCopy: (() -> Void)?

    private let playButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        row.axis = .horizontal
        row.spacing = 4
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false

        configure(playButton, symbol: "play.fill", action: #selector(handlePlay))
        configure(copyButton, symbol: "doc.on.doc", action: #selector(handleCopy))
        row.addArrangedSubview(playButton)
        row.addArrangedSubview(copyButton)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: UIButton, symbol: String, action: Selector) {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    func apply(theme: ReadingTheme) {
        // 气泡要和页面区分开：夜间用略亮的浮层色，否则会和深色底融成一片
        backgroundColor = theme == .night ? UIColor(hex: 0x2C3138) : .white
        layer.borderWidth = 0.5
        layer.borderColor = (theme == .night
            ? UIColor.white.withAlphaComponent(0.12)
            : theme.uiSecondary.withAlphaComponent(0.35)).cgColor
        playButton.tintColor = theme.uiAccent
        copyButton.tintColor = theme.uiForeground
    }

    /// 在 `host` 里把气泡摆在 `rect` 上方（放不下就摆下方）
    func present(above rect: CGRect, in host: UIView, theme: ReadingTheme) {
        apply(theme: theme)
        let size = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bounds = CGRect(origin: .zero, size: size)
        isHidden = false
        host.addSubview(self)

        let gap: CGFloat = 8
        var y = rect.minY - size.height - gap
        if y < 4 { y = rect.maxY + gap }
        var x = rect.midX - size.width / 2
        x = min(max(6, x), max(6, host.bounds.width - size.width - 6))
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func dismiss() {
        isHidden = true
        removeFromSuperview()
    }

    @objc private func handlePlay() {
        onPlay?()
        dismiss()
    }

    @objc private func handleCopy() {
        onCopy?()
        dismiss()
    }
}

// MARK: - 主题色

extension ReadingTheme {
    /// 选中底色：比朗读高亮更中性，避免两者混淆
    var uiSelection: UIColor {
        self == .night
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.black.withAlphaComponent(0.10)
    }
}
