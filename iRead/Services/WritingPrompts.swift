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
    3. 不复述、不重复已有内容，直接进入场景。上一章结尾在哪儿、干了什么，\
    这一章就换地方或换冲突，别把同一场戏再演一遍。
    4. 保持原作的人称（第一/第三人称）与时态，人物称呼不变。
    5. 不写露骨性描写，不写违法犯罪的具体操作细节。
    6. 人物只用大纲与前文里出现过的人。需要跑龙套时，一句话带过、不给姓名。
    7. 不要自己发明具体数字：门牌号、楼层、房间号、几点几分、几天几号、金额。\
    大纲或前文写了的照抄，没写的就模糊处理（「楼上」「傍晚」「一笔不小的钱」）。\
    这类细节一旦编错，后面几十章都会跟着错。
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

    /// 续写上下文。结构体而不是一长串参数：字段还会加，调用点不想每加一个就改一遍。
    struct Context {
        /// 故事大纲 / 设定集
        var outline: String = ""
        /// 已完成章节的「标题 + 一句话摘要」，一行一条。长篇靠它维持记忆
        var recaps: String = ""
        /// 场记：已经发生的事实，按类分行。比摘要细、比正文省
        var log: String = ""
        /// 最近一两章的正文（已截断）
        var recent: String = ""
        /// 这一章要完成什么
        var goal: String?
        /// 底本开篇。只有第一章需要，用来借语感和设定
        var sourceOpening: String?
        /// 上一版没过审的原因，重写时带上
        var feedback: [String] = []
    }

    static func nextChapter(project: WritingProject, context: Context) -> [AIMessage] {
        let number = project.segments.count + 1
        var user = """
        【这本书】《\(project.title)》

        """
        if !project.brief.isEmpty {
            user += """
            【方向】\(project.brief)

            """
        }
        if !context.outline.isEmpty {
            user += """
            【大纲与设定（必须遵守：人物名、身份、关系、世界规则都不能改）】
            \(clip(context.outline, 4000))

            """
        }
        if let sourceOpening = context.sourceOpening, !sourceOpening.isEmpty, number == 1 {
            user += """
            【底本开篇（借用它的设定与语感，不许照抄句子）】
            \(clip(sourceOpening, 4000))

            """
        }
        if !context.recaps.isEmpty {
            user += """
            【前情（已完成章节的摘要，按顺序）】
            \(context.recaps)

            """
        }
        if !context.log.isEmpty {
            user += """
            【场记（已经发生的事实，前后必须对得上；这里没写的事不要自己发明）】
            \(context.log)

            """
        }
        if !context.recent.isEmpty {
            user += """
            【最近正文（语气与场景从这里接，结尾就是起点）】
            \(clip(context.recent, 6000))

            """
        }
        user += """
        【任务】接着写第\(number)章，2200–3000 字。
        - 第一行写标题，格式「第\(number)章 标题」，标题不超过 16 字；空一行，再写正文。
        - 沿用前文的人称与文风；不要重复上章已经交代过的信息，不要写「如前所述」。
        - 这一章要有一个明确推进 + 一个小悬念，结尾留钩子。
        """
        if let goal = context.goal, !goal.isEmpty {
            user += """

            【本章目标（必须完成，但不能靠人物直接说出来）】
            \(goal)
            """
        }
        if !context.feedback.isEmpty {
            user += """

            【上一版没过审的原因，这一版必须改掉】
            \(context.feedback.map { "- \($0)" }.joined(separator: "\n"))

            【怎么改】只动出问题的地方，其余段落尽量逐字保留。
            不要整体重写 —— 整体重写会带进新的细节，又和前面几十章冲突。
            """
        }
        return [.system(system), .user(user)]
    }

    // MARK: - 长篇：起草大纲

    /// 大纲任务的系统提示。
    ///
    /// 不能复用正文那个 `system`：那边要求「只输出小说正文」，模型会顺手写起
    /// 场景和对白；大纲要的是策划案。用户自己写过大纲时尤其明显 ——
    /// 它会把用户的三行设定扩写成一段小说，然后当成「大纲」还给用户。
    private static let outlineSystem = """
    你是一位中文网络小说策划编辑。你的活儿是把故事骨架搭稳：主线清楚、人物有算盘、\
    伏笔埋得住也收得回。

    硬性要求：
    1. 只输出大纲本身，按要求的几段写。不要「好的」「以下是」，不要解释你改了什么，\
    不要写正文片段、不要写对白。
    2. 用短句。不要 Markdown 符号（#、*、> 之类），除了段落编号不要别的格式。\
    标点一律用中文全角（，。；：），不要出现半角逗号句号。
    3. 人物：用户已经写了人物的，只用他写到的，跑龙套一句话带过、不给姓名；\
    从零起草时，有名有姓的角色控制在 4–6 个，别铺一堆没戏的配角。
    4. **类型要对味**。这是给网文读者看的，不是文学奖参评稿：书架上是玄幻就写玄幻的\
    升级、夺宝、越阶、扬名，是悬疑就写线索和反转。读者要爽点，不要替他"拔高"，\
    也别把爽文写成闷文。
    5. 不写露骨性描写，不写违法犯罪的具体操作细节。这条是底线，不要写进大纲内容里。
    """

    /// 用户可能只有一个方向，没有大纲。先让模型起一份草稿，用户再改 ——
    /// 大纲是长篇唯一能压住「越写越飘」的东西，值得单独一步。
    ///
    /// `existing` 非空时语义完全不同：那是**用户自己写的骨架**，模型只许补、
    /// 不许换。以前这里只写了一句「不要推翻重写」，模型照样另起一套 ——
    /// 用户写了三行自己的设定，回来发现被换成了另一个故事，等于白写。
    static func outlineDraft(
        title: String,
        brief: String,
        taste: String,
        sourceTitle: String?,
        sourceOpening: String?,
        existing: String
    ) -> [AIMessage] {
        var user = """
        【这本书】《\(title)》
        【方向】\(brief.isEmpty ? "没有特别指定，按读者口味来。" : brief)

        """
        if !taste.isEmpty {
            user += """
            【读者口味（这些是他真正在看的书，写出来要像同一类）】
            \(taste)

            先判断这几本是什么题材、什么路子 —— 东方玄幻 / 修仙升级 / 都市异能 / 重生复仇 /\
            系统流 / 权谋群像 / 甜宠日常 —— 然后照着这个口味写：同样的题材、同样的爽点来源、\
            同样的节奏。他书架里全是玄幻，就写玄幻；别把玄幻写成悬疑，也别自作主张「拔高立意」。
            不要照搬这些书的具体情节，也不要在输出里提书名。

            """
        }
        if let sourceTitle, let sourceOpening, !sourceOpening.isEmpty {
            user += """
            【底本】《\(sourceTitle)》的开篇（借用设定与语感，不许照抄）
            \(clip(sourceOpening, 3000))

            """
        }
        if !existing.isEmpty {
            user += """
            【用户已经写的大纲（这是骨架，不是参考素材）】
            \(clip(existing, 3000))

            """
        }
        if existing.isEmpty {
            user += """
            【任务】写一份能支撑上百章的故事大纲，1000 字以内，按下面这几段写，用短句，不要用 Markdown 符号：
            """
        } else {
            user += """
            【任务】用户已经写了上面那份。把它补成一份能支撑上百章的故事大纲，1000 字以内，用短句，不要用 Markdown 符号。

            怎么补（这一段最重要，逐条照做）：
            - 骨架不许动：人名、身份、关系、地点、已经定下的事件顺序、世界规则，一律照用。\
            不许改名、换人、合并角色，也不许把故事改成另一个方向。
            - 先保原文：用户写到的句子尽量照抄，只顺语病、压重复。不要换个说法重写 ——\
            他把某句写下来，就是那句他认。
            - 只补缺的：他写了一两句的段，按下面七段的结构补齐；已经很细的段不要膨胀。
            - 不加冲突设定：不许新增和草稿打架的规则或人物；确实需要配角时一句话带过，不给新名字。
            - 输出完整的一份（用户要能直接拿去用），仍按下面这七段排：
            """
        }
        user += """
        1. 一句话故事：谁，想要什么，被什么挡住。
        2. 主角：名字、身份、起点（眼下的处境和实力）、最在意的东西、致命弱点。
        3. 主要人物：3–6 个，每人一句，写清与主角的关系和各自的算盘。主角已经在第 2 段写过，这里不要再列一遍。
        4. 世界与规则：读者必须提前知道的设定，只写会用到的那几条。
        5. 主线：分三到四个阶段，每阶段写「目标 → 阻碍 → 代价 → 阶段结果」。
        6. 埋线：三到五条要长期埋、最后要回收的伏笔。
        7. 禁忌：只写用户明确说过不写的。他没说就写「未限定」，不要自己编。
        """
        // 类型不同，大纲的骨架也不一样：玄幻要看境界和爽点，悬疑要看线索和真相，
        // 用同一套模板会让玄幻大纲读起来像都市小说。
        if let genre = genreHint(brief: brief, taste: taste, existing: existing) {
            user += """

            【这是\(genre)】另外两条必须写清：
            - 第 4 段要有力量体系：境界分几层、往上走靠什么（功法、丹药、血脉、资源、师门），谁占着上层。
            - 第 5 段每个阶段都要写主角的实力跃迁（从哪一层到哪一层），以及这一阶段的爽点是什么\
            （打脸、夺宝、越阶、扬名、护人），别只有「查清真相」这种悬疑式目标。
            """
        }
        return [.system(outlineSystem), .user(user)]
    }

    /// 从方向 / 已有草稿 / 书架里认出这是不是玄幻类的书。
    ///
    /// 只用来决定要不要加「力量体系 + 实力跃迁」那两条：判断错了，模型会给都市小说
    /// 硬塞一套境界，比不加还糟。所以优先级是**用户写的方向 > 用户写的大纲 > 书架**：
    /// 他明确说了「都市悬疑」，哪怕书架里全是修仙，也不加玄幻那两条。
    private static func genreHint(brief: String, taste: String, existing: String) -> String? {
        let fantasy = ["玄幻", "修仙", "仙侠", "修真", "洪荒", "异界", "斗气", "灵气", "宗门", "境界", "丹药", "飞升", "妖兽", "元婴", "金丹"]
        let modern = ["都市", "悬疑", "职场", "校园", "甜宠", "历史", "权谋", "言情", "现实", "刑侦", "商战"]

        let own = brief + " " + existing
        if fantasy.contains(where: { own.contains($0) }) { return "玄幻 / 修仙" }
        if modern.contains(where: { own.contains($0) }) { return nil }
        // 自己什么都没说，才看书架
        if fantasy.contains(where: { taste.contains($0) }) { return "玄幻 / 修仙" }
        return nil
    }

    // MARK: - 长篇：排章

    /// 一次排 N 章的一句话章纲。比逐章现想便宜得多，也让用户能提前看出走向对不对。
    static func plan(project: WritingProject, from number: Int, count: Int) -> [AIMessage] {
        var user = """
        【这本书】《\(project.title)》

        """
        if !project.brief.isEmpty {
            user += """
            【方向】\(project.brief)

            """
        }
        if !project.outlineText.isEmpty {
            user += """
            【大纲与设定】
            \(clip(project.outlineText, 4000))

            """
        }
        if !project.segments.isEmpty {
            user += """
            【已经写到第 \(project.segments.count) 章】
            \(recapLines(project))

            """
        }
        user += """
        【任务】为接下来的 \(count) 章各写一句章纲，从第\(number)章开始。

        要求：
        - 每章一行，格式「第X章：一句话」，30 字以内。
        - 要具体到事件（谁做了什么、结果如何），不要写「继续推进剧情」「矛盾升级」这种空话。
        - 这 \(count) 章要构成一个完整的小段落：有起势、有推进、有阶段性收束，并在最后留下新钩子。
        - 别让同一场戏演两遍：已经写过的地点、线索、动作（比如又去一趟同一个地方、又翻同一页），\
        这一批就换个场景或换个冲突去推进。
        - 只输出这 \(count) 行，不要解释，不要写正文。

        示例：
        第\(number)章：主角在旧书店发现一封没有邮戳的信
        """
        return [.system(system), .user(user)]
    }

    // MARK: - 长篇：审查

    private static let reviewSystem = """
    你是一位严格的中文小说审稿编辑。你的活儿是拦住硬伤，不是评价文笔。

    只输出一个 JSON 对象，不要 Markdown 代码块，不要任何解释文字。格式：
    {"pass": true 或 false, "issues": ["问题1", "问题2"], "recap": "本章摘要"}

    判定规则：
    - 出现下列任何一种，pass 必须是 false，并把问题写进 issues：
      a) 与【大纲】的人物名、身份、关系、世界规则冲突；
      b) 时间线倒错，或已经死掉/离开的人又正常出现；
      c) 与【最近正文】的情节明显重复，或把上一章已经发生的事又写了一遍；
      d) 正文里有元信息（「以下是」「本章完」「约 2000 字」）、提纲式流水账、作者旁白；
      e) 整章没有完成【本章目标】里要求的事。
    - **篇幅不归你管**：字数由程序统计，写在【本章统计】里。不要自己数、不要估算字数，
      也不要因为「读起来觉得短」判 false —— 篇幅合不合规由程序负责。
    - 文笔偏好（够不够美、节奏快慢）不算硬伤，不要因此判 false。
    - issues 最多 3 条，每条一句话，必须指出具体的人名/事件，不要写「建议加强冲突」这类空话。
    - 没有问题就返回空数组。
    - recap 用 40 字以内陈述事实：谁做了什么、结果如何、留下什么钩子。不要评价，不要剧透后面。
    """

    static func review(
        project: WritingProject,
        chapterTitle: String,
        chapterText: String,
        wordCount: Int,
        goal: String?,
        recent: String
    ) -> [AIMessage] {
        var user = """
        【书名】《\(project.title)》

        """
        // 统计值由程序算好喂进来，模型只负责内容判断。
        // 以前不给这个数字，模型会自己估（「这一章只有八百字」），估错了就白改一轮。
        user += """
        【本章统计（程序计算，以此为准）】
        \(chapterTitle)：\(wordCount) 字（不含空白、含标点）

        """
        if !project.outlineText.isEmpty {
            user += """
            【大纲与设定】
            \(clip(project.outlineText, 4000))

            """
        }
        user += """
        【前情摘要】
        \(recapLines(project))

        """
        let logDigest = logLines(project)
        if !logDigest.isEmpty {
            // 审查判的是「和前面有没有冲突」，场记正是冲突的判据：
            // 上一章还炼气三层，这一章突然金丹，得指出来
            user += """
            【场记（已发生的事实，用于查前后矛盾）】
            \(logDigest)

            """
        }
        if !recent.isEmpty {
            user += """
            【最近正文（用于判断是否重复）】
            \(clip(recent, 3000))

            """
        }
        if let goal, !goal.isEmpty {
            user += """
            【本章目标】
            \(goal)

            """
        }
        user += """
        【待审章节】\(chapterTitle)
        \(clip(chapterText, 8000))
        """
        return [.system(reviewSystem), .user(user)]
    }

    /// 审查结果
    struct Verdict {
        var pass: Bool
        var issues: [String]
        var recap: String
    }

    /// 解析审查输出。
    ///
    /// 模型经常把 JSON 包在 ```json 里，或者在前面加一句「好的」。所以先截取第一个 `{`
    /// 到最后一个 `}`，再解析；还是失败就**按通过处理**并留一条警告 ——
    /// 审查是辅助，不该因为格式问题把一章好稿反复重写、白烧额度。
    static func parseVerdict(_ raw: String) -> (verdict: Verdict, warning: String?) {
        let start = raw.firstIndex(of: "{")
        let end = raw.lastIndex(of: "}")
        guard let start, let end, start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (Verdict(pass: true, issues: [], recap: ""), "审查没给出可解析的结论，按通过处理")
        }
        let pass = object["pass"] as? Bool ?? true
        let issues = (object["issues"] as? [String]) ?? []
        let recap = (object["recap"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (Verdict(pass: pass, issues: issues, recap: recap), nil)
    }

    /// 已完结章节的「序号 + 标题 + 摘要」，一行一条。没有摘要的老稿子退回用标题。
    static func recapLines(_ project: WritingProject, limit: Int = 160) -> String {
        let segments = project.segments
        guard !segments.isEmpty else { return "（还没有）" }
        // 超过 limit 章时保留最近的部分：更早的靠大纲承担，全塞进去只会撑爆上下文
        let picked = segments.count > limit ? Array(segments.suffix(limit)) : segments
        let offset = segments.count - picked.count
        var lines: [String] = []
        if offset > 0 {
            lines.append("（更早的 \(offset) 章略，按大纲把握即可）")
        }
        for (i, segment) in picked.enumerated() {
            let number = offset + i + 1
            let recap = (segment.recap ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if recap.isEmpty {
                lines.append("第\(number)章 \(segment.title)")
            } else {
                lines.append("第\(number)章 \(segment.title)：\(recap)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 场记摘要：喂给模型的那一段。
    ///
    /// 顺序是刻意排的 —— 先摆没回收的伏笔（最容易被忘、后果最大），再摆最近的事实。
    /// 超出字数上限时砍**最近事实的尾部以外**的部分，不砍伏笔：
    /// 「他此刻是什么境界」可以靠最近的正文补，埋了三十章没交代的坑补不回来。
    static func logLines(_ project: WritingProject, limit: Int = 60, budget: Int = 1400) -> String {
        let entries = project.logEntries
        guard !entries.isEmpty else { return "" }

        var sections: [String] = []

        let threads = entries
            .filter { $0.kind == .thread && !$0.resolved }
            .suffix(8)
        if !threads.isEmpty {
            sections.append("未回收的伏笔：\n" + threads
                .map { "\($0.chapterLabel)｜\($0.summary)" }
                .joined(separator: "\n"))
        }

        // 伏笔已经单独在上面列过，这里不重复；其余按时间顺序，保留最近的
        let rest = entries.filter { !($0.kind == .thread && !$0.resolved) }
        let picked = rest.count > limit ? Array(rest.suffix(limit)) : rest
        if !picked.isEmpty {
            var body = picked
                .map { "\($0.kind.title)｜\($0.chapterLabel)｜\($0.subject)：\($0.summary)" }
                .joined(separator: "\n")
            if body.count > budget {
                body = "（更早的略）\n" + String(body.suffix(budget))
            }
            sections.append("最近的事实：\n" + body)
        }
        return sections.joined(separator: "\n")
    }

    // MARK: - 场记：从一章里抽事实

    /// 场记的抽取提示。
    ///
    /// 这一段不写作文要求，只写「记什么、不记什么」：模型天然会总结剧情，
    /// 而场记要的是**状态**（他现在几层、伤了哪、答应过谁），两者不是一回事。
    private static let logSystem = """
    你是长篇小说的场记。你只做一件事：读完一章，把「以后写下去必须记住的事实」记下来。
    只输出 JSON，不要解释，不要在 JSON 之外写任何字。
    """

    static func extractLog(
        project: WritingProject,
        chapterIndex: Int,
        segment: WritingSegment,
        known: String
    ) -> [AIMessage] {
        let number = chapterIndex + 1
        var user = """
        【书名】《\(project.title)》 · \(segment.title)

        """
        if !project.outlineText.isEmpty {
            user += """
            【大纲与设定（人物名以此为准）】
            \(clip(project.outlineText, 2500))

            """
        }
        if !known.isEmpty {
            user += """
            【已有场记（已经记过的不要重复记，除非这一章里状态变了）】
            \(clip(known, 2500))

            """
        }
        user += """
        【这一章正文】
        \(clip(segment.text, 9000))

        【记什么】
        1. character：人物的状态变了 —— 境界/等级、位置、伤势、身份、持有关系、对某人的态度。没变就不记。
        2. event：改变了局势、后面必须承接的事。一章 1–2 条，不要复述整章剧情。
        3. thread：这一章新埋的线索、许诺、威胁 —— 还没揭晓的那种。没有就不记。
        4. item：拿到、失去、损坏、易手的关键物件或资源。
        5. world：这一章首次讲清的规则（境界怎么分、钱怎么算、谁管着谁）。
        不记文笔、不记评价、不记读者感受、不预测后面。

        【subject】用书里的原名，不要写「主角」「他」。
        【summary】一句话，40 字以内，只写事实。例：「从炼气二层突破到三层，右臂经脉受伤」。

        【回收】如果这一章揭晓了上面「已有场记」里某条未回收的伏笔，把那条 summary 的前 12 个字原样放进 resolved 数组；没有就留空数组。

        【输出】只输出这个 JSON，不要 Markdown 代码块：
        {"entries":[{"kind":"character","subject":"萧炎","summary":"从炼气二层突破到三层，右臂经脉受伤"}],"resolved":[]}
        """
        return [.system(logSystem), .user(user)]
    }

    /// 一条还没落成 `StoryLogEntry` 的场记（章信息由调用方补）
    struct LogDraft {
        var kind: StoryLogKind
        var subject: String
        var summary: String
    }

    /// 解析场记输出。和 `parseVerdict` 一样容忍 ```json 围栏和前后废话；
    /// 解析不出来返回空数组 + 一句提醒，由调用方退回用章节摘要兜底。
    static func parseLog(_ raw: String) -> (drafts: [LogDraft], resolved: [String], warning: String?) {
        func drafts(from array: [[String: Any]]) -> [LogDraft] {
            array.compactMap { item in
                let subject = (item["subject"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = (item["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !subject.isEmpty, !summary.isEmpty else { return nil }
                let kind = StoryLogKind(rawValue: item["kind"] as? String ?? "") ?? .event
                return LogDraft(kind: kind,
                                subject: String(subject.prefix(20)),
                                summary: String(summary.prefix(80)))
            }
        }

        if let start = raw.firstIndex(of: "{"),
           let end = raw.lastIndex(of: "}"),
           start < end,
           let data = String(raw[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let drafts = drafts(from: object["entries"] as? [[String: Any]] ?? [])
            let resolved = (object["resolved"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return (drafts, resolved, drafts.isEmpty ? "这一章没抽出场记" : nil)
        }

        // 有些模型会直接给一个数组，也认
        if let start = raw.firstIndex(of: "["),
           let end = raw.lastIndex(of: "]"),
           start < end,
           let data = String(raw[start...end]).data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let drafts = drafts(from: array)
            return (drafts, [], drafts.isEmpty ? "这一章没抽出场记" : nil)
        }
        return ([], [], "场记没给出可解析的内容")
    }

    // MARK: - 写作模块：重写某一章

    /// 单章重写：不建议它改剧情，因为后面几十章都建立在「这一章发生过什么」上。
    ///
    /// 带 `comment` 时是「按读者的修改意见改」：这时它不是重写，是**改稿** ——
    /// 意见点到哪儿改哪儿，没点到的逐句保留。两者用同一段代码是因为上下文一样，
    /// 差别只在最后那段任务说明。
    static func rewriteChapterAt(
        project: WritingProject,
        index: Int,
        segment: WritingSegment,
        previousTail: String,
        context: Context,
        comment: String? = nil
    ) -> [AIMessage] {
        let number = index + 1
        var user = """
        【这本书】《\(project.title)》 · 第\(number)章

        """
        if !project.outlineText.isEmpty {
            user += """
            【大纲与设定】
            \(clip(project.outlineText, 4000))

            """
        }
        if !context.recaps.isEmpty {
            user += """
            【前情摘要】
            \(context.recaps)

            """
        }
        if !context.log.isEmpty {
            user += """
            【场记（这一章里的事实不能和它冲突）】
            \(context.log)

            """
        }
        if !previousTail.isEmpty {
            user += """
            【上一章结尾（只用于衔接，不要重写它）】
            \(clip(previousTail, 1500))

            """
        }
        user += """
        【现在的版本】
        \(clip(segment.text, 12000))

        """

        let note = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            // 有意见 = 改稿，不是重写。这一段决定了「手术刀」还是「推倒重来」：
            // 不写死「没点到的地方别动」，模型会顺手把整章换一种写法，
            // 用户逐章写下的判断就白做了。
            user += """
            【读者的修改意见（最高优先级，逐条落实）】
            \(clip(note, 3000))

            【怎么改】
            - 意见点到的地方必须改到位；**没点到的部分逐句保留**，不要顺手润色、改词、加描写。
            - 除意见明确要求，否则不改已发生的事件、人物关系、时间地点和本章结局 —— 后面的章节都建立在这些事实上。
            - 意见若要求删掉某段，把前后的衔接句补顺，别留下断口。
            - 如果意见和上一章/下一章对不上，以「不改事实」为先，把冲突在文字里带过，不要自己发明新设定。

            【输出】
            改完的**整章**（不是 diff、不是片段）：第一行写标题，格式「第\(number)章 标题」；空一行再写正文。
            篇幅和原章接近（原章 \(segment.wordCount) 字，±15% 以内）。
            """
        } else {
            user += """
            【任务】把这一章重写一遍，2200–3000 字。
            - 已发生的关键事件、人物关系、时间地点一个都不能改 —— 后面的章节都建立在这些事实上。\
            要改的是叙述顺序、场景细节、对话质感、情绪铺陈。
            - 保持与上一章结尾的衔接，第一句直接进场景。
            - 第一行写标题，格式「第\(number)章 标题」；空一行再写正文。
            """
        }
        if let goal = segment.goal, !goal.isEmpty {
            user += """

            【本章目标（重写后仍要完成）】
            \(goal)
            """
        }
        if let issues = segment.issues, !issues.isEmpty {
            user += """

            【上一版的问题，这一版必须避免】
            \(issues.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
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
