"""Verhaltensvergleich des ausgelieferten JavaScript nach der Minifizierung."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
import re
import shutil
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('player_build', Path(__file__).resolve().parents[1] / 'build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class JavaScriptBuildTests(unittest.TestCase):
    def test_complete_single_file_javascript_parses_with_and_without_minification(self):
        with tempfile.TemporaryDirectory(prefix='vicious-build-test-') as temporary:
            stage = Path(temporary)
            for name in ['sid-player-worklet.js', 'sid-loop-worker.js', 'sidplayer.js', 'VERSION']:
                shutil.copyfile(builder.HERE / name, stage / name)
            with patch.object(builder, 'HERE', stage):
                for minify in [False, True]:
                    html = builder.build(minify=minify).read_text()
                    scripts = re.findall(r'<script>(.*?)</script>', html, re.S)
                    self.assertEqual(len(scripts), 1)
                    result = subprocess.run(['node', '--check', '-'], input=scripts[0], text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_labels_templates_and_escaped_quotes_keep_their_contents(self):
        source = r'''const mode = 'NTSC';
        const labels = [' (AUTO)', "a : b / c", 'it\'s (a test)', `Clock: ${mode} // [AUTO]`];
        console.log(JSON.stringify(labels));'''
        original = subprocess.check_output(['node', '-e', source])
        bundled = subprocess.check_output(['node', '-e', builder.minify_js(source)])
        self.assertEqual(bundled, original)


if __name__ == '__main__':
    unittest.main()
