"""Convert the project concept Markdown into a formatted DOCX.

Usage:
  python md_to_docx.py <input.md> <output.docx> [--base-dir DIR]

Supports the Markdown subset used by docs/concept/项目构思方案_v0.1.md:
  # headings (1-4), paragraphs, > blockquotes, - / * bullets, 1. numbered lists,
  | tables |, ``` code fences ```, --- horizontal rules, ![alt](img) images,
  inline **bold**, `code`, [text](url).
"""
import re
import sys
import os
import json
import datetime

from docx import Document
from docx.shared import Pt, Cm, RGBColor, Emu
from docx.enum.text import (WD_ALIGN_PARAGRAPH, WD_LINE_SPACING, WD_BREAK,
                            WD_TAB_ALIGNMENT, WD_TAB_LEADER)
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

BODY_FONT = "微软雅黑"
MONO_FONT = "Consolas"
ACCENT = RGBColor(0x1F, 0x3A, 0x5F)
ACCENT2 = RGBColor(0x0F, 0x76, 0x6E)
GRAY = RGBColor(0x55, 0x5F, 0x6D)


def set_run_font(run, name=BODY_FONT, size=None, bold=None, color=None, ascii_name=None):
    run.font.name = ascii_name or name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), ascii_name or name)
    rfonts.set(qn("w:hAnsi"), ascii_name or name)
    rfonts.set(qn("w:eastAsia"), name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color is not None:
        run.font.color.rgb = color


def shade(cell_or_par, hex_fill):
    el = cell_or_par._tc if hasattr(cell_or_par, "_tc") else cell_or_par._p
    pr = el.get_or_add_tcPr() if hasattr(el, "get_or_add_tcPr") else el.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_fill)
    pr.append(shd)


INLINE_RE = re.compile(r"(\*\*.+?\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))")


def add_inline(paragraph, text, base_size=10.5, base_color=None, base_bold=False):
    text = re.sub(r"\\\|", "|", text)
    for token in INLINE_RE.split(text):
        if not token:
            continue
        if token.startswith("**") and token.endswith("**") and len(token) > 4:
            r = paragraph.add_run(token[2:-2])
            set_run_font(r, size=base_size, bold=True, color=base_color)
        elif token.startswith("`") and token.endswith("`") and len(token) > 2:
            r = paragraph.add_run(token[1:-1])
            set_run_font(r, name=MONO_FONT, size=base_size - 0.5,
                         color=RGBColor(0x0F, 0x76, 0x6E), ascii_name=MONO_FONT)
        elif token.startswith("[") and "](" in token:
            m = re.match(r"\[([^\]]+)\]\(([^)]+)\)", token)
            label, url = m.group(1), m.group(2)
            r = paragraph.add_run(label)
            set_run_font(r, size=base_size, color=RGBColor(0x1D, 0x4E, 0xD8))
            r.font.underline = True
            if not os.path.isabs(url):
                pass  # relative links are kept as plain underlined text
        else:
            r = paragraph.add_run(token)
            set_run_font(r, size=base_size, color=base_color, bold=base_bold or None)


def add_heading(doc, level, text):
    para = doc.add_paragraph()
    para.paragraph_format.space_before = Pt({1: 20, 2: 14, 3: 10, 4: 8}.get(level, 8))
    para.paragraph_format.space_after = Pt({1: 8, 2: 6, 3: 4, 4: 3}.get(level, 3))
    para.paragraph_format.keep_with_next = True
    size = {1: 16, 2: 13, 3: 11.5, 4: 10.5}.get(level, 10.5)
    color = ACCENT if level <= 2 else ACCENT2
    # strip inline markup for heading text
    clean = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    clean = re.sub(r"`([^`]+)`", r"\1", clean)
    r = para.add_run(clean)
    set_run_font(r, size=size, bold=True, color=color)
    if level <= 2:
        pPr = para._p.get_or_add_pPr()
        pBdr = OxmlElement("w:pBdr")
        bottom = OxmlElement("w:bottom")
        bottom.set(qn("w:val"), "single")
        bottom.set(qn("w:sz"), "6" if level == 1 else "4")
        bottom.set(qn("w:space"), "4")
        bottom.set(qn("w:color"), "B7C4D6" if level == 1 else "D6DEE9")
        pBdr.append(bottom)
        pPr.append(pBdr)
    return para


