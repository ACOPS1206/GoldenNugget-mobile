#!/usr/bin/env python3
"""Generate Nugget/Core/PosterBoardResources.swift from GoldenNugget's bundled
PosterBoard assets.

Why generate instead of copying the directory: the reference reads these through
``get_bundle_files("files/posterboard/...")`` at runtime — a Qt resource path
that does not exist in this app, and whose contents are *not* the kind of thing
anyone should retype.  A single byte wrong in ``main.caml``'s frame list or in
``Wallpaper.plist`` and the wallpaper silently does not appear.

So they are **embedded in the binary** rather than shipped as bundle resources,
for the reason ``project.yml`` already gives about its own assets: this project
is built by two different builders (Xcode and ``xtool``) from one source list,
and a resource added to ``Package.swift`` alone would never reach
``project.pbxproj`` — the two bundles would quietly disagree.  A generated Swift
file has no such half-state.

The four groups, and where the reference uses each:

  * ``configconversion/*.plist``  — ``PBConfigManager.cache_config_files``:
    replaces whatever the tendie itself carries for these three names, per
    descriptor version directory.
  * ``contents.plist``            — ``create_live_photo_files``: the AAR header
    payload (``wrap_in_aar``).
  * ``1F20C883-…/``               — the live-photo descriptor skeleton that the
    video and the thumbnail are written into.
  * ``VideoCAML/``                — the video-loop descriptor skeleton whose
    ``.ca`` is replaced by a generated ``main.caml``.

Usage:
    scripts/gen-pb-resources-from-goldennugget.py            # write the file
    scripts/gen-pb-resources-from-goldennugget.py --check     # exit 1 on drift
    scripts/gen-pb-resources-from-goldennugget.py --goldennugget ~/GoldenNugget
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Nugget" / "Core" / "PosterBoardResources.swift"
DEFAULT_SOURCE = os.path.expanduser("~/GoldenNugget")
RELATIVE_SOURCE = "files/posterboard"

# The live-photo descriptor root, by its own name: it is a fixed identifier the
# reference hardcodes in two places (`create_live_photo_files`, `recursive_add`).
LIVE_PHOTO_ROOT = "1F20C883-EA98-4CCE-9923-0C9A01359721"
VIDEO_LOOP_ROOT = "VideoCAML"

# Base64 is emitted in fixed-width lines inside one multi-line string literal.
# The decoder is given `.ignoreUnknownCharacters`, so the newlines are dropped
# — which is also what makes a changed file visible in a diff as changed lines
# rather than as one changed 12 000-character line.
WRAP = 96


def collect(root: Path) -> list[tuple[str, bytes]]:
    """Every regular file under ``root``, as (POSIX relative path, bytes).

    Sorted, so the generated file is a pure function of the tree.  Symlinks and
    directories are not part of the payload: the reference copies the tree with
    ``copytree`` and the injector derives every directory row from the file
    paths, so a directory with no files in it carries nothing.
    """
    if not root.is_dir():
        sys.exit(f"gen-pb-resources: no {root}")
    entries: list[tuple[str, bytes]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        entries.append((rel, path.read_bytes()))
    if not entries:
        sys.exit(f"gen-pb-resources: {root} holds no files")
    return entries


def swift_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def b64_literal(data: bytes, indent: str) -> str:
    text = base64.b64encode(data).decode("ascii")
    lines = [text[i:i + WRAP] for i in range(0, len(text), WRAP)]
    # Every line carries the closing delimiter's indentation: Swift strips that
    # prefix from each line of a multi-line literal, and a line indented less
    # than the delimiter is an error ("insufficient indentation").
    body = "\n".join(indent + line for line in lines)
    return f'{indent}b64("""\n{body}\n{indent}""")'


def doc_lines(text: str, indent: str = "    ") -> str:
    """``text`` as one or more ``///`` comment lines, wrapped at 88 columns."""
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if current and len(candidate) > 86:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return "\n".join(f"{indent}/// {line}" for line in lines)


