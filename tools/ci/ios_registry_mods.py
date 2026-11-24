#!/usr/bin/env python3
"""Pick native mods from the Horizon registry index and unpack them as horizon-mixins bundles.

    ios_registry_mods.py --list                      print every native mod (id, version)
    ios_registry_mods.py --out DIR [--selection FILE] ID ...

Selection words: an id turns a mod on, `all` turns on every native mod, `-id` turns one off
(it wins over `all`). Selection files take the same words, one or more per line, `#` comments.
Each chosen mod's newest version that the registry has not marked `broken_on` is downloaded,
checked against the index's size and SHA-256, and its mixins/<id>/ folders copied into DIR.
The index is https://horizon-rust.github.io/horizon-mods/index.json (docs/api/mod-index.md).
Downloads are limited to GitHub release assets. Stdlib only.
"""
import argparse, hashlib, io, json, re, shutil, sys, urllib.request, zipfile
from pathlib import Path

INDEX = "https://horizon-rust.github.io/horizon-mods/index.json"
MAX_BYTES = 64 * 1024 * 1024
ASSET = re.compile(r"^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/[^/]+/[^/]+$")
ID = re.compile(r"^[a-z0-9_]{1,64}$")


def fetch(url, allow_file):
    if not (url.startswith("https://") or (allow_file and url.startswith("file://"))):
        raise SystemExit(f"refusing non-https address: {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read(MAX_BYTES + 1)


def words(lines):
    for line in lines:
        yield from line.split("#", 1)[0].replace(",", " ").split()


def native(index):
    return {p["id"]: p for p in index["projects"] if p.get("kind") == "native-mod"}


def pick_version(project):
    for v in project.get("versions", []):
        if not v.get("broken_on"):
            return v
    return None


def select(projects, wanted):
    on, off = set(), set()
    for w in wanted:
        if w == "all":
            on |= set(projects)
        elif w.startswith("-"):
            off.add(w[1:])
        else:
            on.add(w)
    unknown = sorted((on | off) - set(projects))
    return sorted(i for i in on - off if i in projects), unknown


def safe_members(zf):
    for info in zf.infolist():
        p = Path(info.filename)
        if p.is_absolute() or ".." in p.parts:
            raise SystemExit(f"unsafe path in archive: {info.filename}")
        yield info


def unpack(data, project_id, out):
    """Copy every mixins/<dir>/ holding a horizon-mixin.toml; returns how many."""
    n = 0
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        members = list(safe_members(zf))
        roots = sorted({Path(i.filename).parts[1] for i in members
                        if i.filename.startswith("mixins/") and len(Path(i.filename).parts) > 2
                        and Path(i.filename).name == "horizon-mixin.toml" and len(Path(i.filename).parts) == 3})
        for root in roots:
            dest = out / f"r-{project_id}-{root}"
            if dest.exists():
                shutil.rmtree(dest)
            for info in members:
                parts = Path(info.filename).parts
                if len(parts) > 2 and parts[0] == "mixins" and parts[1] == root and not info.is_dir():
                    target = dest.joinpath(*parts[2:])
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(zf.read(info))
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default=INDEX)
    ap.add_argument("--allow-file", action="store_true", help="tests only: accept file:// addresses")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--selection", type=Path)
    ap.add_argument("ids", nargs="*")
    a = ap.parse_args()
    index = json.loads(fetch(a.index, a.allow_file))
    if index.get("schema") != 1:
        raise SystemExit(f"index schema {index.get('schema')} is not 1: update this script")
    projects = native(index)
    if a.list:
        for pid in sorted(projects):
            v = pick_version(projects[pid])
            print(f"{pid}\t{v['version'] if v else 'broken on the newest Nightly'}\t{projects[pid].get('name', '')}")
        print(f"{len(projects)} native mods", file=sys.stderr)
        return
    if not a.out:
        raise SystemExit("--out is required")
    wanted = list(words(a.ids))
    if a.selection and a.selection.is_file():
        wanted = list(words(a.selection.read_text().splitlines())) + wanted
    chosen, unknown = select(projects, wanted)
    for u in unknown:
        if not ID.match(u):
            raise SystemExit(f"not a mod id: {u}")
        print(f"::warning::{u} is not a native mod in the registry; skipped")
    a.out.mkdir(parents=True, exist_ok=True)
    got = 0
    for pid in chosen:
        v = pick_version(projects[pid])
        if not v:
            print(f"::warning::{pid}: every version is marked broken on the newest Nightly; skipped")
            continue
        f = v["file"]
        if not (ASSET.match(f["url"]) or (a.allow_file and f["url"].startswith("file://"))):
            print(f"::warning::{pid}: unexpected download address; skipped")
            continue
        data = fetch(f["url"], a.allow_file)
        if len(data) != f["size"] or hashlib.sha256(data).hexdigest() != f["sha256"].lower():
            raise SystemExit(f"{pid} {v['version']}: size or SHA-256 differs from the index")
        try:
            n = unpack(data, pid, a.out)
        except zipfile.BadZipFile:
            n = 0
        if n == 0:
            print(f"::warning::{pid} {v['version']}: no mixins/<id>/horizon-mixin.toml in the file; skipped")
            continue
        got += 1
        print(f"{pid} {v['version']}")
    print(f"{got} of {len(chosen)} chosen mods unpacked", file=sys.stderr)


if __name__ == "__main__":
    main()
