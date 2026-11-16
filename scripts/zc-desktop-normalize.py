#!/usr/bin/env python3
"""Normalize Electron/WebKit/Gecko desktop entries to go through zc-launch.

Noctalia already passes every launch through launch_apps_custom_command, so
this is a safety net for launches outside Noctalia (gtk-launch, niri keybinds,
other launchers) and for entries installed by packages that are not aware of
zc-run.  It only rewrites entries whose real binary classifies as chromium,
webkit or gecko; native/unknown/terminal entries are left untouched.

Usage:
  zc-desktop-normalize.py --dry-run
  zc-desktop-normalize.py --apply
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import stat
import subprocess
import sys
import time

CLASSIFIERS = [
    "/opt/mali-stack/current/lib/zc-run/zc-classify",
    "/usr/local/lib/zc-run/zc-classify",
]
ZC_LAUNCH = "/usr/local/bin/zc-launch"
WRAPPER_PATHS = {
    "/usr/local/bin/zc-run",
    "/usr/local/bin/zc-launch",
    "/usr/local/bin/google-chrome",
    "/usr/local/bin/google-chrome-stable",
    "/usr/local/bin/kimi-code",
    "/usr/local/bin/dbx",
    "/usr/local/bin/dbx-dmabuf",
    "/usr/local/bin/zen",
    "/usr/local/bin/zen-browser",
    "/usr/bin/magpie",
    "/usr/local/bin/magpie",
    "/usr/local/bin/noctalia-dt",
    "/usr/local/bin/gpu-app-bridge",
}
TARGET_CLASSES = {"chromium", "webkit", "gecko"}
DESKTOP_DIRS = [
    "/usr/share/applications",
    "/usr/local/share/applications",
    "/home/colle/.local/share/applications",
]
LOG = "/var/log/zc-desktop-normalize.log"


def log(message: str) -> None:
    line = f"{time.strftime('%F %T%z')} {message}"
    print(line)
    try:
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def command_from_exec(exec_value: str) -> tuple[str | None, str]:
    try:
        argv = shlex.split(exec_value, posix=True)
    except ValueError:
        return None, ""
    if not argv:
        return None, ""
    index = 0
    if argv[0] == "env":
        index = 1
        while index < len(argv):
            token = argv[index]
            if "=" in token and not token.startswith("-"):
                index += 1
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
    if index >= len(argv):
        return None, ""
    command = argv[index]
    resolved = command
    if "/" not in command:
        resolved = shutil.which(command) or ""
    return (resolved or None), cmd_display(command)


def cmd_display(command: str) -> str:
    return command


def classify(resolved: str) -> str:
    classifier = next(
        (path for path in CLASSIFIERS if os.path.isfile(path) and os.access(path, os.X_OK)),
        None,
    )
    if classifier is None:
        return "unknown"
    try:
        result = subprocess.run(
            [classifier, resolved],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return result.stdout.strip().splitlines()[0] if result.stdout.strip() else "unknown"


def script_has_wrapper(resolved: str) -> bool:
    try:
        with open(resolved, "rb") as handle:
            head = handle.read(4096)
    except OSError:
        return False
    return b"zc-run" in head or b"zc-launch" in head


def normalize_exec(exec_value: str) -> tuple[bool, str]:
    resolved, _ = command_from_exec(exec_value)
    if resolved is None or not os.path.exists(resolved):
        return False, ""
    if resolved in WRAPPER_PATHS:
        return False, ""
    if os.path.isfile(resolved) and script_has_wrapper(resolved):
        return False, ""
    if classify(resolved) not in TARGET_CLASSES:
        return False, ""
    stripped = exec_value.lstrip()
    if stripped.startswith(ZC_LAUNCH + " ") or stripped == ZC_LAUNCH:
        return False, ""
    return True, f"{ZC_LAUNCH} {exec_value}"


def rewrite_file(
    path: str,
    changes: list[tuple[int, str, str]],
    apply: bool,
    backup: bool = True,
) -> None:
    if not changes:
        return
    if not apply:
        for line_no, old, new in changes:
            log(f"DRY {path}:{line_no}: {old} -> {new}")
        return

    original = os.stat(path)
    if backup:
        backup_path = path + ".zc-launch.bak"
        if not os.path.exists(backup_path):
            shutil.copy2(path, backup_path)

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        lines = handle.readlines()
    for line_no, _old, new in changes:
        lines[line_no - 1] = new + "\n"
    tmp = path + ".zc-launch.tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.writelines(lines)
    shutil.copystat(path, tmp, follow_symlinks=True)
    os.replace(tmp, path)
    try:
        os.chown(path, original.st_uid, original.st_gid)
    except OSError:
        pass
    for line_no, old, new in changes:
        log(f"APPLY {path}:{line_no}: {old} -> {new}")


def process_file(path: str, apply: bool, backup: bool) -> int:
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
            lines = handle.readlines()
    except OSError as error:
        log(f"SKIP {path}: {error}")
        return 0
    changes: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if not line.startswith("Exec="):
            continue
        exec_value = line[len("Exec="):].rstrip("\n")
        changed, new_value = normalize_exec(exec_value)
        if changed:
            changes.append((index + 1, line.rstrip("\n"), f"Exec={new_value}"))
    rewrite_file(path, changes, apply, backup)
    return len(changes)


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true", help="rewrite desktop files")
    group.add_argument("--dry-run", action="store_true", help="print proposed changes (default)")
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="do not keep .zc-launch.bak files (used at image build time)",
    )
    args = parser.parse_args()
    apply = bool(args.apply)
    backup = not bool(args.no_backup)

    total = 0
    for directory in DESKTOP_DIRS:
        if not os.path.isdir(directory):
            continue
        for entry in sorted(os.listdir(directory)):
            if not entry.endswith(".desktop"):
                continue
            total += process_file(os.path.join(directory, entry), apply, backup)
    log(f"done changes={total} mode={'apply' if apply else 'dry-run'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