def add_blockquote(doc, lines):
    for line in lines:
        text = line.lstrip("> ").rstrip()
        if not text:
            continue
        para = doc.add_paragraph()
        para.paragraph_format.left_indent = Cm(0.4)
        para.paragraph_format.space_after = Pt(2)
        # left border
        pPr = para._p.get_or_add_pPr()
        pBdr = OxmlElement("w:pBdr")
        left = OxmlElement("w:left")
        left.set(qn("w:val"), "single")
        left.set(qn("w:sz"), "18")
        left.set(qn("w:space"), "8")
        left.set(qn("w:color"), "2B6CB0")
        pBdr.append(left)
        pPr.append(pBdr)
        add_inline(para, text, base_size=9.5, base_color=RGBColor(0x33, 0x41, 0x55))


def add_code_block(doc, lines):
    para = doc.add_paragraph()
    para.paragraph_format.left_indent = Cm(0.3)
    para.paragraph_format.space_before = Pt(4)
    para.paragraph_format.space_after = Pt(8)
    para.paragraph_format.line_spacing = 1.0
    shade(para, "F3F5F8")
    text = "\n".join(lines)
    r = para.add_run(text)
    set_run_font(r, name=MONO_FONT, size=8.5, color=RGBColor(0x24, 0x2C, 0x38), ascii_name=MONO_FONT)


def add_table(doc, rows):
    # rows: list of list of cell strings; first row = header
    ncols = max(len(r) for r in rows)
    table = doc.add_table(rows=0, cols=ncols)
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = True
    for i, row in enumerate(rows):
        cells = table.add_row().cells
        for j in range(ncols):
            text = row[j] if j < len(row) else ""
            cell = cells[j]
            cell.text = ""
            para = cell.paragraphs[0]
            para.paragraph_format.space_before = Pt(1)
            para.paragraph_format.space_after = Pt(1)
            para.paragraph_format.line_spacing = 1.0
            add_inline(para, text, base_size=8.5, base_bold=(i == 0))
            if i == 0:
                shade(cell, "E8EEF6")
        # repeat the header row on every page and never split a row across pages
        trPr = table.rows[-1]._tr.get_or_add_trPr()
        if i == 0:
            th = OxmlElement("w:tblHeader")
            th.set(qn("w:val"), "true")
            trPr.append(th)
        cs = OxmlElement("w:cantSplit")
        cs.set(qn("w:val"), "true")
        trPr.append(cs)
    # small spacer
    sp = doc.add_paragraph()
    sp.paragraph_format.space_after = Pt(0)
    sp.paragraph_format.line_spacing = 0.5
    r = sp.add_run("")
    set_run_font(r, size=4)


def parse_table(lines):
    rows = []
    for line in lines:
        line = line.strip()
        if not line.startswith("|"):
            continue
        if re.match(r"^\|[\s:\-|]+\|$", line):
            continue  # separator row
        # split on unescaped pipes
        cells = re.split(r"(?<!\\)\|", line)
        cells = [c.strip() for c in cells]
        if cells and cells[0] == "":
            cells = cells[1:]
        if cells and cells[-1] == "":
            cells = cells[:-1]
        rows.append(cells)
    return rows


def add_cover(doc, title, subtitle_lines):
    for _ in range(5):
        doc.add_paragraph()
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run(title)
    set_run_font(r, size=28, bold=True, color=ACCENT)
    for line in subtitle_lines:
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(line)
        set_run_font(r, size=12, color=GRAY)
    doc.add_page_break()


def base_style(doc):
    st = doc.styles["Normal"]
    st.font.name = BODY_FONT
    st.font.size = Pt(10.5)
    st.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_FONT)
    st.paragraph_format.line_spacing = 1.35
    st.paragraph_format.space_after = Pt(4)
    sec = doc.sections[0]
    sec.page_width = Cm(21.0)
    sec.page_height = Cm(29.7)
    sec.top_margin = Cm(2.2)
    sec.bottom_margin = Cm(2.2)
    sec.left_margin = Cm(2.2)
    sec.right_margin = Cm(2.0)


