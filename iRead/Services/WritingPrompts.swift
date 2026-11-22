import Foundation

/// 提示词集中在这里。
///
/// 为什么单独一个文件：这些文案直接决定生成质量，改一句就得能对比效果，
/// 散在三个 View 里没法维护。所有 prompt 都只依赖传进来的纯文本，不碰 UI 状态。
enum WritingPrompts {

    // MARK: - 系统提示

    private static let system = """
    你是一位中文网络小说作者。你的活儿是：在人物、设定、叙事人称都不跑偏的前提下，\
    把故事写得好看——有画面、有节奏、有钩子。

    硬性要求：
    1. 只输出小说正文。不要「好的」「以下是」「（约 2000 字）」这类元信息，\
    不要解释创作思路，不要写总结。
    2. 段落之间空一行；对话独立成段，用中文引号“”。
    3. 不复述、不重复已有内容，直接进入场景。
    4. 保持原作的人称（第一/第三人称）与时态，人物称呼不变。
    5. 不写露骨性描写，不写违法犯罪的具体操作细节。
    """

    // MARK: - 阅读页：改写本章

    static func rewrite(
        bookTitle: String,
        chapterTitle: String,
        chapterText: String,
        previousTail: String,
        instruction: String
    ) -> [AIMessage] {
        var user = """
        【原作】《\(bookTitle)》 · \(chapterTitle)

        """
        if !previousTail.isEmpty {
            user += """
            【上一章结尾（只用于衔接，不要重写它）】
            \(clip(previousTail, 700))

            """
        }
        user += """
        【本章原文】
        \(clip(chapterText, 14000))

        【任务】把上面这一章重写一遍。
        - 人物、身份、关系、已经发生的关键事件一个都不能改；不能删剧情节点，\
        也不能新增改变主线的转折。
        - 要改的是写法：叙述节奏、场景细节、对话质感、情绪铺陈、段落长短。
        - 篇幅和原文相当（上下浮动 20% 以内）。
        - 不要写章节标题，不要写「改写版」之类的字样，直接从正文第一句开始。

        【这次的要求】
        \(instruction.isEmpty ? "无，按你的判断发挥。" : instruction)
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 阅读页：换个走向

    static func redirect(
        bookTitle: String,
        chapterTitle: String,
        chapterText: String,
        instruction: String
    ) -> [AIMessage] {
        let user = """
        【原作】《\(bookTitle)》 · \(chapterTitle)

        【本章原文】
        \(clip(chapterText, 14000))

        【任务】重写这一章，但在剧情上分叉。
        - 先判断这一章的关键转折点（某个选择、某次碰面、某句话）。前半段可以按原文走，\
        文笔可以重写，事件顺序不变，保证读起来是同一本书。
        - 从那个转折点开始，让主角做出和原文不同的选择，然后把「不一样」写透：\
        后果、旁人的反应、主角自己的情绪。不要只是换几句台词。
        - 人物的动机必须站得住：他为什么这次会这么选，要给得出理由。
        - 结尾停在一个让人想翻下一章的钩子上。
        - 不要写章节标题，不要解释你改了哪里，只输出这一章正文。

        【这次的要求】
        \(instruction.isEmpty ? "无，按你的判断发挥。" : instruction)
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 阅读页：接着写

    static func continueChapter(
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        chapterText: String,
        instruction: String
    ) -> [AIMessage] {
        let nextNumber = chapterIndex + 2
        let user = """
        【原作】《\(bookTitle)》 · \(chapterTitle)

        【本章原文（结尾就是续写的起点）】
        \(clip(chapterText, 12000))

        【任务】从这一段结尾处接着写下一章，1800–2500 字。
        - 第一行写章节标题，格式「第\(nextNumber)章 标题」，标题自己起，不超过 16 字。
        - 标题后空一行，再写正文。
        - 人称、语气、人物称呼与上文一致；承接最后一句的场景和情绪，不要突然跳时间。
        - 结尾留钩子。

        【这次的要求】
        \(instruction.isEmpty ? "无，按你的判断发挥。" : instruction)
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 写作模块：第一章

    static func firstChapter(
        title: String,
        brief: String,
        taste: String,
        sourceTitle: String?,
        sourceOpening: String?
    ) -> [AIMessage] {
        var user = """
        【这本书】《\(title)》

        【方向】\(brief.isEmpty ? "没有特别指定，按读者口味来。" : brief)

        """
        if !taste.isEmpty {
            user += """
            【读者口味】这个读者书架上的书：\(taste)
            （只用来判断题材与调性，不要在正文里提到这些书名。）

            """
        }
        if let sourceTitle, let sourceOpening, !sourceOpening.isEmpty {
            user += """
            【底本】《\(sourceTitle)》的开篇（借用它的设定与语感，不许照抄句子）
            \(clip(sourceOpening, 5000))

            """
        }
        user += """
        【任务】写第一章，1800–2500 字。
        - 第一行写标题，格式「第一章 标题」，标题不超过 16 字；空一行，再写正文。
        - 开篇 200 字内必须入戏：给一个具体的场景，或一个不对劲的细节。\
        不要从天气、世界观介绍、人物履历写起。
        - 主角要有名字，有一个当下就得解决的问题。
        - 结尾留钩子。
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 写作模块：下一章

    static func nextChapter(
        project: WritingProject,
        recent: String
    ) -> [AIMessage] {
        let number = project.segments.count + 1
        var user = """
        【这本书】《\(project.title)》

        """
        if !project.brief.isEmpty {
            user += """
            【方向】\(project.brief)

            """
        }
        user += """
        【前文（最近的部分，结尾就是续写的起点）】
        \(clip(recent, 9000))

        【任务】接着写第\(number)章，1800–2500 字。
        - 第一行写标题，格式「第\(number)章 标题」，标题不超过 16 字；空一行，再写正文。
        - 沿用前文的人称与文风；不要重复上章已经交代过的信息。
        - 这一章要有一个小推进 + 一个小悬念，结尾留钩子。
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 写作模块：续写当前章

    static func extendSegment(
        project: WritingProject,
        segment: WritingSegment
    ) -> [AIMessage] {
        var user = """
        【这本书】《\(project.title)》 · \(segment.title)

        """
        if !project.brief.isEmpty {
            user += """
            【方向】\(project.brief)

            """
        }
        user += """
        【这一章已经写到这里】
        \(clip(segment.text, 9000))

        【任务】从上面最后一句接着往下写 800–1200 字，把这一章写完。
        - 不要写章节标题，不要另起一章，直接接着写正文。
        - 保持人称与语气；结尾收在一个小钩子上。
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 工具

    /// 超长文本保留头尾、掐掉中间：改写要看全貌，但成本也得有个上限
    private static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit * 2 / 3)
        let tail = trimmed.suffix(limit / 3)
        return "\(head)\n……（中间略）……\n\(tail)"
    }

    /// 把模型输出拆成「章节标题 + 正文」。
    ///
    /// 模型经常不听话：加粗、加 #、加「好的，以下是第一章」。这里只做最保守的处理 ——
    /// 认得出标题就拆出来，认不出就整段当正文，用调用方给的兜底标题。
    static func splitChapter(_ raw: String, fallbackTitle: String) -> (title: String, body: String) {
        var lines = raw.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first else { return (fallbackTitle, raw) }
        let cleaned = first
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        let looksLikeTitle = cleaned.count <= 40
            && (cleaned.hasPrefix("第") || cleaned.lowercased().hasPrefix("chapter"))
            && (cleaned.contains("章") || cleaned.lowercased().contains("chapter"))
            && !cleaned.hasSuffix("。") && !cleaned.hasSuffix("！") && !cleaned.hasSuffix("？")
        guard looksLikeTitle else {
            return (fallbackTitle, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.removeFirst()
        while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return (cleaned, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
