#!/usr/bin/env python3
"""Originalen Release-Guard mit simulierten GitHub-Antworten ausführen."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
workflow = json.loads(subprocess.check_output(
    ['ruby', '-r', 'yaml', '-r', 'json', '-e',
     'puts JSON.generate(YAML.load_file(ARGV[0]))',
     str(repo / '.github/workflows/publish-appcast.yml')], text=True))
steps = workflow['jobs']['appcast']['steps']
guard = next(step['run'] for step in steps if step['name'] == 'Verify latest stable release')
with tempfile.TemporaryDirectory(prefix='vicious-sparkle-workflow-') as temporary:
    root = Path(temporary)
    (root / 'VERSION').write_text('1.9.26\n')
    gh = root / 'gh'
    gh.write_text('''#!/bin/bash
set -eu
case "$1" in
  release) printf '%s\\n' "$TEST_RELEASE_STATE" ;;
  api) printf '%s\\n' "$TEST_LATEST_TAG" ;;
  *) exit 1 ;;
esac
''')
    git = root / 'git'
    git.write_text('''#!/bin/bash
set -eu
if [[ "$2" == HEAD ]]; then
  printf '%s\\n' "$TEST_HEAD"
else
  printf '%s\\n' release-commit
fi
''')
    gh.chmod(0o755)
    git.chmod(0o755)
    base = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                RELEASE_TAG='v1.9.26', GITHUB_REPOSITORY='example/player',
                TEST_RELEASE_STATE='false\tfalse', TEST_LATEST_TAG='v1.9.26',
                TEST_HEAD='release-commit')
    cases = [
        ('latest stable release', {}, True),
        ('draft', {'TEST_RELEASE_STATE': 'true\tfalse'}, False),
        ('prerelease', {'TEST_RELEASE_STATE': 'false\ttrue'}, False),
        ('older release', {'TEST_LATEST_TAG': 'v1.9.27'}, False),
        ('wrong checkout', {'TEST_HEAD': 'other-commit'}, False),
        ('wrong version', {'RELEASE_TAG': 'v1.9.25'}, False),
        ('malformed tag', {'RELEASE_TAG': 'v1.9.26-rc1'}, False),
        ('missing release state', {'TEST_RELEASE_STATE': ''}, False),
    ]
    for name, changes, succeeds in cases:
        result = subprocess.run(['bash', '-c', guard], cwd=root,
                                env=dict(base, **changes), capture_output=True)
        assert (result.returncode == 0) == succeeds, name
    for step in steps:
        if 'run' in step:
            subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)
print(f'{len(cases)} Release-Guard-Prüfungen und Workflow-Syntax bestanden.')
