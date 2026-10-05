"""Rich Messages (TDLib messageRichMessage) to a plain-text fallback and a small, safe Qt Rich Text subset.

A rich message is a list of PageBlocks whose text is a RichText tree. The bubble draws the HTML; previews,
notifications, copy and search keep using the plain text. Everything from the network is escaped here, and only
tags Qt's Rich Text understands are emitted. Links keep only http(s), tg and mailto targets.
"""
import html

MAX_DEPTH = 12          # nested RichText / blocks deeper than this are flattened to their plain text
MAX_HTML = 96_000       # past this the bubble falls back to plain text
LINK_SCHEMES = ("http://", "https://", "tg://", "mailto:")


def _obj(v):
    return v if isinstance(v, dict) else {}


def _list(v):
    return v if isinstance(v, list) else []


def _esc(s):
    return html.escape(s if isinstance(s, str) else "", quote=True)


def _href(url):
    url = url if isinstance(url, str) else ""
    return _esc(url) if url.lower().startswith(LINK_SCHEMES) else ""


# ------------------------------------------------------------------ RichText
WRAP = {
    "richTextBold": ("<b>", "</b>"), "richTextItalic": ("<i>", "</i>"), "richTextUnderline": ("<u>", "</u>"),
    "richTextStrikethrough": ("<s>", "</s>"), "richTextSubscript": ("<sub>", "</sub>"),
    "richTextSuperscript": ("<sup>", "</sup>"), "richTextFixed": ("<code>", "</code>"),
    "richTextMarked": ('<span style="background-color:#7f7f3f">', "</span>"),
    "richTextSpoiler": ('<span style="background-color:#555555">', "</span>"),
}


def text_plain(rt, depth=0):
    rt = _obj(rt)
    t = rt.get("@type")
    if depth > MAX_DEPTH:
        return ""
    if t == "richTextPlain":
        return rt.get("text") if isinstance(rt.get("text"), str) else ""
    if t == "richTexts":
        return "".join(text_plain(x, depth + 1) for x in _list(rt.get("texts")))
    if t == "richTextCustomEmoji":
        return rt.get("alternative_text") if isinstance(rt.get("alternative_text"), str) else ""
    if t == "richTextMathematicalExpression":
        return rt.get("expression") if isinstance(rt.get("expression"), str) else ""
    if t == "richTextButton":
        return _obj(rt.get("button")).get("text") or ""
    if t in ("richTextIcon", "richTextAnchor"):
        return ""
    return text_plain(rt.get("text"), depth + 1)


def text_html(rt, depth=0):
    rt = _obj(rt)
    t = rt.get("@type")
    if depth > MAX_DEPTH:
        return _esc(text_plain(rt))
    if t == "richTextPlain":
        return _esc(rt.get("text")).replace("\n", "<br>")
    if t == "richTexts":
        return "".join(text_html(x, depth + 1) for x in _list(rt.get("texts")))
    if t in WRAP:
        a, b = WRAP[t]
        return a + text_html(rt.get("text"), depth + 1) + b
    if t in ("richTextUrl", "richTextReferenceLink", "richTextAnchorLink"):
        inner = text_html(rt.get("text"), depth + 1)
        href = _href(rt.get("url"))
        return f'<a href="{href}">{inner}</a>' if href else inner
    if t == "richTextEmailAddress":
        inner = text_html(rt.get("text"), depth + 1)
        return f'<a href="mailto:{_esc(rt.get("email_address"))}">{inner}</a>'
    if t == "richTextDiff":
        return f'<s>{text_html(rt.get("old_text"), depth + 1)}</s> {text_html(rt.get("text"), depth + 1)}'
    if t == "richTextMathematicalExpression":
        return f'<code>{_esc(rt.get("expression"))}</code>'
    if t in ("richTextCustomEmoji", "richTextButton", "richTextIcon", "richTextAnchor"):
        return _esc(text_plain(rt, depth))
    # mention, hashtag, date-time, phone, reference, bot command …: show their text as is
    return text_html(rt.get("text"), depth + 1)


# ------------------------------------------------------------------ PageBlocks
CAPTIONED_MEDIA = {
    "pageBlockPhoto": "Photo", "pageBlockVideo": "Video", "pageBlockAnimation": "GIF", "pageBlockAudio": "Audio",
    "pageBlockVoiceNote": "Voice message", "pageBlockDocument": "File", "pageBlockMap": "Map",
    "pageBlockEmbedded": "Embedded content", "pageBlockCollage": "Collage", "pageBlockSlideshow": "Slideshow",
}


