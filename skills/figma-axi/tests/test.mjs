// Run: node tests/test.mjs — fails loud if the parsing/encoding logic breaks.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import {
  toonValue,
  toonTable,
  parseFileKey,
  parseNodeIds,
  parseFlags,
  rgbaToHex,
  extractStyle,
  flattenNode,
  isSafeUrl,
  imageFileName,
} from '../bin/cli.mjs';

// TOON quoting: only quote what would otherwise be ambiguous.
assert.equal(toonValue('open'), 'open');
assert.equal(toonValue('a,b'), '"a,b"');
assert.equal(toonValue('100644'), '"100644"');
assert.equal(toonValue('https://x.dev/a'), '"https://x.dev/a"');
assert.equal(toonValue('say "hi"'), '"say \\"hi\\""');
assert.equal(toonValue(''), '""');
assert.equal(toonValue(12), '12');
assert.equal(toonValue(undefined), '');

assert.equal(
  toonTable('rows', [{ a: 1, b: 'x' }], ['a', 'b']),
  'rows[1]{a,b}:\n  1,x',
);
assert.equal(toonTable('rows', [], ['a']), 'rows[0]{a}:');

// File keys from raw ids and from every figma url shape.
assert.equal(parseFileKey('ExampleFileKey12345678'), 'ExampleFileKey12345678');
assert.equal(parseFileKey('https://www.figma.com/design/ABC123defg/Demo?node-id=1-42'), 'ABC123defg');
assert.equal(parseFileKey('https://figma.com/file/ABC123defg/Old'), 'ABC123defg');
assert.equal(parseFileKey('nope'), null);
assert.equal(parseFileKey(''), null);

// URL node ids use dashes, the API wants colons.
assert.deepEqual(parseNodeIds('1-42'), ['1:42']);
assert.deepEqual(parseNodeIds('1:42, 7:9'), ['1:42', '7:9']);
assert.deepEqual(parseNodeIds('https://figma.com/design/K/N?node-id=12-345&t=x'), ['12:345']);

// Flags: values, defaults, and loud rejection of unknown ones.
assert.deepEqual(parseFlags(['KEY', '--depth', '3'], { depth: 'int' }, 'file').flags, { depth: 3 });
assert.deepEqual(parseFlags(['KEY', '--depth=3'], { depth: 'int' }, 'file').positional, ['KEY']);
assert.deepEqual(parseFlags(['--full'], { full: 'bool' }, 'node').flags, { full: true });
assert.match(parseFlags(['--dept', '3'], { depth: 'int' }, 'file').error, /unknown flag --dept/);
assert.match(parseFlags(['--dept'], { depth: 'int' }, 'file').help, /--depth/);
assert.match(parseFlags(['--depth'], { depth: 'int' }, 'file').error, /requires a value/);
assert.match(parseFlags(['--depth', 'x'], { depth: 'int' }, 'file').error, /must be a number/);
assert.equal(parseFlags(['--help'], {}, 'me').flags.help, true);

// Colour conversion, including alpha.
assert.equal(rgbaToHex({ r: 1, g: 0, b: 0, a: 1 }), '#FF0000');
assert.equal(rgbaToHex({ r: 0, g: 0, b: 0, a: 0.5 }), '#00000080');
assert.equal(rgbaToHex(null), undefined);

// Style compression.
assert.equal(
  extractStyle({
    type: 'TEXT',
    style: { fontFamily: 'Inter', fontSize: 14, fontWeight: 600, lineHeightPx: 20 },
    fills: [{ type: 'SOLID', color: { r: 0, g: 0, b: 0, a: 1 } }],
  }),
  'Inter 14/20 w600 #000000',
);
assert.equal(
  extractStyle({ type: 'FRAME', layoutMode: 'VERTICAL', itemSpacing: 8, paddingTop: 16, paddingRight: 16, paddingBottom: 16, paddingLeft: 16, cornerRadius: 12 }),
  'col gap8 pad16 radius12',
);
assert.equal(extractStyle({ type: 'FRAME', visible: false }), 'hidden');

// Depth limit is respected and text is carried.
const tree = {
  id: '1:1',
  name: 'Root',
  type: 'FRAME',
  absoluteBoundingBox: { x: 0, y: 0, width: 100, height: 50 },
  children: [
    { id: '1:2', name: 'Label', type: 'TEXT', characters: 'Hello  world', children: [] },
    { id: '1:3', name: 'Deep', type: 'FRAME', children: [{ id: '1:4', name: 'Hidden', type: 'RECTANGLE' }] },
  ],
};
assert.deepEqual(flattenNode(tree, 1).map((r) => r.id), ['1:1', '1:2', '1:3']);
assert.deepEqual(flattenNode(tree, 2).map((r) => r.id), ['1:1', '1:2', '1:3', '1:4']);
assert.equal(flattenNode(tree, 1)[0].box, '0,0 100x50');
assert.equal(flattenNode(tree, 1)[1].text, 'Hello world');

// Token and downloads: https anywhere, plain http only to a local mock.
assert.equal(isSafeUrl('https://api.figma.com/v1'), true);
assert.equal(isSafeUrl('http://127.0.0.1:4010'), true);
assert.equal(isSafeUrl('http://localhost:4010/v1'), true);
assert.equal(isSafeUrl('http://api.example.com/v1'), false);
assert.equal(isSafeUrl('http://localhost.example.com'), false);
assert.equal(isSafeUrl('file:///etc/passwd'), false);
assert.equal(isSafeUrl('not a url'), false);

// Server-supplied node ids never leave the --out dir.
assert.equal(imageFileName('1:42', 'png'), '1-42.png');
assert.equal(imageFileName('../../x;1', 'svg'), '------x-1.svg');

// CLI refuses before any request: 127.0.0.2 is not on the local allowlist and nothing listens there.
const CLI = fileURLToPath(new URL('../bin/cli.mjs', import.meta.url));
const runCli = (...args) =>
  spawnSync(process.execPath, [CLI, ...args], {
    encoding: 'utf8',
    env: { ...process.env, FIGMA_TOKEN: 'test-token', FIGMA_API_BASE: 'http://127.0.0.2:9' },
  });
const insecure = runCli('me');
assert.equal(insecure.status, 1);
assert.match(insecure.stdout, /^error: FIGMA_API_BASE must use https/);
const badFormat = runCli('images', 'ExampleFileKey12345678', '1:42', '--format', '../x');
assert.equal(badFormat.status, 2);
assert.match(badFormat.stdout, /^error: --format must be one of png, jpg, svg, pdf/);

// A redirect from the API is never followed: fetch would resend X-Figma-Token to the new host.
const hits = [];
const mock = createServer((req, res) => {
  hits.push(req.url);
  res.writeHead(302, { location: '/moved' }).end();
});
await new Promise((r) => mock.listen(0, '127.0.0.1', r));
const redirected = await new Promise((r) => {
  const env = { ...process.env, FIGMA_TOKEN: 'test-token', FIGMA_API_BASE: `http://127.0.0.1:${mock.address().port}` };
  const p = spawn(process.execPath, [CLI, 'me'], { env });
  p.on('close', r);
});
mock.close();
assert.equal(redirected, 1);
assert.deepEqual(hits, ['/me']);

console.log('ok');
