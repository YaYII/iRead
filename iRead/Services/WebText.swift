import Foundation

/// 网页抓取通用的 HTML / 文本处理工具。纯 Foundation，无第三方依赖。
/// 供网络书源解析引擎把抓取到的 HTML 片段清洗成可入书架的纯文本。
enum WebText {

    // MARK: - HTML 实体

    /// 常见命名实体。数字实体（&#123; / &#x1F600;）单独用扫描器处理。
    private static let entities: [String: String] = [
        "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">",
        "quot": "\"", "apos": "'", "hellip": "…", "mdash": "—",
        "ndash": "–", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "middot": "·", "bull": "•", "times": "×", "divide": "÷",
        "copy": "©", "reg": "®", "trade": "™", "yen": "¥",
        "pound": "£", "euro": "€", "cent": "¢", "sect": "§",
        "para": "¶", "deg": "°", "plusmn": "±", "micro": "µ",
        "laquo": "«", "raquo": "»", "frac12": "½", "frac14": "¼",
        "sup2": "²", "sup3": "³", "alpha": "α", "beta": "β", "gamma": "γ"
    ]

    /// 解码 HTML 实体：命名实体 + 十进制/十六进制数字实体。
    static func decodeEntities(_ text: String) -> String {
        // 先处理数字实体，用扫描器逐段拼，避免重复替换顺序问题
        var out = ""
        let chars = Array(text)
        var idx = 0
        while idx < chars.count {
            let c = chars[idx]
            if c == "&", idx + 1 < chars.count, chars[idx + 1] == "#" {
                var j = idx + 2
                var hex = false
                if j < chars.count, chars[j] == "x" || chars[j] == "X" {
                    hex = true
                    j += 1
                }
                let digitsStart = j
                while j < chars.count, hex ? chars[j].isHexDigit : chars[j].isNumber {
                    j += 1
                }
                if j > digitsStart, j < chars.count, chars[j] == ";" {
                    let digitStr = String(chars[digitsStart..<j])
                    let code = hex ? Int(digitStr, radix: 16) : Int(digitStr)
                    if let code, code > 0, let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                        idx = j + 1
                        continue
                    }
                }
            }
            out.append(c)
            idx += 1
        }

        // 命名实体：一次性正则替换
        guard let re = try? NSRegularExpression(pattern: "&([a-zA-Z]+);") else { return out }
        let ns = out as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: out, range: range)
        var result = ""
        var last = 0
        for m in matches {
            let whole = m.range(at: 0)
            if whole.location == NSNotFound { continue }
            result += ns.substring(with: NSRange(location: last, length: whole.location - last))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            result += entities[name] ?? ns.substring(with: whole)
            last = whole.location + whole.length
        }
        if last < ns.length {
            result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        }
        return result
    }

    // MARK: - 去标签 / 转纯文本

    /// 去掉 script/style 区块（含内容），避免正文里混进 JS/CSS。
    static func stripScripts(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(
            of: "<script\\b[^>]*>[\\s\\S]*?</script>", with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "<style\\b[^>]*>[\\s\\S]*?</style>", with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return s
    }

    /// 把 HTML 片段转成纯文本：块级标签与 <br> 变换行，其余标签去掉。
    static func htmlToText(_ html: String) -> String {
        var s = stripScripts(html)
        // 块级结束标签 → 换行
        s = s.replacingOccurrences(
            of: "</?(?:p|div|h[1-6]|li|tr|article|section|blockquote|table|ul|ol|br|hr)\\b[^>]*>",
            with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        // 其余标签去掉
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        return cleanWhitespace(s)
    }

    /// 清理空白：去零宽字符/BOM、行尾空格、3+ 连续换行压成 2 个。
    static func cleanWhitespace(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\u{FEFF}", with: "")
        s = s.replacingOccurrences(of: "\u{200B}", with: "")
        s = s.replacingOccurrences(of: "\u{200C}", with: "")
        s = s.replacingOccurrences(of: "\u{200D}", with: "")
        s = s.replacingOccurrences(of: "[\\t\\u{00A0}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)[ \\t]+$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 正则取值

    /// 返回正则第 group 个捕获组在 text 中的全部匹配（去重、去空）。group=0 为整个匹配。
    static func captures(in text: String, pattern: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [String] = []
        for m in matches {
            guard m.numberOfRanges > group else { continue }
            let r = m.range(at: group)
            guard r.location != NSNotFound else { continue }
            let v = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out.append(v) }
        }
        return out
    }

    /// 返回正则第一次匹配的第 group 个捕获组；找不到返回 nil。
    static func firstCapture(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > group else { return nil }
        let r = m.range(at: group)
        guard r.location != NSNotFound else { return nil }
        let v = (text as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 正则替换（书源清洗规则用）。
    static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - URL

    /// 相对 URL 转绝对 URL。href 可能是 //、/、相对路径或完整 URL。
    static func absolute(_ href: String, base: String) -> String? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return nil }
        if h.hasPrefix("http://") || h.hasPrefix("https://") { return h }
        if h.hasPrefix("//") { return "https:" + h }
        guard let baseURL = URL(string: base) else { return nil }
        if h.hasPrefix("/") {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comps?.path = h
            comps?.query = nil
            comps?.fragment = nil
            return comps?.url?.absoluteString
        }
        return URL(string: h, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    /// 把 URL 模板里的占位符替换成值。占位符形如 {key} / {url}。
    static func fill(_ template: String, placeholders: [String: String]) -> String {
        var s = template
        for (key, value) in placeholders {
            s = s.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return s
    }

    /// 按 GBK/UTF-8 自动识别请求返回的数据（复用 App 现有识别逻辑）。
    static func decodeResponse(_ data: Data) -> String {
        TextParser.decode(data)
    }
}
