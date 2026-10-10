#!/usr/bin/env python3
"""Conservative publication guard. Reports locations/categories, never secret values.
This supplements review and GitHub secret scanning; it is not proof of no secrets.
"""
import argparse
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "provider credential": rb"(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}|xai-[A-Za-z0-9_-]{24,}|AIza[0-9A-Za-z_-]{30,})",
    "GitHub credential": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})",
    "AWS credential identifier": rb"(?:AKIA|ASIA)[A-Z0-9]{16}",
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "JWT": rb"eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}",
    "local machine path": rb"/(?:Users|home)/[A-Za-z0-9_.-]+/",
}
EMAIL = re.compile(rb"[A-Za-z0-9_.+%-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
SAFE_DOMAINS = {b"example.com", b"example.org", b"example.net", b"example.test", b"users.noreply.github.com"}
SAFE_EMAILS = {b"noreply@github.com"}  # GitHub-generated commit metadata only.
PRIVATE_NAMES = {"accounts.json", "auth.json", ".credentials.json", ".env", ".DS_Store"}
PRIVATE_PARTS = {"CodexProfiles", "ClaudeProfiles", "ClaudeFeeds", "ClaudeConnections", "node_modules", ".build", ".swiftpm"}

def issues(data):
    result = {name for name, pattern in PATTERNS.items() if re.search(pattern, data)}
    if any(m.group(1).lower() not in SAFE_DOMAINS and m.group(0).lower() not in SAFE_EMAILS for m in EMAIL.finditer(data)):
        result.add("non-example email address")
    return sorted(result)

def git(*args):
    return subprocess.check_output(["git", *args])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--history", action="store_true", help="Also inspect all reachable Git blobs and commit/tag messages")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert not issues(b"fixture@example.com 12345+author@users.noreply.github.com noreply@github.com")
        assert "non-example email address" in issues(b"private-person@" + b"github.com")
        assert "provider credential" in issues(b"sk-" + b"proj-" + b"A" * 40)
        assert "GitHub credential" in issues(b"ghp_" + b"B" * 40)
        assert "private key" in issues(b"-----BEGIN " + b"PRIVATE KEY-----")
        assert "non-example email address" in issues(b"person@" + b"real-mail.invalid")
        assert "local machine path" in issues(b"/Users/" + b"fixture/private")
        print("Privacy guard self-test passed.")
        return 0
    root = pathlib.Path(git("rev-parse", "--show-toplevel").decode().strip())
    failures = []
    names = git("ls-files", "-z").decode().split("\0")
    for name in filter(None, names):
        path = pathlib.PurePosixPath(name)
        if path.name in PRIVATE_NAMES or path.name.startswith(".env.") or PRIVATE_PARTS.intersection(path.parts):
            failures.append((name, "private/generated file"))
        local = root / name
        if local.is_symlink():
            failures.append((name, "symlink in publication source"))
        elif local.is_file():
            failures.extend((name, category) for category in issues(local.read_bytes()))
    checked = 0
    if args.history:
        for entry in git("rev-list", "--objects", "--all").decode().splitlines():
            oid = entry.split(" ", 1)[0]
            kind = git("cat-file", "-t", oid).strip()
            if kind not in (b"blob", b"commit", b"tag"):
                continue
            checked += 1
            failures.extend(("Git object " + oid, category) for category in issues(git("cat-file", "-p", oid)))
    if failures:
        for location, category in failures:
            print(f"Privacy check failed: {location}: {category}", file=sys.stderr)
        return 1
    print(f"Privacy check passed: tracked files" + (f" and {checked} historical objects." if args.history else "."))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
