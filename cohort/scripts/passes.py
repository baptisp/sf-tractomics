"""Parameters of each pass, and the rules that keep earlier passes reusable.

Passes are params/passes/<k>_<name>.yaml, run in the order of k. Pass k runs with
params/shared.yaml and passes 1..k together, so every task an earlier pass computed is asked for
again with the same parameters, and Nextflow reuses it (-resume) instead of computing it again.
That holds only if:
  - no pass sets a parameter of params/shared.yaml;
  - a parameter set by two passes keeps its value, or goes from false to true (a metric turned on
    later); any other change would change, or drop, what an earlier pass computed.
Every pass file is checked against every other on each call, so a bad edit is refused before any
run, whichever pass is asked for.

Usage:
  python3 scripts/passes.py list                      pass names, in order
  python3 scripts/passes.py check                     the rules above, on every pass
  python3 scripts/passes.py resolve PASS OUT [--set key=value ...]
      writes the parameters of PASS to OUT; --set adds run-specific values (paths), which no
      parameter file may set
The files are flat YAML (key: value per line, comments allowed); anything nested is refused.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARED = ROOT / "params" / "shared.yaml"
PASS_DIR = ROOT / "params" / "passes"
PASS_NAME = re.compile(r"^(\d+)_[a-z0-9_]+$")
KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")


class PassError(Exception):
    pass


def strip_comment(value):
    """The value without a trailing comment (a # outside quotes, after a space)."""
    quote = None
    for i, c in enumerate(value):
        if quote:
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or value[i - 1].isspace()):
            return value[:i].rstrip()
    return value.rstrip()


def read_flat(path):
    """{key: value text} of a flat YAML file, in file order."""
    values = {}
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0].isspace() or line.lstrip().startswith("-"):
            raise PassError(f"{path.relative_to(ROOT)}:{n}: nested YAML is not supported: {line.strip()}")
        m = KEY_LINE.match(line)
        if not m:
            raise PassError(f"{path.relative_to(ROOT)}:{n}: not a 'key: value' line: {line.strip()}")
        key, value = m.group(1), strip_comment(m.group(2))
        if value == "":
            raise PassError(f"{path.relative_to(ROOT)}:{n}: {key} has no value (nested YAML is not supported)")
        if key in values:
            raise PassError(f"{path.relative_to(ROOT)}:{n}: {key} is set twice")
        values[key] = value
    return values


def pass_files():
    files = sorted(PASS_DIR.glob("*.yaml"))
    numbered = []
    for f in files:
        m = PASS_NAME.match(f.stem)
        if not m:
            raise PassError(f"params/passes/{f.name}: name must be <number>_<name>.yaml (lower case)")
        numbered.append((int(m.group(1)), f))
    numbers = [k for k, _ in numbered]
    if len(set(numbers)) != len(numbers):
        raise PassError(f"two passes share a number: {[f.name for _, f in numbered]}")
    if not numbered:
        raise PassError("no pass in params/passes/")
    return [f for _, f in sorted(numbered)]


def is_false(value):
    return value.strip("\"'").lower() == "false"


def is_true(value):
    return value.strip("\"'").lower() == "true"


def check(shared, passes):
    """Raise PassError when a pass breaks a rule."""
    for name, values in passes:
        both = sorted(set(values) & set(shared))
        if both:
            raise PassError(f"pass {name} sets {', '.join(both)}, a parameter of params/shared.yaml: "
                            "set it there, for every pass")
    first_seen = {}
    for name, values in passes:
        for key, value in values.items():
            if key not in first_seen:
                first_seen[key] = (name, value)
                continue
            earlier_name, earlier = first_seen[key]
            if value == earlier or (is_false(earlier) and is_true(value)):
                first_seen[key] = (name, value)
                continue
            raise PassError(f"pass {name} sets {key}: {value}, after pass {earlier_name} set it to {earlier}: "
                            "a later pass may only add parameters or turn one from false to true")


def load():
    shared = read_flat(SHARED)
    passes = [(f.stem, read_flat(f)) for f in pass_files()]
    check(shared, passes)
    return shared, passes


def resolve(pass_name, out, extra):
    shared, passes = load()
    names = [name for name, _ in passes]
    if pass_name not in names:
        raise PassError(f"unknown pass {pass_name}: {', '.join(names)}")
    for key in extra:
        if key in shared or any(key in values for _, values in passes):
            raise PassError(f"{key} is set by run.sh (--set), not by a parameter file")
    merged = {}
    for name, values in passes[: names.index(pass_name) + 1]:
        merged.update(values)
    lines = [f"# Generated by scripts/passes.py for pass {pass_name}: do not edit",
             f"# params/shared.yaml + passes {', '.join(names[: names.index(pass_name) + 1])}"]
    lines += [f"{k}: {v}" for k, v in extra.items()]
    lines += [f"{k}: {v}" for k, v in shared.items()]
    lines += [f"{k}: {v}" for k, v in merged.items()]
    Path(out).write_text("\n".join(lines) + "\n")


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    try:
        if argv[1] == "list":
            print("\n".join(f.stem for f in pass_files()))
        elif argv[1] == "check":
            load()
        elif argv[1] == "resolve" and len(argv) >= 4:
            extra = {}
            rest = argv[4:]
            while rest:
                if rest[0] != "--set" or len(rest) < 2 or "=" not in rest[1]:
                    raise PassError(f"bad argument {rest[0]}: expected --set key=value")
                key, value = rest[1].split("=", 1)
                extra[key] = value
                rest = rest[2:]
            resolve(argv[2], argv[3], extra)
        else:
            sys.exit(__doc__)
    except PassError as e:
        sys.exit(f"ERROR: {e}")


if __name__ == "__main__":
    main(sys.argv)
