#!/usr/bin/env python3
"""Generate Nugget/Core/PosterBoardTemplates.swift from GoldenNugget's caml writer.

A video wallpaper works by handing PosterBoard a `.ca` bundle whose `main.caml`
is a frame list: one `<CGImage src="assets/N.jpg"/>` per extracted frame, wrapped
in a fixed CoreAnimation document.  That document is ~1.5 KB of XML and it is
**literal** — every attribute, every tab, and where the file's single trailing
newline falls are part of the artwork the device renders.

Retyping it would be a transcription exercise with no upside, so it is lifted
out of the reference's own writer instead: the three string literals in
``src/controllers/video_handler.py`` (``create_caml``'s f-string header, its
closing literal, and the ``index.xml`` f-string) are read **as source segments**
with ``ast.get_source_segment``.  That keeps the ``{width}``-style placeholders
exactly as written, instead of evaluating them.

The substitutions are mechanical and then checked: every ``{…}`` in the lifted
text has to be one of the five the reference interpolates, the two nested
``{int(width/2)}``/``{int(height/2)}`` expressions, or nothing at all.  A new
placeholder upstream therefore fails this script rather than reaching a device
as a literal ``{width}`` in an animation file.

Usage:
    scripts/gen-pb-templates-from-goldennugget.py            # write the file
    scripts/gen-pb-templates-from-goldennugget.py --check     # exit 1 on drift
    scripts/gen-pb-templates-from-goldennugget.py --goldennugget ~/GoldenNugget
"""

from __future__ import annotations

import argparse
import ast
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Nugget" / "Core" / "PosterBoardTemplates.swift"
DEFAULT_SOURCE = os.path.expanduser("~/GoldenNugget")
RELATIVE_SOURCE = "src/controllers/video_handler.py"

# Python placeholder → Swift expression.  The two `int(...)` forms are the
# reference rounding a position to a whole point; `width`/`height` are already
# integers here, so the cast is the integer division itself.
SUBSTITUTIONS = {
    "{width}": r"\(width)",
    "{height}": r"\(height)",
    "{int(width/2)}": r"\(width / 2)",
    "{int(height/2)}": r"\(height / 2)",
    "{calculationMode}": r"\(calculationMode)",
    "{duration}": r"\(duration)",
    "{reverse}": r"\(reverse)",
}


def literal_segments(source: Path) -> dict[str, str]:
    """The ``caml.write`` / ``index.write`` string literals, by call order.

    Read as source text rather than evaluated: the header is an f-string whose
    ``{width}`` and friends must survive verbatim.
    """
    text = source.read_text(encoding="utf-8")
    tree = ast.parse(text)

    def target_name(node: ast.Call) -> str | None:
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr == "write" and isinstance(func.value, ast.Name):
            return func.value.id
        return None

    found: dict[str, list[str]] = {"caml": [], "index": []}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = target_name(node)
        if name not in found or not node.args:
            continue
        segment = ast.get_source_segment(text, node.args[0])
        if segment is None:
            sys.exit(f"gen-pb-templates: no source for a {name}.write() argument")
        found[name].append(segment)

    # `create_caml` writes the caml three times: the opening document, one frame
    # per image, then the closing document.  Only the first and the last are
    # fixed text; the middle one is one line and is generated from `index`.
    header = [s for s in found["caml"] if "<values>" in s]
    footer = [s for s in found["caml"] if "</caml>" in s]
    if len(header) != 1 or len(footer) != 1 or len(found["index"]) != 1:
        sys.exit("gen-pb-templates: expected one caml opening literal, one caml closing "
                 f"literal and one index literal; found {len(header)}, {len(footer)} "
                 f"and {len(found['index'])}")

    return {"header": header[0], "footer": footer[0], "index": found["index"][0]}


def literal_text(segment: str) -> str:
    """A triple-quoted Python literal's value, escapes interpreted."""
    body = segment
    for prefix in ('f"""', '"""', "f'''", "'''"):
        if body.startswith(prefix):
            body = body[len(prefix):]
            break
    else:
        sys.exit(f"gen-pb-templates: not a triple-quoted literal: {segment[:40]!r}")
    for closing in ('"""', "'''"):
        if body.endswith(closing):
            body = body[: -len(closing)]
            break
    # `\n` and `\t` inside the literal are escapes, not characters; the reference
    # uses both.  unicode_escape is exact for this ASCII-only content.
    return body.encode("utf-8").decode("unicode_escape")


