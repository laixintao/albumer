#!/usr/bin/env python3
"""Read-only release checks; reports locations/categories, never credential values."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'AWS access key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'GitHub credential': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'personal build path': re.compile(rb'/Users/[A-Za-z0-9._-]+/'),
    'credential literal': re.compile(rb'''["'](?:access_token|refresh_token|client_secret)["']\s*:\s*["']([A-Za-z0-9_./+=-]{24,})["']''', re.I),
}


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])


def source_files(repo):
    names = git(repo, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')
    for raw in sorted(set(names)):
        if not raw:
            continue
        name = raw.decode()
        path = repo / name
        if path.is_symlink():
            raise RuntimeError(f'Symlink requires review: {name}')
        if path.is_file():
            yield name, path


def audit(data, name, findings):
    for category, pattern in PATTERNS.items():
        match = pattern.search(data)
        if match:
            # Repeated test fixture strings are not credentials.
            if category == 'credential literal' and len(set(match.group(1))) < 6:
                continue
            findings.add((name, category))
    if ('Resources/Fixtures/' in name and name.endswith('.jpg')) or name.removeprefix('history:').startswith('docs/screenshots/'):
        findings.add((name, 'legacy third-party preview asset'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--history', action='store_true')
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    findings = set()
    count = 0
    if args.app:
        for path in args.app.rglob('*'):
            if path.is_file():
                audit(path.read_bytes(), path.relative_to(args.app).as_posix(), findings)
                count += 1
        for name in ['LICENSE', 'PRIVACY.md', 'TERMS.md', 'THIRD_PARTY_NOTICES.md']:
            if not (args.app / 'Contents/Resources' / name).is_file():
                findings.add((name, 'missing bundled legal document'))
    else:
        for name, path in source_files(args.repo):
            audit(path.read_bytes(), name, findings)
            count += 1
        if args.history:
            for line in git(args.repo, 'rev-list', '--objects', '--all').splitlines():
                oid, _, name = line.partition(b' ')
                if git(args.repo, 'cat-file', '-t', oid.decode()).strip() == b'blob':
                    audit(git(args.repo, 'cat-file', 'blob', oid.decode()), 'history:' + name.decode(), findings)
                    count += 1
    for name, category in sorted(findings):
        print(f'REVIEW: {name}: {category}')
    print(f'Checked {count} files/blobs; {len(findings)} finding(s). Values are not printed.')
    print('Pattern checks do not prove absence of secrets or grant third-party content rights.')
    return bool(findings)


if __name__ == '__main__':
    sys.exit(main())