def add_page_number_footer(doc):
    p = doc.sections[0].footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER

    def text_run(t):
        r = p.add_run(t)
        set_run_font(r, size=9, color=GRAY)
        return r

    text_run("第　")
    r = p.add_run()
    set_run_font(r, size=9, color=GRAY)
    begin = OxmlElement("w:fldChar")
    begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = "PAGE"
    sep = OxmlElement("w:fldChar")
    sep.set(qn("w:fldCharType"), "separate")
    t = OxmlElement("w:t")
    t.text = "1"
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    for el in (begin, instr, sep, t, end):
        r._r.append(el)
    text_run("　页")


def add_toc(doc, entries, anchor_p, pages):
    """Insert a table of contents before anchor_p; anchor_p becomes the page break."""
    toc_paras = []
    head = doc.add_paragraph()
    head.paragraph_format.space_before = Pt(2)
    head.paragraph_format.space_after = Pt(12)
    r = head.add_run("目　录")
    set_run_font(r, size=15, bold=True, color=ACCENT)
    toc_paras.append(head)
    for level, text in entries:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(4)
        p.paragraph_format.line_spacing = 1.15
        p.paragraph_format.left_indent = Cm(0.0 if level == 1 else 0.6)
        p.paragraph_format.tab_stops.add_tab_stop(
            Cm(15.7), WD_TAB_ALIGNMENT.RIGHT, WD_TAB_LEADER.DOTS)
        label = text if len(text) <= 38 else text[:37] + "…"
        page = pages.get(text, pages.get(text.strip(), "1"))
        r = p.add_run(label + "\t" + str(page))
        set_run_font(r, size=10 if level == 1 else 9.5, bold=(level == 1),
                     color=ACCENT if level == 1 else RGBColor(0x33, 0x41, 0x55))
        toc_paras.append(p)
    for p in toc_paras:
        anchor_p._p.addprevious(p._p)
    anchor_p.add_run().add_break(WD_BREAK.PAGE)


