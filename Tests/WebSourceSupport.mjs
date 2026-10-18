import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

// Wie die Produktionsbündelung: dieselbe Parserquelle in jedem JS-Kontext.
export async function sidSource(name) {
  const statement = "import { inspectSIDFile } from './sid-format.js';\n";
  const source = await readFile(new URL('../' + name, import.meta.url), 'utf8');
  assert.equal(source.split(statement).length, 2);
  const format = (await readFile(new URL('../sid-format.js', import.meta.url), 'utf8')).replace('export function', 'function');
  return format + '\n' + source.replace(statement, '');
}
