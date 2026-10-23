#!/usr/bin/env python3
"""Export this project's Markdown operator guide for Windows Notepad.

Development tool only; the generated TXT needs no runtime on the server.
Supports the headings, paragraphs, lists, links, tables and fenced code used
by ANVANDARGUIDE.md. Code blocks are copied without reformatting commands.
"""

import argparse
from pathlib import Path
import re
import textwrap


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ANVANDARGUIDE.md"
TARGET = SOURCE.with_suffix(".txt")


def plain(text):
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)
    return text.replace("**", "").replace("`", "")


def wrapped(text):
    match = re.match(r"^(\s*(?:- |\d+\. ))", text)
    indent = " " * len(match[1]) if match else ""
    return textwrap.wrap(
        text, width=88, subsequent_indent=indent,
        break_long_words=False, break_on_hyphens=False,
    )


def render(markdown):
    output = [
        "Textversion av ANVANDARGUIDE.md. Genererad automatiskt; redigera Markdown-filen.",
        "",
    ]
    paragraph = []
    headers = None
    code = False

    def flush():
        if paragraph:
            output.extend(wrapped(plain(" ".join(paragraph))))
            paragraph.clear()

    for line in markdown.splitlines():
        if line.startswith("```"):
            flush()
            code = not code
            continue
        if code:
            output.append(line)
            continue
        if not line.strip():
            flush()
            output.append("")
            headers = None
        elif line.startswith("|"):
            flush()
            cells = [plain(cell.strip()) for cell in line.strip().strip("|").split("|")]
            if all(re.fullmatch(r":?-+:?", cell) for cell in cells):
                continue
            if headers is None:
                headers = cells
                continue
            if len(cells) != len(headers):
                raise ValueError("Table row has a different number of cells than its header")
            for header, cell in zip(headers, cells):
                output.extend(wrapped(f"{header}: {cell}"))
            output.append("")
        elif re.match(r"^#{1,6} ", line):
            flush()
            heading = plain(line.lstrip("# "))
            output.extend([heading, "=" * len(heading) if line.startswith("# ") else "-" * len(heading)])
        elif re.match(r"^\s*(?:- |\d+\. )", line):
            flush()
            paragraph.append(line)
        else:
            paragraph.append(line.strip())
    flush()
    if code:
        raise ValueError("Unclosed code fence")
    return ("\r\n".join(output).rstrip() + "\r\n").encode("utf-8-sig")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the TXT mirror is missing or out of date")
    args = parser.parse_args()
    content = render(SOURCE.read_text(encoding="utf-8-sig"))
    if args.check:
        if not TARGET.exists() or TARGET.read_bytes() != content:
            parser.exit(1, "ANVANDARGUIDE.txt is out of date. Run: python3 tools/export_user_guide.py\n")
        print("ANVANDARGUIDE.txt is up to date.")
    else:
        TARGET.write_bytes(content)
        print(f"Generated {TARGET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
