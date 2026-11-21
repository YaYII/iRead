#!/usr/bin/env python3
"""把「阅读 3.0」格式的书源转成 iRead 的 NovelSource 规则，并做可转换性统计。"""
import json, re, sys, hashlib
from urllib.parse import urljoin, quote

EXTRACT_TEXT = {"text", "textNodes", "ownText", "textnodes", "owntext"}
EXTRACT_HTML = {"html", "all"}
ATTRS = {"href", "src", "content", "value", "data-src", "data-original", "alt", "title", "data-id"}


class Skip(Exception):
    pass


def parse_css_step(step):
    """把 Legado 单个 CSS 步骤转成 iRead 的 op 串；失败返回 None。"""
    step = step.strip()
    if not step:
        return ""
    if step.startswith("-"):
        return None  # 倒序
    # 旧式前缀 class.xxx / id.xxx / tag.xxx
    if step.startswith("class."):
        step = "." + step[len("class."):]
    elif step.startswith("id."):
        step = "#" + step[len("id."):]
    elif step.startswith("tag."):
        step = step[len("tag."):]
    # 属性选择器：a[data-title] / [property="author"]
    attr_ops = []
    m_attr = re.search(r"\[([\w-]+)(?:\s*=\s*[\"\']?([^\"\']*)[\"\']?)?\]$", step)
    if m_attr:
        attr_name, attr_val = m_attr.group(1), m_attr.group(2)
        attr_ops.append(f"attrEq({attr_name},{attr_val})" if attr_val else f"hasAttr({attr_name})")
        step = step[:m_attr.start()]
    if any(ch in step for ch in ":[]()") and not re.fullmatch(r"[#.\w-]+", step):
        return None  # 伪类/其它属性选择器/括号

    # 末尾 !N 排除（去掉前 N+1 个）→ 用 skip 近似
    skip_n = None
    m_skip = re.search(r"!(\d+)$", step)
    if m_skip:
        skip_n = int(m_skip.group(1)) + 1
        step = step[:m_skip.start()]

    # 末尾 .N 索引
    index = None
    m = re.match(r"^(.*?)\.(\d+)$", step)
    if m and m.group(1):
        step, index = m.group(1), int(m.group(2))

    tokens = [t for t in re.split(r"[\s>+~]+", step) if t]
    if not tokens:
        return None
    ops = []
    for tok in tokens:
        if tok.startswith("#"):
            ops.append(f"id({tok[1:]})")
            continue
        if tok.startswith("."):
            classes = [c for c in tok.split(".") if c]
            if not classes:
                return None
            for c in classes:
                ops.append(f"class({c})")
            continue
        # tag.class / tag#id
        tag = re.split(r"[.#]", tok)[0]
        if not re.fullmatch(r"[a-zA-Z][\w-]*", tag):
            return None
        ops.append(f"tag({tag})")
        for part in re.findall(r"\.([\w-]+)", tok):
            ops.append(f"class({part})")
        idm = re.search(r"#([\w-]+)", tok)
        if idm:
            ops.append(f"id({idm.group(1)})")
    if skip_n:
        ops.append(f"skip({skip_n})")
    if index is not None:
        ops.append(f"nth({index})")
    ops.extend(attr_ops)
    return ".".join(ops)


