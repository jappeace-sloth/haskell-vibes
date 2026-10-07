#!/usr/bin/env python3
"""List the API changes of a Haskell package between two versions.

Usage: hs-api-diff.py OLD NEW

OLD and NEW are each either a Hoogle file, as written by
`cabal haddock --haddock-hoogle`, or PACKAGE-VERSION, which fetches the
Hoogle file Hackage built for that release.

The Hoogle file is Haddock's record of what every exposed module exports,
so this sees single re-exported names, operators, modules without an export
list, constructors, record fields, classes, associated types and instances.
It reports REMOVED and CHANGED entities, which break callers, ADDED
CONSTRUCTOR on an existing type, which breaks a pattern match that has no
wildcard, and ADDED METHOD on an existing class, which breaks instances
unless the method has a default (the file does not say; check the source).
A method is recognised as a signature right after its class line whose
first constraint is that class.  Instances are compared without module qualifiers, counting
how many share each unqualified form: Haddock files an instance under the
module it picks for the type, and docs built by different GHC versions
qualify classes differently (GHC.Show.Show, GHC.Internal.Show.Show).  A
removal lowers the count and is reported; qualifier-only differences are
summed up in one line.

Not in the Hoogle file, so not seen: a whole re-exported module (`module X`
in an export list), which of two same-named types a signature refers to
(signatures are printed unqualified), type family instances, and behaviour
changes such as input that is now refused.
"""
import re
import sys
import urllib.error
import urllib.request
from collections import Counter

HACKAGE_RELEASE = re.compile(r"^[A-Za-z][\w-]*-\d+(\.\d+)*$")
LEADING_FORALL = re.compile(r"^forall [^.]*\.\s*")
MODULE_QUALIFIER = re.compile(r"\b(?:[A-Z][\w']*\.)+(?=[A-Z])")

Key = tuple[str, str]
Modules = dict[str, dict[Key, str]]


def read_hoogle(source: str) -> str:
    if HACKAGE_RELEASE.match(source):
        package = source.rsplit("-", 1)[0]
        url = f"https://hackage.haskell.org/package/{source}/docs/{package}.txt"
        try:
            with urllib.request.urlopen(url) as response:
                return response.read().decode()
        except urllib.error.HTTPError as failure:
            sys.exit(f"no Hoogle file for {source} on Hackage ({failure.code} at {url}); "
                     "build one with `cabal haddock --haddock-hoogle` and pass its path")
    with open(source) as handle:
        text = handle.read()
    if not re.search(r"^@package ", text, re.M):
        sys.exit(f"{source} is not a Hoogle file (no @package line)")
    return text


def logical_lines(text: str) -> list[str]:
    """The declarations, with each `class ... where {` block folded into one line."""
    declarations: list[str] = []
    in_class_block = False
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("--") or stripped.startswith("@"):
            continue
        if in_class_block:
            declarations[-1] += " " + stripped
            in_class_block = stripped != "}"
            continue
        declarations.append(stripped)
        in_class_block = stripped.endswith("where {")
    return declarations


def declaration_key(declaration: str) -> Key:
    words = declaration.split()
    if words[0] in ("data", "newtype", "type", "class", "pattern"):
        kind = " ".join(words[:2]) if words[1] == "family" else words[0]
        head = declaration[len(kind):].split(" where", 1)[0].split(" = ", 1)[0].split(" :: ", 1)[0]
        name = head.split("=>")[-1].split()[0]
        return (kind, name)
    name = declaration.split(" :: ", 1)[0].strip("[]()")
    return ("value", name)


def normalize(declaration: str) -> str:
    """Whitespace collapsed and a top-level forall dropped; a rank-N forall stays."""
    declaration = " ".join(declaration.split())
    if " :: " in declaration and not declaration.startswith(("instance ", "class ")):
        name, signature = declaration.split(" :: ", 1)
        declaration = f"{name} :: {LEADING_FORALL.sub('', signature)}"
    return declaration


def first_constraint_class(declaration: str) -> str | None:
    signature = declaration.split(" :: ", 1)[1] if " :: " in declaration else ""
    if "=>" not in signature:
        return None
    context = signature.split("=>", 1)[0].strip().lstrip("(").split()
    return context[0] if context else None