def main():
    src, out = sys.argv[1], sys.argv[2]
    base_dir = None
    if "--base-dir" in sys.argv:
        base_dir = sys.argv[sys.argv.index("--base-dir") + 1]
    if base_dir is None:
        base_dir = os.path.dirname(os.path.abspath(src))

    with open(src, encoding="utf-8") as f:
        lines = f.read().split("\n")

    doc = Document()
    base_style(doc)

    # Cover from the first H1 + following blockquote lines
    first_h1 = next((l for l in lines if l.startswith("# ")), "# 项目构思方案")
    cover_title = re.sub(r"^#\s*", "", first_h1)
    add_cover(doc, cover_title, [
        "产品与技术构思（v0.1）",
        "DeepSeek Remote AI · 手机远程控制系统",
        "依据《DeepSeek_Remote_AI_项目策划案及自动开发任务书》v1.0",
        "生成日期：" + datetime.date.today().isoformat() + "　|　直接执行人：DeepSeek Harness",
    ])

    i = 0
    n = len(lines)
    skipped_title = False
    in_code = False
    code_lines = []
    table_buf = []
    num_counter = 0
    prev_num_line = False
    toc_entries = []

    toc_pages = {}
    if "--toc-pages" in sys.argv:
        with open(sys.argv[sys.argv.index("--toc-pages") + 1], encoding="utf-8") as f:
            toc_pages = json.load(f)
    want_toc = "--toc" in sys.argv
    add_page_number_footer(doc)
    anchor_p = doc.add_paragraph()
    anchor_p.paragraph_format.space_after = Pt(0)

    def flush_table():
        nonlocal table_buf
        if table_buf:
            rows = parse_table(table_buf)
            if rows:
                add_table(doc, rows)
            table_buf = []

    while i < n:
        line = lines[i]
        stripped = line.strip()
        pending_num = prev_num_line
        prev_num_line = False

        # code fence
        if stripped.startswith("```"):
            if in_code:
                add_code_block(doc, code_lines)
                code_lines = []
                in_code = False
            else:
                flush_table()
                in_code = True
            i += 1
            continue
        if in_code:
            code_lines.append(line)
            i += 1
            continue

        # table block
        if stripped.startswith("|"):
            table_buf.append(line)
            i += 1
            continue
        else:
            flush_table()

        if not stripped:
            i += 1
            continue

        if stripped in ("---", "***", "___"):
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(6)
            p.paragraph_format.space_after = Pt(6)
            pPr = p._p.get_or_add_pPr()
            pBdr = OxmlElement("w:pBdr")
            bottom = OxmlElement("w:bottom")
            bottom.set(qn("w:val"), "single")
            bottom.set(qn("w:sz"), "4")
            bottom.set(qn("w:space"), "1")
            bottom.set(qn("w:color"), "D6DEE9")
            pBdr.append(bottom)
            pPr.append(pBdr)
            i += 1
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            flush_table()
            level = len(m.group(1))
            # the cover already carries the document title: skip the first H1
            if level == 1 and not skipped_title:
                skipped_title = True
                i += 1
                continue
            add_heading(doc, level, m.group(2))
            if level <= 3:
                clean = re.sub(r"\*\*([^*]+)\*\*", r"\1", m.group(2))
                clean = re.sub(r"`([^`]+)`", r"\1", clean).strip()
                toc_entries.append((1 if level <= 2 else 2, clean))
            i += 1
            continue

        # image
        m = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)\s*$", stripped)
        if m:
            alt, path = m.group(1), m.group(2)
            img_path = path if os.path.isabs(path) else os.path.join(base_dir, path)
            if os.path.exists(img_path):
                p = doc.add_paragraph()
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                p.paragraph_format.space_before = Pt(6)
                p.paragraph_format.space_after = Pt(2)
                run = p.add_run()
                run.add_picture(img_path, width=Cm(16.4))
                if alt:
                    cap = doc.add_paragraph()
                    cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
                    cap.paragraph_format.space_after = Pt(10)
                    cr = cap.add_run("图：" + alt)
                    set_run_font(cr, size=9, color=GRAY)
            else:
                print("WARN missing image:", img_path)
            i += 1
            continue

        # blockquote
        if stripped.startswith(">"):
            bq = []
            while i < n and lines[i].strip().startswith(">"):
                bq.append(lines[i])
                i += 1
            add_blockquote(doc, bq)
            continue

        # list item
        m_bullet = re.match(r"^([-*])\s+(.*)$", stripped)
        if m_bullet:
            para = doc.add_paragraph(style="List Bullet")
            para.paragraph_format.space_after = Pt(2)
            para.paragraph_format.line_spacing = 1.25
            add_inline(para, m_bullet.group(2))
            i += 1
            continue
        m_num = re.match(r"^(\d+)\.\s+(.*)$", stripped)
        if m_num:
            num_counter = num_counter + 1 if pending_num else 1
            prev_num_line = True
            para = doc.add_paragraph()
            para.paragraph_format.space_after = Pt(2)
            para.paragraph_format.line_spacing = 1.25
            para.paragraph_format.left_indent = Cm(0.78)
            para.paragraph_format.first_line_indent = Cm(-0.48)
            add_inline(para, "%d. " % num_counter + m_num.group(2))
            i += 1
            continue

        # ordinary paragraph
        para = doc.add_paragraph()
        para.paragraph_format.space_after = Pt(5)
        add_inline(para, stripped)
        i += 1

    if want_toc and toc_entries:
        add_toc(doc, toc_entries, anchor_p, toc_pages)
    else:
        anchor_p._p.getparent().remove(anchor_p._p)

    if "--toc-dump" in sys.argv:
        with open(sys.argv[sys.argv.index("--toc-dump") + 1], "w", encoding="utf-8") as f:
            json.dump(toc_entries, f, ensure_ascii=False, indent=1)

    doc.save(out)
    print("saved:", out, "size:", os.path.getsize(out))
    print("toc entries:", len(toc_entries))


if __name__ == "__main__":
    main()
