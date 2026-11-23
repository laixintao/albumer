#!/usr/bin/env python3
"""Prepare and atomically push the next stable release; Actions publishes the packages."""
from datetime import date
import os
from pathlib import Path
import re
import subprocess
import sys

from distribution import info, validate_metadata, version_tuple

ROOT = Path(__file__).resolve().parents[1]


def git(*args, check=True):
    return subprocess.run(['git', *args], cwd=ROOT, text=True, capture_output=True, check=check)


def notes(version, changes):
    return f'''# Albumer {version}

Native macOS album management and playback control for Spotify.

## Changes

{changes}

## Install

Download `Albumer-{version}-macos-universal.dmg` and drag Albumer into Applications,
or extract the ZIP. Both packages support Apple Silicon and Intel on macOS 15+.

Homebrew: `brew install --cask laixintao/tap/albumer` (available after the tap syncs).
Spotify requires your own developer Client ID, an eligible Premium account and an
available Connect device. See the repository README for setup and API access limits.

The app is ad hoc signed and is not notarized by Apple. If macOS blocks an app you
trust, follow [Apple's first-launch instructions](https://support.apple.com/en-us/102445).
The cask does not disable Gatekeeper or remove quarantine attributes.

Checksums are in `SHA256SUMS`. Verify provenance with:
`gh attestation verify Albumer-{version}-macos-universal.dmg --repo laixintao/albumer`.

Original code and preview assets use MIT. Spotify branding/content remains subject
to its own terms. Read PRIVACY.md, TERMS.md and THIRD_PARTY_NOTICES.md before connecting.

## 中文

原生 macOS Spotify 专辑管理客户端，支持 Apple Silicon、Intel，要求 macOS 15+。
下载 DMG 后拖入「应用程序」，或解压 ZIP；也可在 tap 同步后通过上述 Homebrew 命令安装。
需要自己的 Spotify Client ID、符合要求的 Premium 账号及可用播放设备。
应用未经过 Apple 公证；如首次打开被阻止，请按上方 Apple 指引操作。
附件包含 SHA-256 校验值及 GitHub 构建来源证明。变更列表保留提交标题原文。
'''


def main():
    if git('status', '--porcelain', '--untracked-files=all').stdout:
        raise ValueError('Commit or stash changes first; the worktree must be clean.')
    if git('branch', '--show-current').stdout.strip() != 'main':
        raise ValueError('Run make release from main in the public repository.')
    current = info()['CFBundleShortVersionString']
    major, minor, patch = version_tuple(current)
    version = os.environ.get('VERSION') or f'{major}.{minor}.{patch + 1}'
    if version_tuple(version) <= (major, minor, patch):
        raise ValueError(f'Version must be newer than {current}.')
    tag = f'v{version}'
    if git('show-ref', '--verify', '--quiet', f'refs/tags/{tag}', check=False).returncode == 0:
        raise ValueError(f'{tag} exists locally. Retry its push instead of preparing another release.')
    # All remote checks precede edits. A failed fetch or divergent branch leaves files untouched.
    git('fetch', '--quiet', 'origin', 'refs/heads/main', '--tags')
    remote = git('rev-parse', 'FETCH_HEAD').stdout.strip()
    if git('merge-base', '--is-ancestor', remote, 'HEAD', check=False).returncode:
        raise ValueError('Remote main has changes not present locally; pull --ff-only first.')
    if git('ls-remote', '--tags', 'origin', f'refs/tags/{tag}').stdout.strip():
        raise ValueError(f'{tag} already exists on origin; published tags are immutable.')
    base = f'refs/tags/v{current}'
    revision = f'{base}..HEAD' if git('rev-parse', '--verify', base, check=False).returncode == 0 else 'HEAD'
    commits = git('log', '--no-merges', '--format=%h%x09%s', revision).stdout.splitlines()
    if not commits:
        raise ValueError('No new commits since the current release.')
    changes = []
    for line in commits:
        sha, subject = line.split('\t', 1)
        subject = re.sub(r'([\\`*_\[\]<>])', r'\\\1', subject)
        changes.append(f'- {subject} (`{sha}`)')
    changes = '\n'.join(changes)
    plist = ROOT / 'Sources/Albumer/Resources/Info.plist'
    text = plist.read_text()
    for key, value in [('CFBundleShortVersionString', version), ('CFBundleVersion', str(int(info()['CFBundleVersion']) + 1))]:
        text, count = re.subn(rf'(<key>{key}</key>\s*<string>)[^<]*(</string>)',
                             lambda match: match[1] + value + match[2], text)
        if count != 1:
            raise ValueError(f'Expected one {key} in Info.plist.')
    plist.write_text(text)
    note_path = ROOT / f'docs/releases/{tag}.md'
    note_path.parent.mkdir(parents=True, exist_ok=True)
    if not note_path.exists():
        note_path.write_text(notes(version, changes))
    changelog = ROOT / 'CHANGELOG.md'
    content = changelog.read_text()
    if not re.search(rf'^## {re.escape(version)}(?:\s|$)', content, re.M):
        heading, _, rest = content.partition('\n')
        changelog.write_text(f'{heading}\n\n## {version} — {date.today().isoformat()}\n\n'
                             f'[Release notes](docs/releases/{tag}.md)\n\n{changes}\n{rest}')
    validate_metadata(tag, require_tag=False)
    git('add', '--', str(plist.relative_to(ROOT)), 'CHANGELOG.md', str(note_path.relative_to(ROOT)))
    git('commit', '-m', f'Release {tag}')
    git('tag', '-a', tag, '-m', f'Albumer {version}')
    push = ['push', '--atomic', 'origin', 'HEAD:refs/heads/main', f'refs/tags/{tag}']
    result = git(*push, check=False)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        print('Release commit and tag retained. Retry exactly:\n  git ' + ' '.join(push)
              + '\nDo not rerun make release for the same version.', file=sys.stderr)
        return 1
    print(f'Pushed {tag}. Actions will build, test, verify, attest and publish.\n'
          'https://github.com/laixintao/albumer/actions/workflows/release.yml\n'
          f'Release after CI: https://github.com/laixintao/albumer/releases/tag/{tag}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Release stopped: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