def convert_rule(raw, want="text"):
    """raw 形如 `.book-list@li@a@href##正则##替换`，返回 iRead 选择器串；不支持返回 None。"""
    if not isinstance(raw, str):
        return None
    rule = raw.strip()
    if not rule:
        return None
    if "<js>" in rule or "@js:" in rule:
        return None
    if rule.startswith("@css:"):
        rule = rule[len("@css:"):].strip()
    if "||" in rule:
        rule = rule.split("||")[0].strip()
    if "&&" in rule:
        return None
    if "{{" in rule:
        return None  # 字段里带模板变量
    # 正则后处理
    pattern = repl = None
    if "##" in rule:
        parts = rule.split("##")
        rule = parts[0]
        if len(parts) > 1 and parts[1].strip():
            pattern = parts[1]
        if len(parts) > 2:
            repl = parts[2]
        else:
            repl = ""
        # 我们的 replace() 参数按逗号切分，正则里有逗号会解析错
        if pattern and ("," in pattern or not balanced(pattern)):
            pattern = repl = None
    rule = rule.strip()
    if not rule:
        return None

    # 抽出 @ 分隔的提取器
    steps = [s for s in rule.split("@") if s.strip() != ""]
    extractor = None
    if steps:
        last = steps[-1].strip()
        low = last.lower()
        if low in EXTRACT_TEXT:
            extractor = "text"
            steps.pop()
        elif low in EXTRACT_HTML:
            extractor = "html"
            steps.pop()
        elif low in ATTRS or re.fullmatch(r"[a-zA-Z][\w:-]*", last) and not re.search(r"[#.]", last):
            # 纯单词当属性名（Legado 里 href / src / content 常见）
            extractor = "attr:" + last
            steps.pop()
    if not steps:
        # 纯提取器：直接作用在当前项上（Legado 里 text / href 很常见）
        if extractor == "text":
            return "text"
        if extractor and extractor.startswith("attr:"):
            return f"attr({extractor[5:]})"
        return None
    css = []
    for step in steps:
        converted = parse_css_step(step)
        if converted is None:
            return None
        css.append(converted)
    sel = ".".join([c for c in css if c])
    if not sel:
        return None
    if extractor == "text":
        sel += ".text"
    elif extractor and extractor.startswith("attr:"):
        sel += f".attr({extractor[5:]})"
    # 没有提取器时保留 HTML（正文场景由 cleanSegments 再转文本）

    if pattern:
        sel += f".replace({pattern},{repl})"
    return sel


def balanced(p):
    depth = 0
    for ch in p:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def clean_name(s):
    s = re.sub(r"^[^\w\u4e00-\u9fa5#]+", "", s or "")
    return s.strip() or "未命名"


