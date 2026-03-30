#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 robotnix contributors
# SPDX-License-Identifier: MIT

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple


MISMATCH_RE = re.compile(
    r"hash mismatch in fixed-output derivation '([^']+)':\s+"
    r"specified:\s+(\S+)\s+"
    r"got:\s+(\S+)",
    re.MULTILINE,
)


def run(cmd: List[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def run_logged(cmd: List[str], timeout: Optional[int] = None) -> Tuple[int, str, bool]:
    # Avoid deadlocks from huge nix-build output by writing directly to a file.
    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as logf:
        proc = subprocess.Popen(
            cmd,
            text=True,
            stdout=logf,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
        logf.flush()
        logf.seek(0)
        return proc.returncode, logf.read(), timed_out


def extract_mismatches(output: str) -> List[Tuple[str, str, str]]:
    return [(m.group(1), m.group(2), m.group(3)) for m in MISMATCH_RE.finditer(output)]


def dedupe_mismatches(mismatches: List[Tuple[str, str, str]]) -> List[Tuple[str, str, str]]:
    by_drv: Dict[str, Tuple[str, str, str]] = {}
    for drv_path, specified, got_hash in mismatches:
        by_drv[drv_path] = (drv_path, specified, got_hash)
    return list(by_drv.values())


def drv_url(drv_path: str) -> Optional[str]:
    proc = run(["nix", "derivation", "show", drv_path])
    if proc.returncode != 0:
        return None
    data = json.loads(proc.stdout)
    drv = data.get(drv_path)
    if not drv:
        return None
    attrs = drv.get("structuredAttrs", {})
    urls = attrs.get("urls", [])
    if not urls:
        return None
    return urls[0]


def drv_urls(drv_paths: List[str]) -> Dict[str, str]:
    if not drv_paths:
        return {}

    proc = run(["nix", "derivation", "show", *drv_paths])
    if proc.returncode != 0:
        return {}

    data = json.loads(proc.stdout)
    out: Dict[str, str] = {}
    for drv_path in drv_paths:
        drv = data.get(drv_path)
        if not drv:
            continue
        attrs = drv.get("structuredAttrs", {})
        urls = attrs.get("urls", [])
        if urls:
            out[drv_path] = urls[0]
    return out


def has_http_429(output: str) -> bool:
    return (
        "curl: (22) The requested URL returned error: 429" in output
        or "HTTP error 429" in output
    )


def project_path_from_url(url: str) -> Optional[str]:
    prefix = "https://android.googlesource.com/platform/"
    if not url.startswith(prefix):
        return None
    rest = url[len(prefix) :]
    marker = "/+archive/"
    if marker not in rest:
        return None
    return rest.split(marker, 1)[0]


def parse_corrected_hashes_block(text: str) -> Tuple[int, int, Dict[str, str]]:
    start = text.find("correctedArchiveHashes = {")
    if start == -1:
        raise RuntimeError("Could not find `correctedArchiveHashes` block")
    end = text.find("};", start)
    if end == -1:
        raise RuntimeError("Could not find end of `correctedArchiveHashes` block")

    block = text[start : end + 2]
    entries: Dict[str, str] = {}
    for line in block.splitlines():
        m = re.match(r'\s*"([^"]+)"\s*=\s*"([^"]+)";\s*$', line)
        if m:
            entries[m.group(1)] = m.group(2)

    return start, end + 2, entries


def render_corrected_hashes_block(entries: Dict[str, str]) -> str:
    lines = ["  correctedArchiveHashes = {"]
    for key in sorted(entries.keys()):
        lines.append(f'    "{key}" = "{entries[key]}";')
    lines.append("  };")
    return "\n".join(lines)


def update_corrected_hash(
    nix_file: Path, project_path: str, new_hash: str, verbose: bool
) -> bool:
    text = nix_file.read_text()
    start, end, entries = parse_corrected_hashes_block(text)
    old_hash = entries.get(project_path)
    if old_hash == new_hash:
        if verbose:
            print(f"unchanged: {project_path} already {new_hash}")
        return False

    entries[project_path] = new_hash
    new_block = render_corrected_hashes_block(entries)
    new_text = text[:start] + new_block + text[end:]
    nix_file.write_text(new_text)

    if verbose:
        if old_hash is None:
            print(f"added:   {project_path} -> {new_hash}")
        else:
            print(f"updated: {project_path} {old_hash} -> {new_hash}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run DerpFest build, detect AOSP archive hash mismatches, and update "
            "correctedArchiveHashes in flavors/derpfest/default.nix"
        )
    )
    parser.add_argument(
        "--nix-file",
        default="flavors/derpfest/default.nix",
        help="Path to DerpFest nix file (default: %(default)s)",
    )
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=20,
        help="Maximum build/update iterations (default: %(default)s)",
    )
    parser.add_argument(
        "--configuration",
        default='{ device = "enchilada"; flavor = "derpfest"; flavorVersion = "16"; release = "bp2a"; stateVersion = "3"; }',
        help="Nix configuration attrset string for nix-build --arg configuration",
    )
    parser.add_argument(
        "--attr",
        default="img",
        help="Build attribute for nix-build -A (default: %(default)s)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print extra progress details",
    )
    parser.add_argument(
        "--keep-going",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Pass --keep-going to nix-build to collect more failures per run (default: %(default)s)",
    )
    parser.add_argument(
        "--max-rate-limit-retries",
        type=int,
        default=6,
        help="Retries when build fails only due to HTTP 429 (default: %(default)s)",
    )
    parser.add_argument(
        "--rate-limit-sleep-seconds",
        type=int,
        default=30,
        help="Base sleep before retry after HTTP 429 (default: %(default)s)",
    )
    parser.add_argument(
        "--build-timeout-seconds",
        type=int,
        default=0,
        help="Kill nix-build after this many seconds but still parse collected logs (0 disables timeout)",
    )
    args = parser.parse_args()

    nix_file = Path(args.nix_file)
    if not nix_file.exists():
        print(f"nix file not found: {nix_file}", file=sys.stderr)
        return 2

    rate_limit_retries = 0
    for i in range(1, args.max_iterations + 1):
        print(f"[{i}/{args.max_iterations}] nix-build -A {args.attr}")
        cmd = [
            "nix-build",
            "./default.nix",
            "--arg",
            "configuration",
            args.configuration,
            "-A",
            args.attr,
        ]
        if args.keep_going:
            cmd.append("--keep-going")
        timeout = args.build_timeout_seconds if args.build_timeout_seconds > 0 else None
        code, output, timed_out = run_logged(cmd, timeout=timeout)
        if timed_out:
            print(
                f"nix-build timed out after {args.build_timeout_seconds}s; parsing partial logs",
                file=sys.stderr,
            )
        if code == 0:
            print("build succeeded")
            tail = "\n".join(output.strip().splitlines()[-20:])
            if tail:
                print(tail)
            return 0

        mismatches = dedupe_mismatches(extract_mismatches(output))
        if not mismatches:
            if has_http_429(output) and rate_limit_retries < args.max_rate_limit_retries:
                rate_limit_retries += 1
                sleep_for = args.rate_limit_sleep_seconds * rate_limit_retries
                print(
                    f"rate limited by android.googlesource.com (HTTP 429), "
                    f"retry {rate_limit_retries}/{args.max_rate_limit_retries} in {sleep_for}s",
                    file=sys.stderr,
                )
                time.sleep(sleep_for)
                continue
            if timed_out:
                print(
                    "build timed out with no hash mismatch detected; increase --build-timeout-seconds",
                    file=sys.stderr,
                )
                return 124
            print("build failed with no hash mismatch detected; stopping", file=sys.stderr)
            sys.stderr.write(output)
            return code
        rate_limit_retries = 0

        urls_by_drv = drv_urls([drv_path for drv_path, _specified, _got_hash in mismatches])
        changed_any = False
        for drv_path, _specified, got_hash in mismatches:
            url = urls_by_drv.get(drv_path)
            if not url:
                url = drv_url(drv_path)
            if not url:
                print(f"warning: unable to resolve URL for {drv_path}", file=sys.stderr)
                continue
            project_path = project_path_from_url(url)
            if not project_path:
                if args.verbose:
                    print(f"skipping non-AOSP URL: {url}")
                continue
            changed = update_corrected_hash(nix_file, project_path, got_hash, args.verbose)
            changed_any = changed_any or changed

        if not changed_any:
            print("no correctedArchiveHashes updates were applied; stopping", file=sys.stderr)
            return 1

    print(f"reached max iterations ({args.max_iterations})", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        raise SystemExit(130)