def _caption_plain(cap):
    cap = _obj(cap)
    return " ".join(x for x in (text_plain(cap.get("text")), text_plain(cap.get("credit"))) if x)


def _cell_align(a):
    t = _obj(a).get("@type", "")
    return {"pageBlockHorizontalAlignmentCenter": "center", "pageBlockHorizontalAlignmentRight": "right"}.get(t, "left")


def _table_html(b, depth):
    rows = []
    for row in _list(b.get("cells")):
        cells = []
        for cell in _list(row):
            cell = _obj(cell)
            tag = "th" if cell.get("is_header") else "td"
            span = ""
            if isinstance(cell.get("colspan"), int) and cell["colspan"] > 1:
                span += f' colspan="{cell["colspan"]}"'
            if isinstance(cell.get("rowspan"), int) and cell["rowspan"] > 1:
                span += f' rowspan="{cell["rowspan"]}"'
            cells.append(f'<{tag}{span} align="{_cell_align(cell.get("align"))}">{text_html(cell.get("text"), depth + 1)}</{tag}>')
        rows.append("<tr>" + "".join(cells) + "</tr>")
    cap = text_html(b.get("caption"), depth + 1)
    cap_html = f"<p><i>{cap}</i></p>" if cap else ""
    return (cap_html + '<table border="1" cellspacing="0" cellpadding="5" style="border-color:#808080; '
            'border-style:solid; margin-top:4px; margin-bottom:4px">' + "".join(rows) + "</table>")


def _table_plain(b):
    lines = []
    for row in _list(b.get("cells")):
        lines.append(" | ".join(text_plain(_obj(c).get("text")) for c in _list(row)))
    return "\n".join(lines)


def block_html(b, depth=0):
    b = _obj(b)
    t = b.get("@type", "")
    if depth > MAX_DEPTH:
        return f"<p>{_esc(block_plain(b))}</p>"
    if t in ("pageBlockTitle", "pageBlockHeader"):
        return f"<h3>{text_html(b.get('title') or b.get('header'), depth + 1)}</h3>"
    if t in ("pageBlockSubtitle", "pageBlockSubheader", "pageBlockKicker"):
        return f"<h4>{text_html(b.get('subtitle') or b.get('subheader') or b.get('kicker'), depth + 1)}</h4>"
    if t == "pageBlockSectionHeading":
        size = b.get("size") if isinstance(b.get("size"), int) else 2
        level = min(6, max(3, size + 2))
        return f"<h{level}>{text_html(b.get('text'), depth + 1)}</h{level}>"
    if t in ("pageBlockParagraph", "pageBlockFooter", "pageBlockThinking"):
        inner = text_html(b.get("text"), depth + 1)
        return f"<p><i>{inner}</i></p>" if t != "pageBlockParagraph" else f"<p>{inner}</p>"
    if t == "pageBlockPreformatted":
        return f"<pre>{_esc(text_plain(b.get('text'), depth + 1))}</pre>"
    if t == "pageBlockMathematicalExpression":
        return f"<pre>{_esc(b.get('expression'))}</pre>"
    if t == "pageBlockDivider":
        return "<hr>"
    if t == "pageBlockList":
        items = []
        for it in _list(b.get("items")):
            it = _obj(it)
            box = ("☑ " if it.get("is_checked") else "☐ ") if it.get("has_checkbox") else ""
            label = it.get("label") if isinstance(it.get("label"), str) else ""
            inner = "".join(block_html(x, depth + 1) for x in _list(it.get("blocks")))
            # Qt wraps a lone paragraph in extra spacing inside <li>; unwrap the simple case
            if inner.startswith("<p>") and inner.endswith("</p>") and inner.count("<p>") == 1:
                inner = inner[3:-4]
            prefix = f"{_esc(label)} " if label and label not in ("•", "-", "*") else ""
            items.append(f"<li>{box}{prefix}{inner}</li>")
        return "<ul>" + "".join(items) + "</ul>"
    if t == "pageBlockBlockQuote":
        inner = "".join(block_html(x, depth + 1) for x in _list(b.get("blocks")))
        credit = text_html(b.get("credit"), depth + 1)
        return f"<blockquote>{inner}{f'<p>— {credit}</p>' if credit else ''}</blockquote>"
    if t in ("pageBlockExpandableBlockQuote", "pageBlockPullQuote"):
        credit = text_html(b.get("credit"), depth + 1)
        return f"<blockquote><p>{text_html(b.get('text'), depth + 1)}</p>{f'<p>— {credit}</p>' if credit else ''}</blockquote>"
    if t == "pageBlockDetails":
        # Qt has no <details>: show the header bold and the body indented, always open
        inner = "".join(block_html(x, depth + 1) for x in _list(b.get("blocks")))
        return f"<p><b>▸ {text_html(b.get('header'), depth + 1)}</b></p><blockquote>{inner}</blockquote>"
    if t == "pageBlockTable":
        return _table_html(b, depth)
    if t == "pageBlockCover":
        return block_html(b.get("cover"), depth + 1)
    if t == "pageBlockEmbeddedPost":
        inner = "".join(block_html(x, depth + 1) for x in _list(b.get("blocks")))
        return f"<blockquote><p><b>{_esc(b.get('author'))}</b></p>{inner}</blockquote>"
    if t in CAPTIONED_MEDIA:
        cap = _caption_plain(b.get("caption"))
        return f"<p><i>[{CAPTIONED_MEDIA[t]}{': ' + _esc(cap) if cap else ''}]</i></p>"
    if t == "pageBlockChatLink":
        return f"<p><i>[{_esc(b.get('title'))}]</i></p>"
    if t == "pageBlockAuthorDate":
        return f"<p><i>{text_html(b.get('author'), depth + 1)}</i></p>"
    return ""   # anchors, button rows, related articles, unsupported


