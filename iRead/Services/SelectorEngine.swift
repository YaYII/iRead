import Foundation

/// 轻量选择器 DSL 引擎。纯 Foundation：HTML 用平衡标签扫描 + 正则，JSON 用键路径。
/// 输入一个字符串，经过一串以 "." 分隔的操作符，输出字符串数组。
/// 例：`tag(a).class(result-item).attr(href).re('\/(\d+)\.html',1)`
enum SelectorEngine {

    // MARK: - 操作符

    enum Op {
        case tag(String)                 // 取指定标签的整个块（平衡匹配，支持嵌套）
        case `class`(String)             // 取 class 含该值的任意标签块
        case id(String)                  // 取 id 等于该值的标签块
        case attr(String)                // 从当前"开始标签串"里取属性值
        case re(pattern: String, group: Int) // 正则捕获
        case text                        // HTML 块 → 纯文本（含实体解码）
        case entity                      // HTML 实体解码
        case trim                        // 去空白
        case replace(pattern: String, with: String)
        case drop(pattern: String)       // 删掉匹配行（广告行过滤）
        case first
        case last
        case nth(Int)
        case skip(Int)                   // 跳过前 n 项（去掉表格表头、「直达底部」这类干扰行）
        case join(String)
        case json(String)                // JSON 键路径
    }

    // MARK: - 入口

