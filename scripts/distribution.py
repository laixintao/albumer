#!/usr/bin/env python3
"""Headless packaging, verification and immutable draft publication for Albumer."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / 'Sources/Albumer/Resources/Info.plist'
REPOSITORY = 'laixintao/albumer'


def run(*args, check=True):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True, text=True, check=check)


def info(path=PLIST):
    return plistlib.loads(path.read_bytes())


def version_tuple(value):
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value):
        raise ValueError('Use a stable SemVer version such as 1.2.3, without a v prefix.')
    return tuple(map(int, value.split('.')))


def validate_metadata(tag, require_tag=True):
    if not tag or not tag.startswith('v'):
        raise ValueError('RELEASE_TAG must be a stable SemVer tag with a v prefix.')
    version_tuple(tag[1:])
    if info()['CFBundleShortVersionString'] != tag[1:]:
        raise ValueError('Tag and source bundle version differ.')
    if not str(info()['CFBundleVersion']).isdigit():
        raise ValueError('Bundle build number must be numeric.')
    notes = ROOT / f'docs/releases/{tag}.md'
    if not notes.is_file() or len(notes.read_text().strip()) < 40:
        raise ValueError('Missing release notes.')
    if not re.search(rf'^## {re.escape(tag[1:])}(?:\s|$)', (ROOT / 'CHANGELOG.md').read_text(), re.M):
        raise ValueError('Missing changelog entry.')
    if require_tag:
        if run('git', 'cat-file', '-t', f'refs/tags/{tag}').stdout.strip() != 'tag':
            raise ValueError('Release tag must be annotated.')
        if run('git', 'rev-parse', f'{tag}^{{commit}}').stdout != run('git', 'rev-parse', 'HEAD').stdout:
            raise ValueError('Checkout does not match the release tag.')
    return tag[1:]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def bundle_digest(app):
    entries = []
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            raise ValueError('Unexpected symlink inside the application bundle.')
        if path.is_file():
            entries.append([path.relative_to(app).as_posix(), path.stat().st_mode & 0o777, sha256(path)])
    return hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest()


def verify_app(app, version):
    metadata = info(app / 'Contents/Info.plist')
    expected = {'CFBundleShortVersionString': version, 'CFBundleVersion': info()['CFBundleVersion'],
                'CFBundleIdentifier': 'app.albumer', 'CFBundleExecutable': 'Albumer',
                'LSMinimumSystemVersion': '15.0'}
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(f'Unexpected bundled {key}: {metadata.get(key)!r}')
    run('codesign', '--verify', '--deep', '--strict', app)
    architectures = set(run('lipo', '-archs', app / 'Contents/MacOS/Albumer').stdout.split())
    if architectures != {'arm64', 'x86_64'}:
        raise ValueError(f'Expected a universal executable, got {architectures}.')
    run(sys.executable, ROOT / 'scripts/audit-release.py', '--app', app)
    return bundle_digest(app)


def artifact_names(version):
    return [f'Albumer-{version}-macos-universal.{extension}' for extension in ['dmg', 'zip']]


def verify_packages(directory, version):
    expected = artifact_names(version)
    manifest = json.loads((directory / 'package-manifest.json').read_text())
    if manifest.get('version') != version or set(manifest.get('files', {})) != set(expected):
        raise ValueError('Unexpected package manifest or incomplete release.')
    if set(path.name for path in directory.glob('*.dmg')) | set(path.name for path in directory.glob('*.zip')) != set(expected):
        raise ValueError('Unexpected package names in artifact directory.')
    for name in expected:
        if sha256(directory / name) != manifest['files'][name]:
            raise ValueError(f'Checksum mismatch: {name}')
    with tempfile.TemporaryDirectory(prefix='albumer-verify-') as temporary:
        temporary = Path(temporary)
        archive = directory / expected[1]
        with zipfile.ZipFile(archive) as zipped:
            for entry in zipped.infolist():
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'Albumer.app':
                    raise ValueError('Unsafe or unexpected ZIP entry.')
                if stat.S_ISLNK(entry.external_attr >> 16):
                    raise ValueError('Unexpected ZIP symlink.')
            if zipped.testzip() is not None:
                raise ValueError('ZIP integrity check failed.')
        extracted = temporary / 'zip'
        run('ditto', '-x', '-k', archive, extracted)
        zip_digest = verify_app(extracted / 'Albumer.app', version)
        mount = temporary / 'dmg'
        mount.mkdir()
        run('hdiutil', 'verify', directory / expected[0])
        mounted = False
        try:
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, directory / expected[0])
            mounted = True
            dmg_digest = verify_app(mount / 'Albumer.app', version)
        finally:
            if mounted:
                run('hdiutil', 'detach', mount)
        if zip_digest != dmg_digest or zip_digest != manifest.get('bundle_digest'):
            raise ValueError('DMG/ZIP applications do not match the tested build.')
    checksums = ''.join(f'{manifest["files"][name]}  {name}\n' for name in expected)
    (directory / 'SHA256SUMS').write_text(checksums)
    print(f'Verified {version}: checksums, signatures, versions, universal architectures and matching app bundles.')
    return expected + ['SHA256SUMS']


def package():
    version = info()['CFBundleShortVersionString']
    version_tuple(version)
    app = ROOT / 'build/Albumer.app'
    digest = verify_app(app, version)
    directory = ROOT / 'dist/releases'
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise ValueError('dist/releases must be empty; preserve or remove the earlier local artifacts first.')
    dmg, archive = [directory / name for name in artifact_names(version)]
    with tempfile.TemporaryDirectory(prefix='albumer-package-') as temporary:
        stage = Path(temporary)
        run('ditto', '--norsrc', '--noextattr', app, stage / 'Albumer.app')
        (stage / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', f'Albumer {version}', '-srcfolder', stage,
            '-format', 'UDZO', '-fs', 'HFS+', dmg)
    run('ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, archive)
    manifest = {'version': version, 'bundle_digest': digest,
                'files': {path.name: sha256(path) for path in [dmg, archive]}}
    (directory / 'package-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify_packages(directory, version)
    print('Packages: dist/releases (application was not launched).')


def release_record(tag, repository):
    result = run('gh', 'api', f'repos/{repository}/releases/tags/{tag}', check=False)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if '(HTTP 404)' in result.stderr:
        return None
    raise RuntimeError('Could not read release state: ' + result.stderr)


def publish(directory, tag):
    version = validate_metadata(tag)
    names = verify_packages(directory, version)
    repository = os.environ.get('GH_REPO', REPOSITORY)
    if repository != REPOSITORY:
        raise ValueError('Publication is restricted to laixintao/albumer.')
    record = release_record(tag, repository)
    if record and not record['draft']:
        raise ValueError('This release is already public. Publish a new version; never replace public assets.')
    if not record:
        run('gh', 'release', 'create', tag, '--repo', repository, '--draft', '--verify-tag',
            '--target', run('git', 'rev-parse', 'HEAD').stdout.strip(), '--title', f'Albumer {version}',
            '--notes-file', ROOT / f'docs/releases/{tag}.md')
    # Only drafts may resume. Do not silently change an asset uploaded by an earlier attempt.
    record = release_record(tag, repository)
    if not record or not record['draft']:
        raise ValueError('Expected a draft before asset upload.')
    existing = {asset['name']: asset for asset in record['assets']}
    if set(existing) - set(names):
        raise ValueError('Draft contains unexpected assets; inspect it before resuming.')
    for name in names:
        if name in existing:
            digest = existing[name].get('digest')
            if digest != 'sha256:' + sha256(directory / name):
                raise ValueError(f'Draft asset differs from verified package: {name}. Inspect the draft; no assets replaced.')
            continue
        run('gh', 'release', 'upload', tag, directory / name, '--repo', repository)
    final = release_record(tag, repository)
    if not final or not final['draft'] or {asset['name'] for asset in final['assets']} != set(names):
        raise ValueError('Draft asset set is incomplete or release state changed.')
    for asset in final['assets']:
        if asset['state'] != 'uploaded' or asset.get('digest') != 'sha256:' + sha256(directory / asset['name']):
            raise ValueError('Uploaded asset integrity check failed; draft left unpublished.')
    run('gh', 'release', 'edit', tag, '--repo', repository, '--draft=false', '--latest')
    print(f'Published https://github.com/{repository}/releases/tag/{tag}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate', 'package', 'verify', 'publish'])
    args = parser.parse_args()
    tag = os.environ.get('RELEASE_TAG', '')
    directory = Path(os.environ.get('ARTIFACT_DIR') or ROOT / 'dist/releases').resolve()
    if args.command == 'validate':
        validate_metadata(tag)
        print(f'Validated release metadata for {tag}.')
    elif args.command == 'package':
        package()
    elif args.command == 'verify':
        verify_packages(directory, validate_metadata(tag))
    else:
        publish(directory, tag)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'Distribution stopped: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