def block_plain(b, depth=0):
    b = _obj(b)
    t = b.get("@type", "")
    if depth > MAX_DEPTH:
        return ""
    for key in ("title", "header", "subtitle", "subheader", "kicker"):
        if key in b and t != "pageBlockDetails" and t != "pageBlockTable":
            return text_plain(b.get(key))
    if t in ("pageBlockParagraph", "pageBlockFooter", "pageBlockThinking", "pageBlockSectionHeading",
             "pageBlockPreformatted", "pageBlockExpandableBlockQuote", "pageBlockPullQuote"):
        return text_plain(b.get("text"))
    if t == "pageBlockMathematicalExpression":
        return b.get("expression") if isinstance(b.get("expression"), str) else ""
    if t == "pageBlockList":
        out = []
        for it in _list(b.get("items")):
            it = _obj(it)
            box = ("[x] " if it.get("is_checked") else "[ ] ") if it.get("has_checkbox") else ""
            label = it.get("label") if isinstance(it.get("label"), str) and it.get("label") else "•"
            out.append(f"{label} {box}" + " ".join(block_plain(x, depth + 1) for x in _list(it.get("blocks"))))
        return "\n".join(out)
    if t in ("pageBlockBlockQuote", "pageBlockEmbeddedPost"):
        return "\n".join(block_plain(x, depth + 1) for x in _list(b.get("blocks")))
    if t == "pageBlockDetails":
        body = "\n".join(block_plain(x, depth + 1) for x in _list(b.get("blocks")))
        return text_plain(b.get("header")) + ("\n" + body if body else "")
    if t == "pageBlockTable":
        return _table_plain(b)
    if t == "pageBlockCover":
        return block_plain(b.get("cover"), depth + 1)
    if t in CAPTIONED_MEDIA:
        cap = _caption_plain(b.get("caption"))
        return f"[{CAPTIONED_MEDIA[t]}{': ' + cap if cap else ''}]"
    return ""


PARTIAL_NOTE = "Partial message: open it in an official Telegram app for the rest."


def convert(rich_message):
    """richMessage → (plain_text, html, is_full). html is '' when the message is too large to draw safely."""
    rm = _obj(rich_message)
    blocks = _list(rm.get("blocks"))
    plain = "\n\n".join(p for p in (block_plain(b) for b in blocks) if p)
    body = "".join(block_html(b) for b in blocks)
    is_full = rm.get("is_full") is not False
    if not is_full:
        body += f"<p><i>{_esc(PARTIAL_NOTE)}</i></p>"
        plain += f"\n\n{PARTIAL_NOTE}"
    if len(body) > MAX_HTML:
        body = ""
    return plain, body, is_full