def emit_group(name: str, doc: str, entries: list[tuple[str, bytes]]) -> str:
    lines = [doc_lines(doc), f"    static let {name}: [String: Data] = ["]
    for rel, data in entries:
        lines.append(f'        "{swift_string(rel)}":')
        lines.append(b64_literal(data, "            ") + ",")
    lines.append("    ]")
    return "\n".join(lines)


def emit_blob(name: str, doc: str, data: bytes) -> str:
    return (f"{doc_lines(doc)}\n    static let {name}: Data =\n"
            + b64_literal(data, "        "))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--goldennugget", default=DEFAULT_SOURCE,
                    help="path to the reference checkout (default: ~/GoldenNugget)")
    ap.add_argument("--check", action="store_true",
                    help="report drift and exit 1 instead of writing")
    args = ap.parse_args()

    source = Path(args.goldennugget) / RELATIVE_SOURCE
    config = collect(source / "configconversion")
    live = collect(source / LIVE_PHOTO_ROOT)
    video = collect(source / VIDEO_LOOP_ROOT)
    contents = source / "contents.plist"
    if not contents.is_file():
        sys.exit(f"gen-pb-resources: no {contents}")

    total = sum(len(d) for _, d in config + live + video) + contents.stat().st_size

    generated = f'''// Generated by scripts/gen-pb-resources-from-goldennugget.py — do not edit by hand.
//
// Source: the reference's ``{RELATIVE_SOURCE}``, {len(config) + len(live) + len(video) + 1} files,
// {total} bytes, embedded base64.  These are the files the reference reads through
// ``get_bundle_files("files/posterboard/…")``.
//
// Embedded rather than shipped as bundle resources on purpose: this project is
// built by both Xcode (from project.pbxproj) and xtool (from xtool.yml), and a
// resource added to only one of them would produce two bundles that quietly
// disagree.  A generated Swift file cannot be half-installed.
//
// Regenerate after an upstream change to that directory; `--check` fails on drift.

import Foundation

enum PosterBoardResources {{
    /// Base64 decoding that tolerates the line wrapping above, and refuses to
    /// hand out an empty file where a real one was written: a corrupt literal
    /// would otherwise reach the device as a 0-byte payload, which the wallpaper
    /// store answers by dropping the descriptor.
    private static func b64(_ value: String) -> Data {{
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters),
              !data.isEmpty || value.isEmpty else {{
            preconditionFailure("PosterBoardResources: a base64 literal did not decode")
        }}
        return data
    }}

    /// The live-photo descriptor root's own name.  ``create_live_photo_files``
    /// writes the video into a folder of this name under ``video-descriptor/``.
    static let livePhotoIdentifier = "{LIVE_PHOTO_ROOT}"

{emit_group("configConversion",
            "The three ``com.apple.posterkit.provider.instance.*`` plists that replace a "
            "tendie's own copies (``PBConfigManager.cache_config_files``).",
            config)}

    /// ``files/posterboard/contents.plist`` — the AAR's first member.
    /// ``create_live_photo_files`` wraps this plus the video into
    /// ``segmentation.data.aar``.
{emit_blob("livePhotoContentsPlist",
           "The contents.plist ``wrap_in_aar`` embeds beside the video.",
           contents.read_bytes())}

{emit_group("livePhotoDescriptor",
            f"The ``{LIVE_PHOTO_ROOT}/`` skeleton, paths relative to that root.",
            live)}

{emit_group("videoLoopDescriptor",
            f"The ``{VIDEO_LOOP_ROOT}/`` skeleton for a looping video wallpaper, "
            "paths relative to that root.",
            video)}
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
        print(f"{OUTPUT.relative_to(ROOT)} already current ({total} bytes embedded)")
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated, encoding="utf-8")
    count = len(config) + len(live) + len(video) + 1
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {count} files, {total} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
