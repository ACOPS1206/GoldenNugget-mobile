#!/usr/bin/env python3
"""Rewrite PoC.xcodeproj/project.pbxproj for the Nugget/Core refactor.

XcodeGen is not available in this environment, so the project file is edited
surgically instead.  The rules the script enforces:

  * the legacy `Sparserestore` group becomes `Core` (path = Core)
  * every .swift file under Nugget/Core/ is referenced by that group and added
    to the single Sources build phase
  * Backup.swift / MBDB.swift (deleted) lose their build file, file reference,
    group entry and build-phase entry
  * new object IDs are deterministic (md5 of the file name) and never collide
    with an ID already present in the file
"""

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "PoC.xcodeproj" / "project.pbxproj"
CORE_DIR = ROOT / "Nugget" / "Core"
LEGACY_GROUP_NAME = "Sparserestore"
LEGACY_GROUP_ID = "02718FE4F507CDB13D3AC30F"
# Objects that survive the move (the group's path changes, these do not).
KEEP = {"PoCEngine.swift", "InstProxy.swift"}
REMOVED = {"Backup.swift", "MBDB.swift"}

HEX24 = re.compile(r"^[0-9A-F]{24}$")


def make_id(name: str, tag: str, used: set) -> str:
    """Deterministic, collision-free 24-char uppercase hex object ID."""
    seed = f"{tag}:{name}".encode()
    for salt in range(1000):
        candidate = hashlib.md5(seed + str(salt).encode()).hexdigest().upper()[:24]
        if candidate not in used:
            used.add(candidate)
            return candidate
    raise RuntimeError(f"could not mint an ID for {name}")


def find_block(text: str, start: str, end: str) -> tuple:
    i = text.index(start)
    j = text.index(end, i)
    return i, j


def rewrite_build_file_section(text: str, new_entries: list, drop_names: set) -> str:
    start = "/* Begin PBXBuildFile section */\n"
    end = "/* End PBXBuildFile section */"
    i, j = find_block(text, start, end)
    body_lines = [l for l in text[i + len(start):j].split("\n") if l.strip()]
    entry_re = re.compile(
        r"^\t\t([0-9A-F]{24}) /\* (.*?) \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24}) /\* (.*?) \*/; \};$"
    )
    kept = [l for l in body_lines if entry_re.match(l)]
    kept = [l for l in kept if entry_re.match(l).group(2).split(" in ")[0] not in drop_names]
    combined = kept + new_entries
    combined.sort(key=lambda l: entry_re.match(l).group(2))
    return text[:i + len(start)] + "\n".join(combined) + "\n" + text[j:]


def rewrite_file_reference_section(text: str, new_entries: list, drop_names: set) -> str:
    start = "/* Begin PBXFileReference section */\n"
    end = "/* End PBXFileReference section */"
    i, j = find_block(text, start, end)
    body_lines = [l for l in text[i + len(start):j].split("\n") if l.strip()]
    name_re = re.compile(r"^\t\t[0-9A-F]{24} /\* (.*?) \*/ = \{isa = PBXFileReference;")
    kept = [l for l in body_lines if name_re.match(l)]
    kept = [l for l in kept if name_re.match(l).group(1) not in drop_names]
    combined = kept + new_entries
    combined.sort(key=lambda l: name_re.match(l).group(1))
    return text[:i + len(start)] + "\n".join(combined) + "\n" + text[j:]


def rewrite_sources_phase(text: str, new_entries: list, drop_names: set) -> str:
    start = "/* Begin PBXSourcesBuildPhase section */"
    marker = "\t\t\tfiles = (\n"
    i = text.index(start)
    k = text.index(marker, i) + len(marker)
    closing = text.index("\t\t\t);", k)
    body_lines = [l for l in text[k:closing].split("\n") if l.strip()]
    name_re = re.compile(r"^\t{4}[0-9A-F]{24} /\* (.*?) in Sources \*/,?$")
    kept = [l for l in body_lines if name_re.match(l)]
    kept = [l for l in kept if name_re.match(l).group(1) not in drop_names]
    combined = [l.rstrip(",") + "," for l in kept] + new_entries
    # A kept file (PoCEngine.swift, InstProxy.swift) is also listed in
    # `new_entries`, so collapse to one line per name before sorting.
    by_name = {}
    for line in combined:
        by_name[name_re.match(line).group(1)] = line
    combined = [by_name[k] for k in sorted(by_name)]
    return text[:k] + "\n".join(combined) + "\n" + text[closing:]


def rewrite_group(text: str, children_lines: list) -> str:
    start = f"\t\t{LEGACY_GROUP_ID} /* {LEGACY_GROUP_NAME} */ = {{\n"
    end = "\t\t};\n"
    i = text.index(start)
    j = text.index(end, i) + len(end)
    block = (
        f"\t\t{LEGACY_GROUP_ID} /* Core */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        + "".join(children_lines)
        + "\t\t\t);\n"
        "\t\t\tpath = Core;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
    )
    return text[:i] + block + text[j:]


def main() -> int:
    text = PBXPROJ.read_text(encoding="utf-8")

    files = sorted(p.name for p in CORE_DIR.glob("*.swift"))
    if not files:
        print("no sources found under Nugget/Core", file=sys.stderr)
        return 1

    used = set(re.findall(r"\b[0-9A-F]{24}\b", text))

    # Existing IDs for the two files that keep their name.
    existing = {}
    for m in re.finditer(
        r"^\t\t([0-9A-F]{24}) /\* (.*?) \*/ = \{isa = PBXFileReference;",
        text,
        re.MULTILINE,
    ):
        existing[m.group(2)] = m.group(1)
    existing_build = {}
    for m in re.finditer(
        r"^\t\t([0-9A-F]{24}) /\* (.*?) \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})",
        text,
        re.MULTILINE,
    ):
        existing_build[m.group(2).split(" in ")[0]] = m.group(1)

    new_refs, new_builds, child_lines = [], [], []
    for name in files:
        if name in KEEP:
            ref = existing[name]
            build = existing_build[name]
        else:
            ref = make_id(name, "fileRef", used)
            build = make_id(name, "buildFile", used)
            new_refs.append(
                f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = sourcecode.swift; path = {name}; "
                f"sourceTree = \"<group>\"; }};"
            )
            new_builds.append(
                f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; "
                f"fileRef = {ref} /* {name} */; }};"
            )
        child_lines.append(f"\t\t\t\t{ref} /* {name} */,\n")
    child_lines.sort(key=lambda l: l.split("/* ", 1)[1].split(" */")[0])

    phase_entries = []
    for name in files:
        build = existing_build.get(name)
        if build is None:
            m = [l for l in new_builds if f"/* {name} in Sources */" in l]
            build = m[0].strip().split(" ")[0]
        phase_entries.append(f"\t\t\t\t{build} /* {name} in Sources */,")

    text = rewrite_build_file_section(text, new_builds, REMOVED)
    text = rewrite_file_reference_section(text, new_refs, REMOVED)
    text = rewrite_sources_phase(text, phase_entries, REMOVED)
    text = rewrite_group(text, child_lines)
    # The group keeps its ID, so this rename is the only place the legacy name is
    # spelled in a comment; the parent's child entry has no comment, but the
    # parent group's entry does.
    text = text.replace(
        f"{LEGACY_GROUP_ID} /* {LEGACY_GROUP_NAME} */", f"{LEGACY_GROUP_ID} /* Core */"
    )

    PBXPROJ.write_text(text, encoding="utf-8")
    print(f"rewrote {PBXPROJ.relative_to(ROOT)}: {len(files)} Core sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
