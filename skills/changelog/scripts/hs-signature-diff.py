#!/usr/bin/env python3
"""List the API changes of a Haskell package between two git refs.

Usage: hs-signature-diff.py OLD_REF NEW_REF [REPO_DIR]

Reads the .cabal file at each ref, takes every exposed-modules entry, finds
each module under its hs-source-dirs and compares, per module, the export
list and the top-level type signatures.  Haddock comments and explicit
foralls are stripped first, so a reworded comment is not reported.

It sees: removed modules, removed exports, and changed signatures of
exported top-level functions.  It does NOT see changed data constructors or
record fields, class methods, instances, CPP-selected code, or re-exports of
whole modules.  Treat an empty report as "no signature changed", not as
"nothing breaks": refused inputs and changed errors only show up in the code
and the changelog.
"""
import re
import subprocess
import sys

HASKELL_SYMBOL = r"!#$%&*+./<=>?@\\^|~:"
LINE_COMMENT = re.compile(rf"(?<![{HASKELL_SYMBOL}])--(?![{HASKELL_SYMBOL}]).*")
BLOCK_COMMENT = re.compile(r"\{-(?!#).*?-\}", re.S)
FORALL = re.compile(r"\bforall\b[^.]*\.\s*")
SIGNATURE_START = re.compile(r"^([a-z_][\w']*(?:\s*,\s*[a-z_][\w']*)*)\s*$|^([a-z_][\w']*(?:\s*,\s*[a-z_][\w']*)*)\s*::")


def git_show(repo, ref, path):
    result = subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"],
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def cabal_file(repo, ref):
    listing = subprocess.run(["git", "-C", repo, "ls-tree", "--name-only", ref],
                             capture_output=True, text=True, check=True).stdout.split()
    cabals = [name for name in listing if name.endswith(".cabal")]
    if len(cabals) != 1:
        sys.exit(f"expected one .cabal file at the root of {ref}, found {cabals}")
    return git_show(repo, ref, cabals[0])


def cabal_field_values(cabal, field):
    """Every value of a cabal field, across all stanzas, as one list of words."""
    values = []
    pattern = re.compile(rf"^(\s*){field}:(.*)$", re.I)
    lines = cabal.split("\n")
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if not match:
            continue
        indent = len(match.group(1))
        chunk = [match.group(2)]
        for following in lines[index + 1:]:
            stripped = following.strip()
            if stripped and (len(following) - len(following.lstrip())) <= indent:
                break
            if stripped and re.match(r"^[\w-]+:", stripped):
                break
            chunk.append(following)
        values += re.findall(r"[^\s,]+", LINE_COMMENT.sub("", "\n".join(chunk)))
    return values


def module_source(repo, ref, module, source_dirs):
    relative = module.replace(".", "/") + ".hs"
    # The dirs come from every stanza, and a library without hs-source-dirs
    # means ".", so "." is always tried last.
    for directory in source_dirs + ["."]:
        path = relative if directory in (".", "./") else f"{directory.rstrip('/')}/{relative}"
        source = git_show(repo, ref, path)
        if source is not None:
            return source
    return None


def exports_and_signatures(source):
    """The export list (None when the module exports everything) and signatures."""
    code = LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", source))
    header = re.search(r"^module\s+[\w.]+\s*\((.*?)\)\s*where", code, re.S | re.M)
    exports = set(re.findall(r"(?<![\w'])[a-zA-Z_][\w']*", header.group(1))) if header else None
    signatures = {}
    lines = code.split("\n")
    index = 0
    while index < len(lines):
        match = SIGNATURE_START.match(lines[index])
        if not match:
            index += 1
            continue
        names = match.group(1) or match.group(2)
        text = lines[index][len(names):]
        index += 1
        while index < len(lines) and (lines[index].startswith((" ", "\t")) or not lines[index].strip()):
            if not lines[index].strip():
                break
            text += " " + lines[index].strip()
            index += 1
        text = " ".join(FORALL.sub("", text).split())
        if text.startswith("::"):
            for name in re.split(r"\s*,\s*", names.strip()):
                signatures[name] = text
    return exports, signatures


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    old_ref, new_ref = sys.argv[1], sys.argv[2]
    repo = sys.argv[3] if len(sys.argv) == 4 else "."
    old_cabal, new_cabal = cabal_file(repo, old_ref), cabal_file(repo, new_ref)
    old_modules = set(cabal_field_values(old_cabal, "exposed-modules"))
    new_modules = set(cabal_field_values(new_cabal, "exposed-modules"))
    old_dirs = cabal_field_values(old_cabal, "hs-source-dirs")
    new_dirs = cabal_field_values(new_cabal, "hs-source-dirs")

    findings = 0
    for module in sorted(old_modules - new_modules):
        print(f"REMOVED MODULE {module}")
        findings += 1
    for module in sorted(old_modules & new_modules):
        old_source = module_source(repo, old_ref, module, old_dirs)
        new_source = module_source(repo, new_ref, module, new_dirs)
        if old_source is None or new_source is None:
            print(f"SKIPPED {module}: source not found at one of the refs")
            continue
        old_exports, old_signatures = exports_and_signatures(old_source)
        new_exports, new_signatures = exports_and_signatures(new_source)
        if old_exports is not None and new_exports is not None:
            for name in sorted((old_exports - new_exports) & set(old_signatures)):
                print(f"REMOVED EXPORT {module}.{name}")
                findings += 1
        for name in sorted(set(old_signatures) & set(new_signatures)):
            exported = new_exports is None or name in new_exports
            if exported and old_signatures[name] != new_signatures[name]:
                print(f"CHANGED {module}.{name}\n  old {old_signatures[name]}\n  new {new_signatures[name]}")
                findings += 1
    added = sorted(new_modules - old_modules)
    if added:
        print(f"added modules (not breaking): {', '.join(added)}")
    print(f"{findings} breaking change(s) found across {len(old_modules & new_modules)} common modules")


if __name__ == "__main__":
    main()
