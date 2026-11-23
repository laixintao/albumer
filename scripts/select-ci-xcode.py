#!/usr/bin/env python3
"""Select an installed SDK with Liquid Glass support, without changing xcode-select."""
import os
from pathlib import Path
import re
import subprocess

candidates = []
for app in Path('/Applications').glob('Xcode*.app'):
    developer = app / 'Contents/Developer'
    result = subprocess.run(['xcodebuild', '-version'], env=dict(os.environ, DEVELOPER_DIR=str(developer)),
                            capture_output=True, text=True)
    match = re.search(r'Xcode (\d+(?:\.\d+)*)', result.stdout)
    if result.returncode == 0 and match:
        version = tuple(map(int, match[1].split('.')))
        if version[0] >= 26:
            candidates.append((version, developer))
if not candidates:
    raise SystemExit('An installed Xcode 26+ SDK is required to compile Liquid Glass controls.')
version, developer = max(candidates)
with open(os.environ['GITHUB_ENV'], 'a') as output:
    output.write(f'DEVELOPER_DIR={developer}\n')
print('Selected Xcode ' + '.'.join(map(str, version)))