def parse_api(text: str) -> tuple[Modules, set[str], dict[tuple[str, str], str]]:
    """Each module's entities, the package's instances, which Haddock files
    under whichever module it picks for the type, and which values are class
    methods: Haddock prints a class's methods right after the class line."""
    modules: Modules = {}
    instances: set[str] = set()
    methods: dict[tuple[str, str], str] = {}
    module, current_class = None, None
    for declaration in logical_lines(text):
        if declaration.startswith("module "):
            module, current_class = declaration.split()[1], None
            modules[module] = {}
        elif declaration.startswith("instance "):
            instances.add(normalize(declaration))
        elif module is None:
            sys.exit(f"declaration before any module line: {declaration}")
        else:
            key = declaration_key(declaration)
            modules[module][key] = normalize(declaration)
            if key[0] == "class":
                current_class = key[1]
            elif key[0] == "value" and current_class and first_constraint_class(declaration) == current_class:
                methods[(module, key[1])] = current_class
            else:
                current_class = None
    return modules, instances, methods


def result_type(signature: str) -> str:
    """The type name a constructor builds: the head of its last arrow at depth 0."""
    depth, last_arrow = 0, 0
    for index, character in enumerate(signature):
        depth += {"(": 1, "[": 1, ")": -1, "]": -1}.get(character, 0)
        if depth == 0 and signature.startswith("->", index):
            last_arrow = index + 2
    return signature[last_arrow:].split()[0].strip("()")


def added_constructors(module: str, old_entities: dict[Key, str], new_entities: dict[Key, str]) -> list[str]:
    """Constructors new to a type that already existed, which break exhaustive matches."""
    old_types = {key[1] for key in old_entities if key[0] in ("data", "newtype")}
    found = []
    for key in sorted(set(new_entities) - set(old_entities)):
        if key[0] == "value" and key[1][:1].isupper():
            built = result_type(new_entities[key].split(" :: ", 1)[1])
            if built in old_types:
                found.append(f"ADDED CONSTRUCTOR {module}: {new_entities[key]}")
    return found


def instance_changes(old_instances: set[str], new_instances: set[str]) -> tuple[list[str], int, int]:
    """Lines naming removed instances, how many were removed, and how many
    matched only once qualifiers were dropped.

    Each unqualified form is counted on both sides, so when two types share a
    name and one of them loses an instance the count drops and it is reported.
    """
    old_only, new_only = old_instances - new_instances, new_instances - old_instances
    new_counts = Counter(MODULE_QUALIFIER.sub("", instance) for instance in new_only)
    old_by_form: dict[str, list[str]] = {}
    for instance in sorted(old_only):
        old_by_form.setdefault(MODULE_QUALIFIER.sub("", instance), []).append(instance)
    removed, removed_count, qualifier_only = [], 0, 0
    for form, candidates in sorted(old_by_form.items()):
        missing = len(candidates) - new_counts[form]
        if missing > 0:
            removed += [f"REMOVED ({missing} of these) {candidate}" for candidate in candidates]
            removed_count += missing
        qualifier_only += min(len(candidates), new_counts[form])
    return removed, removed_count, qualifier_only


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    old_api, old_instances, _ = parse_api(read_hoogle(sys.argv[1]))
    new_api, new_instances, new_methods = parse_api(read_hoogle(sys.argv[2]))
    breaking = 0
    for module in sorted(old_api):
        if module not in new_api:
            print(f"REMOVED MODULE {module}")
            breaking += 1
            continue
        old_entities, new_entities = old_api[module], new_api[module]
        for key in sorted(old_entities):
            if key not in new_entities:
                print(f"REMOVED {module}: {old_entities[key]}")
                breaking += 1
            elif old_entities[key] != new_entities[key]:
                print(f"CHANGED {module}.{key[1]}\n  old {old_entities[key]}\n  new {new_entities[key]}")
                breaking += 1
        for line in added_constructors(module, old_entities, new_entities):
            print(line)
        for key in sorted(set(new_entities) - set(old_entities)):
            owner = new_methods.get((module, key[1]))
            if key[0] == "value" and owner and ("class", owner) in old_entities:
                print(f"ADDED METHOD {module}: {new_entities[key]} "
                      "(breaks instances unless it has a default; check the source)")
    removed_instances, removed_count, qualifier_only = instance_changes(old_instances, new_instances)
    for line in removed_instances:
        print(line)
    breaking += removed_count
    if qualifier_only:
        print(f"{qualifier_only} instance(s) matched only after dropping module qualifiers "
              "(docs from different GHC versions, or a type that moved module)")
    added = sorted(set(new_api) - set(old_api))
    if added:
        print(f"added modules: {', '.join(added)}")
    print(f"{breaking} breaking change(s) across {len(set(old_api) & set(new_api))} common modules; "
          "not checked: whole-module re-exports, same-named types, type family instances, behaviour")


if __name__ == "__main__":
    main()
