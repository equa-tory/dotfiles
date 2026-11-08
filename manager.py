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
        meta = {"description": relative.name, "default": "false", "after": []}
        for line in script.read_text(encoding="utf-8").splitlines()[:15]:
            if line.startswith("# description:"):
                meta["description"] = line.split(":", 1)[1].strip()
            elif line.startswith("# default:"):
                meta["default"] = line.split(":", 1)[1].strip().lower()
            elif line.startswith("# after:"):
                meta["after"] = line.split(":", 1)[1].split()
        results.append({"path": str(relative), "script": script, **meta})
    return results


def order_modules(items):
    """Apply optional # after: module/path execution dependencies."""
    by_path = {item["path"]: item for item in items}
    ordered = []
    visiting = set()
    visited = set()

    def visit(path):
        if path in visited:
            return
        if path in visiting:
            raise ValueError(f"module execution dependency cycle at {path}")
        visiting.add(path)
        for dependency in by_path[path].get("after", []):
            if dependency in by_path:
                visit(dependency)
        visiting.remove(path)
        visited.add(path)
        ordered.append(by_path[path])

    for item in items:
        visit(item["path"])
    return ordered


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


def fuzzy_match(query, text):
    """Return whether query's characters appear in order in text."""
    text_iter = iter(text.casefold())
    return all(any(char == candidate for candidate in text_iter) for char in query.casefold())


def filtered_tree(entries, query):
    if not query:
        return entries
    matching_modules = {
        entry["path"]
        for entry in entries
        if entry["kind"] == "module"
        and fuzzy_match(query, entry["path"] + " " + entry["description"])
    }
    visible = []
    for entry in entries:
        if entry["kind"] == "module":
            if entry["path"] in matching_modules:
                visible.append(entry)
            continue
        prefix = entry["path"] + "/"
        if fuzzy_match(query, entry["path"]) or any(path.startswith(prefix) for path in matching_modules):
            visible.append(entry)
    return visible


def select_ui(screen, items, selected):
    curses.curs_set(0)
    screen.keypad(True)
    entries = tree(items)
    pos = 0
    offset = 0
    query = ""
    search_mode = False
    while True:
        height, width = screen.getmaxyx()
        screen.erase()
        screen.addnstr(0, 0, "equa-bootstrap  |  modules discovered automatically", max(0, width - 1), curses.A_BOLD)
        if search_mode:
            message = f"Fuzzy search: {query}  (Enter: finish, Esc: clear)"
        elif query:
            message = f"Filter: {query}  |  /: edit search"
        else:
            message = "Type to fuzzy filter | /: search | a: all | n: none"
        screen.addnstr(1, 0, message, max(0, width - 1))
        available = max(1, height - 4)
        visible_entries = filtered_tree(entries, query)
        if not visible_entries:
            pos = 0
            offset = 0
        elif pos >= len(visible_entries):
            pos = len(visible_entries) - 1
        if pos < offset:
            offset = pos
        if pos >= offset + available:
            offset = pos - available + 1
        for row, entry in enumerate(visible_entries[offset:offset+available], start=3):
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
        screen.addnstr(height - 1, 0, f"Selected {len(selected)}/{len(items)} | ↑/↓ move · PgUp/PgDn page · Enter run · q quit", max(0,width-1))
        screen.refresh()
        key = screen.getch()
        if search_mode:
            if key in (10, 13, curses.KEY_ENTER):
                search_mode = False
            elif key in (27,):
                query = ""
                pos = offset = 0
                search_mode = False
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                query = query[:-1]
                pos = offset = 0
            elif key >= 0 and key < 256 and chr(key).isprintable():
                query += chr(key)
                pos = offset = 0
            continue
        if key in (curses.KEY_UP, ord('k')):
            pos = max(0, pos - 1)
        elif key in (curses.KEY_DOWN, ord('j')):
            pos = min(len(visible_entries) - 1, pos + 1) if visible_entries else 0
        elif key == curses.KEY_PPAGE:
            pos = max(0, pos - available)
            offset = max(0, offset - available)
        elif key == curses.KEY_NPAGE:
            pos = min(len(visible_entries) - 1, pos + available) if visible_entries else 0
            offset = min(max(0, len(visible_entries) - available), offset + available)
        elif key == ord('/'):
            search_mode = True
        elif key == ord('a'):
            selected.update(m["path"] for m in items)
        elif key == ord('n'):
            selected.clear()
        elif key == ord(' '):
            if not visible_entries:
                continue
            entry = visible_entries[pos]
            paths = [entry["path"]] if entry["kind"] == "module" else [m["path"] for m in items if m["path"].startswith(entry["path"] + "/")]
            if all(path in selected for path in paths):
                selected.difference_update(paths)
            else:
                selected.update(paths)
        elif key in (10, 13, curses.KEY_ENTER):
            return selected
        elif key in (ord('q'), 27):
            if query:
                query = ""
                pos = offset = 0
            else:
                return None
        elif key in (curses.KEY_BACKSPACE, 127, 8):
            query = query[:-1]
            pos = offset = 0
        elif key >= 0 and key < 256 and chr(key).isprintable() and chr(key).lower() not in ("a", "n"):
            query += chr(key)
            pos = offset = 0


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
    targets = order_modules([m for m in items if m["path"] in selected])
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
