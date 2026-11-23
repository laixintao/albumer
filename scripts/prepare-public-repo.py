#!/usr/bin/env python3
"""Export HEAD ancestry with original authors, excluding legacy preview assets.

The source repository, its refs, and its working tree are never modified.
A final snapshot commit includes current tracked and nonignored source files.
Only permitted objects are copied; there are no alternates or original reflogs.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

from importlib.util import spec_from_file_location, module_from_spec
ROOT = Path(__file__).resolve().parents[1]
spec = spec_from_file_location('release_audit', ROOT / 'scripts/audit-release.py')
audit = module_from_spec(spec)
spec.loader.exec_module(audit)


def git(repo, *args, data=None, env=None):
    return subprocess.check_output(['git', '-C', str(repo), *args], input=data, env=env)


def excluded(name, oid):
    if name.startswith('Sources/Albumer/Resources/Fixtures/'):
        if name.endswith('.jpg'):
            return True
        if name.endswith('/albums.json'):
            catalog = json.loads(git(ROOT, 'cat-file', 'blob', oid))
            return not all(item.get('id', '').startswith('preview-') for item in catalog)
    return name.startswith('docs/screenshots/') or name == 'scripts/fetch-preview-assets.py'


def metadata(commit):
    raw = git(ROOT, 'cat-file', 'commit', commit)
    header, _, message = raw.partition(b'\n\n')
    env = os.environ.copy()
    for role in ['author', 'committer']:
        identity = next(line[len(role)+1:] for line in header.splitlines() if line.startswith(role.encode() + b' '))
        match = re.fullmatch(rb'(.*) <([^<>]*)> (\d+ [+-]\d{4})', identity)
        if match is None:
            raise RuntimeError('Unsupported commit identity')
        name, email, date = (part.decode() for part in match.groups())
        env.update({f'GIT_{role.upper()}_NAME': name, f'GIT_{role.upper()}_EMAIL': email, f'GIT_{role.upper()}_DATE': date})
    return env, message


def main():
    subprocess.run(['python3', str(ROOT / 'scripts/audit-release.py')], check=True)
    output = ROOT / 'build/public'
    output.mkdir(parents=True, exist_ok=True)
    package = Path(tempfile.mkdtemp(prefix='Albumer-', dir=output))
    repo = package / 'Albumer'
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
    blobs = {}

    def copy_blob(oid):
        if oid not in blobs:
            blobs[oid] = git(repo, 'hash-object', '-w', '--stdin', data=git(ROOT, 'cat-file', 'blob', oid)).decode().strip()
        return blobs[oid]

    def tree(entries):
        root = {}
        for name, mode, oid in entries:
            parts = name.split('/')
            directory = root
            for part in parts[:-1]:
                directory = directory.setdefault(part, {})
            directory[parts[-1]] = (mode, oid)
        def write(directory):
            records = []
            for name, value in sorted(directory.items()):
                if isinstance(value, dict):
                    mode, kind, oid = '040000', 'tree', write(value)
                else:
                    mode, oid = value
                    kind = 'blob'
                records.append(f'{mode} {kind} {oid}\t{name}\0'.encode())
            return git(repo, 'mktree', '-z', data=b''.join(records)).decode().strip()
        return write(root)

    mapping = {}
    commits = git(ROOT, 'rev-list', '--reverse', '--topo-order', 'HEAD').decode().splitlines()
    for commit in commits:
        entries = []
        for record in git(ROOT, 'ls-tree', '-r', '-z', commit).split(b'\0'):
            if not record:
                continue
            info, name = record.split(b'\t', 1)
            mode, kind, oid = info.decode().split()
            name = name.decode()
            if excluded(name, oid):
                continue
            if kind != 'blob' or mode not in ['100644', '100755']:
                raise RuntimeError(f'Unsupported historical entry: {name}')
            entries.append((name, mode, copy_blob(oid)))
        parents = git(ROOT, 'show', '-s', '--format=%P', commit).decode().split()
        args = ['commit-tree', tree(entries)]
        for parent in parents:
            args += ['-p', mapping[parent]]
        env, message = metadata(commit)
        mapping[commit] = git(repo, *args, data=message, env=env).decode().strip()

    files = list(audit.source_files(ROOT))
    entries = [(name, '100755' if path.stat().st_mode & 0o111 else '100644',
                git(repo, 'hash-object', '-w', '--stdin', data=path.read_bytes()).decode().strip()) for name, path in files]
    env, _ = metadata(commits[-1])
    now = datetime.now(timezone.utc).strftime('%s +0000')
    env['GIT_AUTHOR_DATE'] = now
    env['GIT_COMMITTER_DATE'] = now
    latest = git(repo, 'commit-tree', tree(entries), '-p', mapping[commits[-1]],
                 data=b'Prepare MIT release and fix album identity for single releases\n', env=env).decode().strip()
    git(repo, 'update-ref', 'refs/heads/main', latest)
    git(repo, 'reset', '--hard', 'HEAD')
    subprocess.run(['python3', str(ROOT / 'scripts/audit-release.py'), '--repo', str(repo), '--history'], check=True)
    git(repo, 'fsck', '--full', '--no-reflogs')
    git(repo, 'bundle', 'create', str(package / 'Albumer-public.bundle'), '--all')
    with zipfile.ZipFile(package / 'Albumer-source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, _ in files:
            archive.write(repo / name, 'Albumer/' + name)
    (package / 'history-map.json').write_text(json.dumps(mapping, indent=2) + '\n')
    print(f'Public repository: {repo.relative_to(ROOT)}')
    print(f'Preserved {len(commits)} historical commits plus one release snapshot; authors retained.')
    print('No remote configured. Original repository/history unchanged.')


if __name__ == '__main__':
    main()
