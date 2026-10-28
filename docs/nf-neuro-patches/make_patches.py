"""Write one diff per vendored nf-neuro file that differs from the upstream version recorded in
modules.json, and list vendored components that modules.json does not track.

Usage, from the pipeline root, with a clone of github.com/nf-neuro/modules:
    python3 docs/nf-neuro-patches/make_patches.py ../modules
Run it after any change under modules/nf-neuro or subworkflows/nf-neuro, and commit the result:
a diff that appears or changes in `git status` is a divergence to document in README.md here.
"""
import difflib
import json
import os
import subprocess
import sys

REPO = "https://github.com/nf-neuro/modules.git"
OUT = os.path.dirname(os.path.abspath(__file__))


def upstream(clone, sha, path):
    r = subprocess.run(["git", "-C", clone, "show", f"{sha}:{path}"], capture_output=True)
    return r.stdout.decode() if r.returncode == 0 else None


def main(clone):
    tracked = json.load(open("modules.json"))["repos"][REPO]
    for old in os.listdir(OUT):
        if old.endswith(".diff"):
            os.remove(os.path.join(OUT, old))
    untracked = []
    for kind, depth in (("modules", 2), ("subworkflows", 1)):
        root = f"{kind}/nf-neuro"
        names = sorted({"/".join(os.path.relpath(d, root).split(os.sep)[:depth])
                        for d, _, files in os.walk(root) if files})
        for name in names:
            if name not in tracked[kind]["nf-neuro"]:
                untracked.append(f"{root}/{name}")
                continue
            sha = tracked[kind]["nf-neuro"][name]["git_sha"]
            for d, _, files in os.walk(f"{root}/{name}"):
                for f in sorted(files):
                    path = os.path.join(d, f)
                    if path.endswith(".snap"):
                        continue
                    ours = open(path).read()
                    theirs = upstream(clone, sha, path)
                    if theirs is None or theirs == ours:
                        continue
                    diff = difflib.unified_diff(theirs.splitlines(True), ours.splitlines(True),
                                                f"upstream {sha[:8]}/{path}", f"sf-tractomics/{path}")
                    with open(os.path.join(OUT, path.replace("/", "__") + ".diff"), "w") as out:
                        out.writelines(diff)
                    print(f"differs: {path}")
    for u in untracked:
        print(f"not in modules.json: {u}")


if __name__ == "__main__":
    main(sys.argv[1])