    /// 对 input 依次应用选择器串，返回最终字符串数组。
    static func select(_ selector: String, from input: String) -> [String] {
        let ops = parse(selector)
        var state = [input]
        for op in ops {
            var next: [String] = []
            switch op {
            case .tag(let name):
                for s in state { next.append(contentsOf: blocks(tag: name, in: s)) }
            case .class(let c):
                for s in state { next.append(contentsOf: blocks(className: c, in: s)) }
            case .id(let i):
                for s in state { next.append(contentsOf: blocks(idValue: i, in: s)) }
            case .attr(let name):
                for s in state { if let v = attribute(name, in: s) { next.append(v) } }
            case .re(let pattern, let group):
                for s in state { next.append(contentsOf: WebText.captures(in: s, pattern: pattern, group: group)) }
            case .text:
                for s in state { next.append(WebText.htmlToText(s)) }
            case .entity:
                for s in state { next.append(WebText.decodeEntities(s)) }
            case .trim:
                for s in state { next.append(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            case .replace(let pattern, let template):
                for s in state { next.append(WebText.replace(s, pattern: pattern, with: template)) }
            case .drop(let pattern):
                for s in state { next.append(dropLines(pattern, in: s)) }
            case .first:
                if let f = state.first { next.append(f) }
            case .last:
                if let l = state.last { next.append(l) }
            case .nth(let i):
                if state.indices.contains(i) { next.append(state[i]) }
            case .skip(let n):
                if n < state.count { next.append(contentsOf: state[n...]) }
            case .join(let sep):
                next.append(state.joined(separator: sep))
            case .json(let path):
                for s in state { next.append(contentsOf: jsonValues(s, path: path)) }
            }
            state = next
            if state.isEmpty { break }
        }
        return state
    }

    /// 便捷：取第一个结果
    static func first(_ selector: String, from input: String) -> String? {
        select(selector, from: input).first
    }

    // MARK: - 选择器解析

    /// 按 "." 切分，但忽略引号内和括号内的点（正则里常见 `.*`）。
    static func parse(_ selector: String) -> [Op] {
        let parts = splitTopLevel(selector)
        return parts.compactMap { parseOp($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character? = nil
        var depth = 0
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; current.append(ch); continue }
            if ch == "(" { depth += 1; current.append(ch); continue }
            if ch == ")" { depth = max(0, depth - 1); current.append(ch); continue }
            if ch == "." && depth == 0 {
                parts.append(current); current = ""; continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func parseOp(_ token: String) -> Op? {
        if token.isEmpty { return nil }
        switch token {
        case "text": return .text
        case "entity": return .entity
        case "trim": return .trim
        case "first": return .first
        case "last": return .last
        default: break
        }
        if let args = arguments(token) {
            switch args.name {
            case "tag": return .tag(args.values.first ?? "")
            case "class": return .class(args.values.first ?? "")
            case "id": return .id(args.values.first ?? "")
            case "attr": return .attr(args.values.first ?? "")
            case "re":
                let pattern = args.values.first ?? ""
                let group = args.values.count > 1 ? Int(args.values[1]) ?? 1 : 1
                return .re(pattern: pattern, group: group)
            case "replace":
                return .replace(pattern: args.values.first ?? "", with: args.values.count > 1 ? args.values[1] : "")
            case "drop": return .drop(pattern: args.values.first ?? "")
            case "nth": return .nth(Int(args.values.first ?? "") ?? 0)
            case "skip": return .skip(max(0, Int(args.values.first ?? "") ?? 0))
            case "join": return .join(args.values.first ?? "")
            case "json": return .json(args.values.first ?? "")
            default: return nil
            }
        }
        return nil
    }

    /// 解析 `name(arg1,arg2)`，处理引号内的逗号。
    private static func arguments(_ token: String) -> (name: String, values: [String])? {
        guard let open = token.firstIndex(of: "("), token.last == ")" else { return nil }
        let name = String(token[..<open]).trimmingCharacters(in: .whitespaces)
        let inner = String(token[token.index(after: open)..<token.index(before: token.endIndex)])
        var values: [String] = []
        var cur = ""
        var quote: Character? = nil
        var escaped = false
        for ch in inner {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { cur.append(ch); escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ch == "," { values.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { values.append(cur.trimmingCharacters(in: .whitespaces)) }
        return (name, values)
    }

    // MARK: - HTML 平衡标签扫描

    /// 取所有 <tag>...</tag> 完整块，支持同名标签嵌套（按深度配对）。
    static func blocks(tag name: String, in html: String) -> [String] {
        let target = name.lowercased()
        let ns = html as NSString
        let openPattern = "<\(name)\\b[^>]*>"
        guard let re = try? NSRegularExpression(pattern: openPattern, options: .caseInsensitive) else { return [] }
        let openMatches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var results: [String] = []
        for m in openMatches {
            let start = m.range(at: 0).location
            if let end = findMatchingClose(from: m.range(at: 0).location + m.range(at: 0).length,
                                           tag: target, in: ns) {
                results.append(ns.substring(with: NSRange(location: start, length: end - start)))
            }
        }
        return results
    }

    /// 取所有 class 含指定值的元素块（不限定标签名）。
    static func blocks(className: String, in html: String) -> [String] {
        blocks(attribute: "class", contains: className, in: html)
    }

    /// 取所有 id 等于指定值的元素块。
    static func blocks(idValue: String, in html: String) -> [String] {
        blocks(attribute: "id", equals: idValue, in: html)
    }

    private static func blocks(attribute: String, contains: String? = nil, equals: String? = nil, in html: String) -> [String] {
        let ns = html as NSString
        // 匹配所有开始标签
        guard let re = try? NSRegularExpression(pattern: "<([a-zA-Z][a-zA-Z0-9-]*)\\b[^>]*>", options: []) else { return [] }
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [String] = []
        for m in matches {
            let whole = m.range(at: 0)
            let tagString = ns.substring(with: whole)
            guard let value = attributeValue(attribute, in: tagString) else { continue }
            if let c = contains, !value.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { String($0) == c }) { continue }
            if let e = equals, value != e { continue }
            let tagName = ns.substring(with: m.range(at: 1)).lowercased()
            if let end = findMatchingClose(from: whole.location + whole.length, tag: tagName, in: ns) {
                results.append(ns.substring(with: NSRange(location: whole.location, length: end - whole.location)))
            }
        }
        return results
    }

    /// 从位置 pos 开始，找与 tag 配对闭合标签的结束位置（含 `>`）。
    private static func findMatchingClose(from pos: Int, tag: String, in ns: NSString) -> Int? {
        let openPattern = "<\(tag)\\b[^>]*>"
        let closePattern = "</\(tag)\\s*>"
        guard let openRe = try? NSRegularExpression(pattern: openPattern, options: .caseInsensitive),
              let closeRe = try? NSRegularExpression(pattern: closePattern, options: .caseInsensitive) else { return nil }
        var depth = 1
        var cursor = pos
        let total = ns.length
        let source = ns as String
        while cursor < total {
            let range = NSRange(location: cursor, length: total - cursor)
            let nextOpen = openRe.firstMatch(in: source, range: range)
            let nextClose = closeRe.firstMatch(in: source, range: range)
            // 后面既没有开标签也没有闭标签，说明这个开标签没有配对，放弃。
            if nextOpen == nil && nextClose == nil { return nil }
            // 取位置更靠前的那个；只有闭标签时直接走闭标签分支。
            if let close = nextClose,
               nextOpen == nil || close.range.location < nextOpen!.range.location {
                depth -= 1
                if depth == 0 { return close.range.location + close.range.length }
                cursor = close.range.location + close.range.length
            } else if let open = nextOpen {
                depth += 1
                cursor = open.range.location + open.range.length
            }
        }
        return nil
    }

    /// 从开始标签串里取属性值。
    static func attribute(_ name: String, in tagString: String) -> String? {
        attributeValue(name, in: tagString)
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let ns = tag as NSString
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound { return WebText.decodeEntities(ns.substring(with: r)) }
        }
        return nil
    }

    // MARK: - 行过滤

    private static func dropLines(_ pattern: String, in text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let kept = text.split(separator: "\n").filter { line in
            re.firstMatch(in: String(line), range: NSRange(location: 0, length: (line as NSString).length)) == nil
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - JSON 键路径

    /// 把 JSON 文本按点分键路径取值，数组用 [n] 或 [*]。返回字符串数组。
    static func jsonValues(_ text: String, path: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let values: [Any] = jsonWalk(root, path: path)
        return values.compactMap { valueToString($0) }
    }

    private static func jsonWalk(_ root: Any, path: String) -> [Any] {
        if path.isEmpty { return [root] }
        var current: [Any] = [root]
        let tokens = jsonTokens(path)
        for token in tokens {
            var next: [Any] = []
            if token == "[*]" {
                for v in current { if let arr = v as? [Any] { next.append(contentsOf: arr) } }
            } else if token.hasPrefix("[") && token.hasSuffix("]"),
                      let idx = Int(token.dropFirst().dropLast()) {
                for v in current {
                    if let arr = v as? [Any], arr.indices.contains(idx) { next.append(arr[idx]) }
                }
            } else {
                for v in current {
                    if let dict = v as? [String: Any], let found = dict[token] { next.append(found) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// 把 "data.books[*].title" 拆成 ["data", "books", "[*]", "title"]，
    /// 也兼容 "data.books.[*].title" 这种独立方块的写法。
    private static func jsonTokens(_ path: String) -> [String] {
        var result: [String] = []
        for raw in path.split(separator: ".").map(String.init) {
            if let bracket = raw.firstIndex(of: "[") {
                let key = String(raw[..<bracket]).trimmingCharacters(in: .whitespaces)
                let bracketPart = String(raw[bracket...])
                if !key.isEmpty { result.append(key) }
                result.append(bracketPart)
            } else if !raw.isEmpty {
                result.append(raw)
            }
        }
        return result
    }

    private static func valueToString(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [Any] {
            return arr.compactMap { valueToString($0) }.joined(separator: "\n")
        }
        return nil
    }
}
