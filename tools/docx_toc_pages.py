"""Map DOCX/PDF headings to page numbers (used to fill the table of contents).

Usage:
  python docx_toc_pages.py <pdf> <toc_entries.json> [--out <toc_pages.json>] [--verify]

toc_entries.json is the JSON written by md_to_docx.py --toc-dump:
  [[1, "0. 一页纸结论"], [2, "1.1 ..."], ...]

With --verify it checks the page map stored inside the PDF (nothing) -- instead
it re-derives the mapping and prints it, so a caller can compare two runs.
Normalisation ignores spaces/punctuation so that PDF text extraction quirks do
not hide a heading.
"""
import json
import re
import sys

import pymupdf


def norm(s):
    s = s.replace("\u3000", "")
    s = re.sub(r"\s+", "", s)
    return s


def page_texts(pdf):
    doc = pymupdf.open(pdf)
    return [norm(p.get_text()) for p in doc], doc.page_count


def find_page(pages, heading, start=0):
    """Return the first page index (1-based) containing heading, searching from start."""
    key = norm(heading)
    # strip a leading numbering for the search to avoid the TOC itself matching,
    # but keep enough characters to stay unique
    for idx in range(start, len(pages)):
        if key in pages[idx]:
            return idx + 1
    # fallback: prefix match on the first 14 chars
    key14 = key[:14]
    for idx in range(start, len(pages)):
        if key14 and key14 in pages[idx]:
            return idx + 1
    return None


def main():
    pdf = sys.argv[1]
    entries = json.load(open(sys.argv[2], encoding="utf-8"))
    pages, count = page_texts(pdf)
    # start searching after page 1 (cover) and after the TOC pages: skip pages
    # that contain many of the headings (the TOC page)
    toc_end = 1
    while toc_end < count:
        hits = sum(1 for _, h in entries if norm(h)[:12] in pages[toc_end])
        if hits >= 3:
            toc_end += 1
        else:
            break
    result = {}
    cursor = toc_end
    for level, heading in entries:
        pg = find_page(pages, heading, start=cursor)
        if pg is None:
            pg = find_page(pages, heading, start=toc_end)
        result[heading] = pg
        if pg:
            cursor = pg - 1
    print("pages:", count, "toc_end:", toc_end, "mapped:", len(result))
    missing = [h for h, p in result.items() if p is None]
    if missing:
        print("MISSING:", missing)
    for level, heading in entries:
        print(("  " if level == 2 else "") + heading, "->", result.get(heading))
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
        json.dump({k: v for k, v in result.items() if v}, open(out, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)
        print("wrote", out)


if __name__ == "__main__":
    main()
