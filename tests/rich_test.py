import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bin"))
import omagram_rich as rich  # noqa: E402
import omagram_state as model  # noqa: E402


def P(t):
    return {"@type": "richTextPlain", "text": t}


def cell(t, header=False):
    return {"@type": "pageBlockTableCell", "text": P(t), "is_header": header, "colspan": 1, "rowspan": 1,
            "align": {"@type": "pageBlockHorizontalAlignmentLeft"}, "valign": {"@type": "pageBlockVerticalAlignmentTop"}}


def msg(blocks, full=True):
    return {"@type": "messageRichMessage", "message": {"@type": "richMessage", "blocks": blocks, "is_rtl": False, "is_full": full}}


class RichMessageTest(unittest.TestCase):
    def test_table_becomes_text_kind_with_html_and_plain_fallback(self):
        c = model.content(msg([{"@type": "pageBlockTable", "caption": P(""), "is_bordered": True, "is_striped": False,
                                "is_compact": False, "cells": [[cell("A", True), cell("B", True)], [cell("1"), cell("2")]]}]))
        self.assertEqual(c["kind"], "text")
        self.assertIn("<th align=\"left\">A</th>", c["html"])
        self.assertEqual(c["text"], "A | B\n1 | 2")
        self.assertEqual(model.preview_text({"kind": "text", "text": c["text"]}), "A | B 1 | 2")

    def test_network_text_is_escaped(self):
        c = model.content(msg([{"@type": "pageBlockParagraph", "text": P("<img src=x onerror=1> & \"q\"")}]))
        self.assertNotIn("<img", c["html"])
        self.assertIn("&lt;img src=x onerror=1&gt; &amp; &quot;q&quot;", c["html"])

    def test_only_safe_link_schemes(self):
        bad = {"@type": "richTextUrl", "text": P("x"), "url": "javascript:alert(1)", "is_cached": False}
        good = {"@type": "richTextUrl", "text": P("y"), "url": "https://example.org/?a=1&b=2", "is_cached": False}
        html = rich.text_html({"@type": "richTexts", "texts": [bad, good]})
        self.assertNotIn("javascript", html)
        self.assertIn('<a href="https://example.org/?a=1&amp;b=2">y</a>', html)

    def test_checklist_and_details(self):
        item = {"@type": "pageBlockListItem", "label": "•", "has_checkbox": True, "is_checked": False, "value": 0, "type": "",
                "blocks": [{"@type": "pageBlockParagraph", "text": P("todo")}]}
        details = {"@type": "pageBlockDetails", "header": P("More"), "is_open": False,
                   "blocks": [{"@type": "pageBlockParagraph", "text": P("hidden")}]}
        plain, html, full = rich.convert({"blocks": [{"@type": "pageBlockList", "items": [item]}, details], "is_full": True})
        self.assertIn("<li>☐ todo</li>", html)
        self.assertIn("▸ More", html)
        self.assertEqual(plain, "• [ ] todo\n\nMore\nhidden")
        self.assertTrue(full)

    def test_partial_message_is_flagged(self):
        c = model.content(msg([{"@type": "pageBlockParagraph", "text": P("start")}], full=False))
        self.assertTrue(c["richPartial"])
        self.assertIn(rich.PARTIAL_NOTE, c["text"])

    def test_garbage_does_not_raise(self):
        for junk in (None, 5, "x", {"blocks": "nope"}, {"blocks": [None, 3, {"@type": "pageBlockList", "items": [None]}]}):
            plain, html, _ = rich.convert(junk)
            self.assertIsInstance(plain, str)
            self.assertIsInstance(html, str)

    def test_deep_nesting_is_bounded(self):
        rt = P("deep")
        for _ in range(200):
            rt = {"@type": "richTextBold", "text": rt}
        self.assertLess(rich.text_html(rt).count("<b>"), rich.MAX_DEPTH + 2)


if __name__ == "__main__":
    unittest.main()
