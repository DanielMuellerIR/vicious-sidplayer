#!/usr/bin/env python3
"""Release-Gates mit temporaeren Zielen und abgefangenen Systembefehlen pruefen."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
real_git = shutil.which('git')
with tempfile.TemporaryDirectory(prefix='vicious-release-guards-') as temporary:
    root = Path(temporary)
    commands = root / 'commands'
    commands.mkdir()
    calls = root / 'calls.jsonl'
    env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'], VSP_TEST_CALLS=str(calls), VSP_TEST_REAL_GIT=real_git)
    stub = '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['VSP_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps([name] + args) + '\\n')
if name == 'git' and (not args or args[0] != 'push'):
    sys.exit(subprocess.call([os.environ['VSP_TEST_REAL_GIT']] + args))
if name == 'codesign' and args[-1] == os.environ.get('VSP_TEST_INVALID_APP'):
    sys.exit(1)
'''
    for name in ['git', 'hdiutil', 'codesign', 'spctl', 'xcrun']:
        path = commands / name
        path.write_text(stub)
        path.chmod(0o755)
    def recorded():
        return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
    def clear():
        calls.write_text('')

    # Frueher warf der EXIT-Trap ein fremdes gleichnamiges Volume aus.
    dmg_root = root / 'dmg'
    (dmg_root / 'build').mkdir(parents=True)
    old = dmg_root / 'build/Vicious SID Player.dmg'
    old.write_bytes(b'previous-release')
    shutil.copy(repo / 'build_dmg.sh', dmg_root)
    result = subprocess.run(['bash', 'build_dmg.sh'], cwd=dmg_root, env=env, capture_output=True)
    assert result.returncode != 0
    assert old.read_bytes() == b'previous-release'
    assert not [call for call in recorded() if call[0] == 'hdiutil']
    assert not list((dmg_root / 'build').glob('.dmg-build.*'))
    clear()

    public = root / 'public'
    public.mkdir()
    for name in ['publish_github.sh', 'publish-lib.sh', 'VERSION']:
        shutil.copy(repo / name, public)
    def git(*args):
        return subprocess.run([real_git, *args], cwd=public, check=True, capture_output=True, text=True)
    git('init', '-q', '-b', 'main')
    git('config', 'core.hooksPath', '/dev/null')
    git('config', 'commit.gpgsign', 'false')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    git('add', 'publish_github.sh', 'publish-lib.sh', 'VERSION')
    git('commit', '-qm', 'fixture')
    git('branch', 'older')
    target = 'https://github.com/DanielMuellerIR/vicious-sidplayer.git'
    git('remote', 'add', 'github', target)
    git('config', '--add', 'remote.github.pushurl', target)
    git('config', '--add', 'remote.github.pushurl', 'https://example.invalid/unintended.git')
    result = subprocess.run(['bash', 'publish_github.sh'], cwd=public, env=env, capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    pushes = [call for call in recorded() if call[:2] == ['git', 'push']]
    assert pushes == [['git', 'push', '--no-follow-tags', target, 'refs/heads/main:refs/heads/main']], pushes
    clear()
    (public / 'VERSION').write_text('99.0.0\n')
    git('add', 'VERSION')
    git('commit', '-qm', 'second fixture')
    result = subprocess.run(['bash', 'publish_github.sh'], cwd=public, env=dict(env, BRANCH='older'), capture_output=True)
    assert result.returncode != 0
    assert not [call for call in recorded() if call[:2] == ['git', 'push']]
    clear()

    # Nur den echten Ziel-Guard ausfuehren; alle Ziele liegen im Testordner.
    script = (repo / 'install.sh').read_text()
    guard = script[script.index('TEAM='):script.index('STAGE_DIR=')]
    new = root / 'new.app'
    old = root / 'existing.app'
    new.mkdir()
    old.mkdir()
    sentinel = old / 'keep'
    sentinel.write_text('foreign app')
    harness = 'APP="$1"\nDESTINATION="$2"\nset -euo pipefail\n' + guard
    result = subprocess.run(['bash', '-c', harness, 'guard', str(new), str(old)], env=dict(env, VSP_TEST_INVALID_APP=str(old)), capture_output=True)
    assert result.returncode != 0
    assert sentinel.read_text() == 'foreign app'
    clear()
    linked = root / 'linked.app'
    linked.symlink_to(old)
    result = subprocess.run(['bash', '-c', harness, 'guard', str(new), str(linked)], env=env, capture_output=True)
    assert result.returncode != 0
    assert sentinel.read_text() == 'foreign app'
print('Release-Gates: fremdes Volume/Artefakt, mehrere Pushziele, Branch-Abweichung und fremde Installationsziele bestanden.')