def convert_source(s):
    if not s.get("enabled"):
        raise Skip("已禁用")
    if s.get("bookSourceType") != 0:
        raise Skip("非文本")
    url = (s.get("searchUrl") or "").strip()
    if not url:
        raise Skip("无搜索地址")
    # 去掉 {{cookie.removeCookie(...)}} 这类前置指令
    url = re.sub(r"\{\{cookie\.removeCookie\([^)]*\)\}\}\s*", "", url)
    url = re.sub(r"\{\{cookie\.[^}]*\}\}\s*", "", url)
    if url.startswith("@js") or "<js>" in url:
        raise Skip("JS 搜索")

    # 搜索配置（POST / charset / headers）与 URL 分开
    method, body, body_charset, extra_headers = "GET", None, None, None
    if ",{" in url:
        idx = url.index(",{")
        cfg_text = url[idx + 1:]
        url = url[:idx].strip()
        try:
            cfg = json.loads(cfg_text)
        except Exception:
            raise Skip("搜索配置解析失败")
        method = str(cfg.get("method", "GET")).upper()
        body = cfg.get("body")
        body_charset = cfg.get("charset")
        extra_headers = cfg.get("headers")
        if method not in ("GET", "POST"):
            raise Skip("不支持的请求方法")
    if url.startswith("POST:"):
        method, url = "POST", url[len("POST:"):].strip()
    if "{{" in url:
        url = url.replace("{{baseUrl}}", "{host}").replace("{{key}}", "{key}")
        url = url.replace("{{page-1}}", "0").replace("{{page}}", "{page}")
        if "{{" in url:
            raise Skip("搜索 URL 含其它模板变量")
    if body is not None:
        body = str(body).replace("{{key}}", "{key}").replace("{{page}}", "{page}")
        body = body.replace("{{baseUrl}}", "{host}").replace("{{page-1}}", "0")
        if "{{" in body:
            raise Skip("POST body 含其它模板变量")

    search, toc, content = s.get("ruleSearch") or {}, s.get("ruleToc") or {}, s.get("ruleContent") or {}
    if not isinstance(search, dict) or not isinstance(toc, dict) or not isinstance(content, dict):
        raise Skip("规则不是对象")

    book_list = convert_rule(search.get("bookList"), "list")
    name = convert_rule(search.get("name"))
    book_url = convert_rule(search.get("bookUrl"))
    if not book_list or not name or not book_url:
        raise Skip("搜索规则不完整")
    fields = {"title": name, "url": book_url}
    for src_key, dst in (("author", "author"), ("coverUrl", "cover"), ("intro", "intro")):
        v = convert_rule(search.get(src_key))
        if v:
            fields[dst] = v

    chapter_list = convert_rule(toc.get("chapterList"), "list")
    if not chapter_list:
        raise Skip("目录规则不支持")
    ch_fields = {}
    cn = convert_rule(toc.get("chapterName"))
    cu = convert_rule(toc.get("chapterUrl"))
    if cn:
        ch_fields["title"] = cn
    if cu:
        ch_fields["url"] = cu

    content_sel = convert_rule(content.get("content"))
    if not content_sel:
        raise Skip("正文规则不支持")

    host = (s.get("bookSourceUrl") or "").strip()
    if not host.startswith("http"):
        raise Skip("站点地址异常")
    # 相对搜索地址补成绝对地址（App 端不做相对解析）
    if not url.startswith("http"):
        url = urljoin(host.rstrip("/") + "/", url.lstrip("/"))
    sid = "legado-" + hashlib.md5((host + "|" + s.get("bookSourceName", "")).encode()).hexdigest()[:10]
    headers = {}
    raw_header = s.get("header") or ""
    for line in str(raw_header).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip()] = v.strip()

    search_rule = {"url": url, "list": book_list, "fields": fields}
    if method == "POST":
        search_rule["method"] = "POST"
        search_rule["body"] = body or "{key}"
        if body_charset:
            search_rule["bodyCharset"] = body_charset
    if extra_headers:
        search_rule["headers"] = extra_headers

    out = {
        "schemaVersion": 1,
        "id": sid,
        "name": clean_name(s.get("bookSourceName", "")),
        "host": host,
        "type": "html",
        "enabled": False,
        "isBuiltin": False,
        "note": f"由「阅读」书源转换：{s.get('bookSourceName','')} · {s.get('bookSourceGroup','')}".strip(" ·"),
        "search": search_rule,
        "chapter": {"list": chapter_list, "fields": ch_fields},
        "content": {"list": content_sel},
    }
    if headers:
        out["headers"] = headers
    return out


if __name__ == "__main__":
    """
    用法：
      python3 convert.py <shareBookSource.json> [输出.json]
    输出可直接在 App 的书源管理里粘贴导入，也可作为内置源资源。
    转换只覆盖「纯选择器」能表达的部分；带 JS/CSS 选择器/XPath 的源会被跳过并计入统计。
    """
    if len(sys.argv) < 2:
        print("用法: python3 convert.py <shareBookSource.json> [输出.json]")
        sys.exit(0)
    src = json.load(open(sys.argv[1]))
    out_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/iread-legado.json"
    ok, skip = [], {}
    for s in src:
        try:
            ok.append(convert_source(s))
        except Skip as e:
            skip[str(e)] = skip.get(str(e), 0) + 1
        except Exception as e:
            skip["异常:" + type(e).__name__] = skip.get("异常:" + type(e).__name__, 0) + 1
    print("可转换", len(ok), "/", len(src))
    for k, v in sorted(skip.items(), key=lambda x: -x[1]):
        print(f"  跳过 {v:4d}  {k}")
    # 按 host 去重：同一站的多个镜像/重复条目只留第一条
    seen, uniq = set(), []
    for o in ok:
        key = re.sub(r"^https?://(www\.)?", "", o["host"]).strip("/").lower()
        if key in seen:
            continue
        seen.add(key)
        uniq.append(o)
    print("按站点去重后", len(uniq), "->", out_path)
    json.dump(uniq, open(out_path, "w"), ensure_ascii=False, indent=1)
