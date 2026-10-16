"""Verhaltensvergleich des ausgelieferten JavaScript nach der Minifizierung."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('player_build', Path(__file__).resolve().parents[1] / 'build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class JavaScriptBuildTests(unittest.TestCase):
    def test_labels_templates_and_escaped_quotes_keep_their_contents(self):
        source = r'''const mode = 'NTSC';
        const labels = [' (AUTO)', "a : b / c", 'it\'s (a test)', `Clock: ${mode} // [AUTO]`];
        console.log(JSON.stringify(labels));'''
        original = subprocess.check_output(['node', '-e', source])
        bundled = subprocess.check_output(['node', '-e', builder.minify_js(source)])
        self.assertEqual(bundled, original)


if __name__ == '__main__':
    unittest.main()