def swift_lines(text: str, indent: str) -> tuple[str, bool]:
    """One Swift string literal per line, with the trailing newline reported.

    Per line rather than as a multi-line Swift literal on purpose: Swift strips
    the closing delimiter's indentation from every line, and these lines start
    with tabs — the exact whitespace is what this file exists to preserve.
    """
    trailing = text.endswith("\n")
    stripped = text[:-1] if trailing else text
    lines = stripped.split("\n")
    rendered = []
    for line in lines:
        # Order matters: escape the backslashes first, then turn the literal
        # characters Swift forbids in a single-line literal into escapes. A tab
        # written raw is "unprintable ASCII character found in source file".
        escaped = line.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t")
        for character in escaped:
            if ord(character) < 0x20:
                sys.exit(f"gen-pb-templates: control character {ord(character)} in {line!r}")
        for python, swift in SUBSTITUTIONS.items():
            escaped = escaped.replace(python, swift)
        # The interpolation markers have to stay unescaped, so they are inserted
        # after the escaping pass; a stray `{`/`}` left over is upstream drift.
        if "{" in escaped or "}" in escaped:
            sys.exit(f"gen-pb-templates: unhandled placeholder in {line!r}")
        rendered.append(f'{indent}"{escaped}",')
    return "\n".join(rendered), trailing


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--goldennugget", default=DEFAULT_SOURCE,
                    help="path to the reference checkout (default: ~/GoldenNugget)")
    ap.add_argument("--check", action="store_true",
                    help="report drift and exit 1 instead of writing")
    args = ap.parse_args()

    source = Path(args.goldennugget) / RELATIVE_SOURCE
    if not source.is_file():
        sys.exit(f"gen-pb-templates: no {source}")

    segments = literal_segments(source)
    header_lines, header_nl = swift_lines(literal_text(segments["header"]), "            ")
    footer_lines, footer_nl = swift_lines(literal_text(segments["footer"]), "            ")
    index_lines, index_nl = swift_lines(literal_text(segments["index"]), "            ")
    for name, flag in (("header", header_nl), ("footer", footer_nl), ("index", index_nl)):
        if not flag:
            sys.exit(f"gen-pb-templates: the {name} literal does not end in a newline; "
                     "the writer's output would differ")

    generated = f'''// Generated by scripts/gen-pb-templates-from-goldennugget.py — do not edit by hand.
//
// Source: ``{RELATIVE_SOURCE}``, the three string literals ``create_caml`` writes.
// Lifted as source segments, so the placeholder spellings, the attribute order and
// the leading tabs are the reference's own.
//
// `--check` fails on drift, and it also fails if upstream grows a placeholder this
// script does not know about — a literal `{{width}}` in a caml file is an animation
// that does not load.

import Foundation

/// The fixed halves of a `.ca` bundle's frame list, plus its `index.xml`.
enum PosterBoardTemplates {{
    /// The document up to `<values>` — the layer tree, and the keyframe animation
    /// whose `duration`, `calculationMode` and `autoreverses` the caller sets.
    static func camlHeader(width: Int, height: Int, calculationMode: String,
                           duration: Double, reverse: Int) -> String {{
        [
{header_lines}
        ].joined(separator: "\\n") + "\\n"
    }}

    /// The closing tags: the three LKStates and their six transitions.
    static func camlFooter() -> String {{
        [
{footer_lines}
        ].joined(separator: "\\n") + "\\n"
    }}

    /// One frame's entry in the `<values>` list.
    static func camlFrame(index: Int) -> String {{
        "\\t\\t\\t<CGImage src=\\"assets/\\(index).jpg\\"/>\\n"
    }}

    /// The `.ca` bundle's `index.xml`, whose `documentWidth`/`documentHeight` are
    /// the frame size — the same numbers as the caml's `bounds`.
    static func camlIndex(width: Int, height: Int) -> String {{
        [
{index_lines}
        ].joined(separator: "\\n") + "\\n"
    }}
}}
'''

    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.is_file() else ""
        if current != generated:
            print(f"drift in {OUTPUT.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print(f"{OUTPUT.relative_to(ROOT)} matches {RELATIVE_SOURCE}")
        return 0

    if OUTPUT.is_file() and OUTPUT.read_text(encoding="utf-8") == generated:
        print(f"{OUTPUT.relative_to(ROOT)} already current")
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
