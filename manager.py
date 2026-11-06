#!/usr/bin/env python3
"""Discover shell installers, display a selection tree, and run chosen scripts."""
import argparse
import curses
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT / "configs"
PROFILES = ("default", "desktop", "server")


def modules():
    results = []
    for script in sorted(BASE.rglob("install.sh")):
        relative = script.parent.relative_to(BASE)
        if not relative.parts or relative.parts[0] not in PROFILES:
            continue
        meta = {"description": relative.name, "default": "false"}
        for line in script.read_text(encoding="utf-8").splitlines()[:15]:
            if line.startswith("# description:"):
                meta["description"] = line.split(":", 1)[1].strip()
            elif line.startswith("# default:"):
                meta["default"] = line.split(":", 1)[1].strip().lower()
        results.append({"path": str(relative), "script": script, **meta})
    return results


def tree(items):
    groups = set()
    for m in items:
        parts = Path(m["path"]).parts
        for depth in range(1, len(parts)):
            groups.add("/".join(parts[:depth]))
    groups.update(PROFILES)
    entries = [{"kind": "group", "path": g} for g in groups] + [
        {**m, "kind": "module"} for m in items
    ]
    return sorted(entries, key=lambda e: (e["path"].split("/"), e["kind"] == "module"))


def select_ui(screen, items, selected):
    curses.curs_set(0)
    screen.keypad(True)
    entries = tree(items)
    pos = 0
    offset = 0
    message = "Space: toggle | a: all on | n: all off | Enter: run | q: quit"
    while True:
        height, width = screen.getmaxyx()
        screen.erase()
        screen.addnstr(0, 0, "equa-bootstrap  |  modules discovered automatically", max(0, width - 1), curses.A_BOLD)
        screen.addnstr(1, 0, message, max(0, width - 1))
        available = max(1, height - 4)
        if pos < offset:
            offset = pos
        if pos >= offset + available:
            offset = pos - available + 1
        for row, entry in enumerate(entries[offset:offset+available], start=3):
            path = entry["path"]
            depth = path.count("/")
            if entry["kind"] == "group":
                members = [m["path"] for m in items if m["path"].startswith(path + "/")]
                count = len(set(members) & selected)
                indicator = "[x]" if members and count == len(members) else "[-]" if count else "[ ]"
                label = path.split("/")[-1] + "/"
            else:
                indicator = "[x]" if path in selected else "[ ]"
                label = path.split("/")[-1] + " — " + entry["description"]
            line = "  " * depth + indicator + " " + label
            attr = curses.A_REVERSE if (offset + row - 3) == pos else 0
            screen.addnstr(row, 0, line, max(0, width - 1), attr)
        screen.addnstr(height - 1, 0, f"Selected {len(selected)}/{len(items)} | Enter: execute", max(0,width-1))
        screen.refresh()
        key = screen.getch()
        if key in (curses.KEY_UP, ord('k')):
            pos = max(0, pos - 1)
        elif key in (curses.KEY_DOWN, ord('j')):
            pos = min(len(entries) - 1, pos + 1)
        elif key == ord('a'):
            selected.update(m["path"] for m in items)
        elif key == ord('n'):
            selected.clear()
        elif key == ord(' '):
            entry = entries[pos]
            paths = [entry["path"]] if entry["kind"] == "module" else [m["path"] for m in items if m["path"].startswith(entry["path"] + "/")]
            if all(path in selected for path in paths):
                selected.difference_update(paths)
            else:
                selected.update(paths)
        elif key in (10, 13, curses.KEY_ENTER):
            return selected
        elif key in (ord('q'), 27):
            return None


def main():
    parser = argparse.ArgumentParser(description="Composable CLI bootstrap")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--only", help="Comma-separated module paths (or unique module names)")
    parser.add_argument("--profile", choices=PROFILES)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    items = modules()
    if args.list:
        for m in items:
            print(f'{m["path"]:48} {m["description"]}  (default={m["default"]})')
        return 0
    selected = {m["path"] for m in items if m["default"] == "true"}
    if args.all:
        selected = {m["path"] for m in items}
    if args.profile:
        selected = {m["path"] for m in items if m["path"].startswith(args.profile + "/")}
    if args.only:
        selected = set()
        for name in args.only.split(","):
            name = name.strip()
            matches = [m["path"] for m in items if m["path"] == name or m["path"].split("/")[-1] == name]
            if len(matches) != 1:
                parser.error(f"--only '{name}' matched {len(matches)} modules; use the full path")
            selected.add(matches[0])
    if not (args.all or args.profile or args.only or args.dry_run):
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            parser.error("Interactive mode requires a TTY; specify --only or --profile")
        selection = curses.wrapper(select_ui, items, selected)
        if selection is None:
            print("Cancelled")
            return 0
        selected = selection
    targets = [m for m in items if m["path"] in selected]
    print("\nSelected modules:")
    for m in targets:
        print("  - " + m["path"])
    if args.dry_run:
        print("Dry run: no scripts executed")
        return 0
    if not targets:
        print("Nothing selected")
        return 0
    # Require review before running any installer, even when using a profile.
    if sys.stdin.isatty():
        answer = input("Run selected installers? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Cancelled")
            return 0
    for m in targets:
        print(f'\n=== {m["path"]} ===', flush=True)
        env = dict(os.environ, BOOTSTRAP_ROOT=str(ROOT), BOOTSTRAP_MODULE=m["path"])
        code = subprocess.call(["bash", str(m["script"])], cwd=str(m["script"].parent), env=env)
        if code != 0:
            print(f'FAILED: {m["path"]} (exit {code}); stopping', file=sys.stderr)
            return code
    print("\nAll selected modules finished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
