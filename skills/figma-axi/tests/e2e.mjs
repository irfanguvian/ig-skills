// End-to-end test against a mock Figma API. Run: node tests/e2e.mjs
// Serves realistic Figma REST payloads, runs the real CLI as a child process,
// asserts on stdout + exit code, and reports output size vs the raw JSON.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readdirSync, rmSync } from 'node:fs';

const run = promisify(execFile);
const CLI = new URL('../bin/cli.mjs', import.meta.url).pathname;

/* ---------- fixtures ---------- */

const solid = (r, g, b, a = 1) => [{ blendMode: 'NORMAL', type: 'SOLID', color: { r, g, b, a } }];

function textNode(id, name, chars, styleRef) {
  return {
    id,
    name,
    type: 'TEXT',
    blendMode: 'PASS_THROUGH',
    absoluteBoundingBox: { x: 24, y: 40, width: 280.4, height: 20.2 },
    constraints: { vertical: 'TOP', horizontal: 'LEFT' },
    fills: solid(0.06, 0.09, 0.16),
    strokes: [],
    strokeWeight: 1,
    effects: [],
    characters: chars,
    style: {
      fontFamily: 'Inter',
      fontPostScriptName: 'Inter-SemiBold',
      fontWeight: 600,
      fontSize: 14,
      lineHeightPx: 20,
      letterSpacing: -0.14,
      textAlignHorizontal: 'LEFT',
      textAutoResize: 'HEIGHT',
    },
    characterStyleOverrides: [],
    styleOverrideTable: {},
    lineTypes: ['NONE'],
    lineIndentations: [0],
    styles: styleRef ? { fill: 'S:color-ink', text: 'S:text-body' } : undefined,
  };
}

function card(index) {
  return {
    id: `10:${100 + index}`,
    name: `Card ${index}`,
    type: 'FRAME',
    blendMode: 'PASS_THROUGH',
    absoluteBoundingBox: { x: 24, y: 120 + index * 96, width: 328, height: 88 },
    constraints: { vertical: 'TOP', horizontal: 'LEFT' },
    clipsContent: false,
    layoutMode: 'VERTICAL',
    itemSpacing: 8,
    paddingTop: 16,
    paddingRight: 16,
    paddingBottom: 16,
    paddingLeft: 16,
    cornerRadius: 12,
    fills: solid(1, 1, 1),
    strokes: solid(0.9, 0.91, 0.92),
    strokeWeight: 1,
    strokeAlign: 'INSIDE',
    effects: [
      { type: 'DROP_SHADOW', visible: true, color: { r: 0, g: 0, b: 0, a: 0.05 }, offset: { x: 0, y: 1 }, radius: 3, blendMode: 'NORMAL' },
    ],
    children: [
      {
        id: `10:${400 + index}`,
        name: 'Row',
        type: 'FRAME',
        absoluteBoundingBox: { x: 40, y: 136 + index * 96, width: 296, height: 56 },
        layoutMode: 'HORIZONTAL',
        itemSpacing: 12,
        paddingTop: 0,
        paddingRight: 0,
        paddingBottom: 0,
        paddingLeft: 0,
        fills: [],
        strokes: [],
        effects: [],
        children: [
          textNode(`10:${200 + index}`, 'Title', `Profile card headline number ${index}`, true),
          textNode(`10:${300 + index}`, 'Body', 'A longer supporting line of copy that will be truncated by the tree view because it runs well past the 120 character preview limit used for text nodes.', false),
        ],
      },
    ],
  };
}

const CARDS = Number(process.env.STRESS || 12);

const FILE = {
  name: 'Demo App',
  role: 'editor',
  lastModified: '2026-07-20T09:14:03Z',
  editorType: 'figma',
  thumbnailUrl: 'https://s3-alpha.figma.com/thumb/abc',
  version: '4812993220',
  document: {
    id: '0:0',
    name: 'Document',
    type: 'DOCUMENT',
    children: [
      // A divider page: shares the name of a real page but holds nothing. Listed first,
      // so a naive "first match wins" scope picker would pick this one.
      { id: '0:3', name: '✲ ・ User Onboarding', type: 'CANVAS', children: [] },
      {
        id: '0:1',
        name: 'User Onboarding',
        type: 'CANVAS',
        backgroundColor: { r: 0.9, g: 0.9, b: 0.9, a: 1 },
        children: [
          {
            id: '1:42',
            name: 'Step 1 — Profile',
            type: 'FRAME',
            absoluteBoundingBox: { x: 0, y: 0, width: 375, height: 812 },
            layoutMode: 'VERTICAL',
            itemSpacing: 16,
            paddingTop: 24,
            paddingRight: 24,
            paddingBottom: 24,
            paddingLeft: 24,
            cornerRadius: 0,
            fills: solid(0.98, 0.98, 0.99),
            strokes: [],
            effects: [],
            children: Array.from({ length: CARDS }, (_, i) => card(i)),
          },
          {
            id: '1:88',
            name: 'Step 2 — Preferences',
            type: 'FRAME',
            absoluteBoundingBox: { x: 420, y: 0, width: 375, height: 812 },
            fills: solid(1, 1, 1),
            children: [textNode('1:89', 'Heading', 'Pick your preferences', true)],
          },
        ],
      },
      {
        id: '0:2',
        name: 'Components',
        type: 'CANVAS',
        children: [],
      },
    ],
  },
  components: {},
  styles: {
    'S:color-ink': { key: 'k1', name: 'Color/Ink', styleType: 'FILL', description: 'Primary text' },
    'S:text-body': { key: 'k2', name: 'Text/Body', styleType: 'TEXT', description: '' },
    'S:unused': { key: 'k3', name: 'Color/Never Used', styleType: 'FILL', description: '' },
  },
};

const PUBLISHED_STYLES = {
  meta: {
    styles: [
      { key: 'k1', file_key: 'PUB1234567890', node_id: '90:1', style_type: 'FILL', name: 'Color/Ink', description: 'Primary text colour' }, // gitleaks:allow (fake fixture key)
      { key: 'k2', file_key: 'PUB1234567890', node_id: '90:2', style_type: 'TEXT', name: 'Text/Body', description: '' }, // gitleaks:allow (fake fixture key)
      { key: 'k3', file_key: 'PUB1234567890', node_id: '90:3', style_type: 'EFFECT', name: 'Shadow/Card', description: '' }, // gitleaks:allow (fake fixture key)
    ],
  },
};

const STYLE_NODES = {
  name: 'Demo App',
  nodes: {
    '90:1': { document: { id: '90:1', name: 'Color/Ink', type: 'RECTANGLE', fills: solid(0.06, 0.09, 0.16) } },
    '90:2': {
      document: {
        id: '90:2',
        name: 'Text/Body',
        type: 'TEXT',
        style: { fontFamily: 'Inter', fontWeight: 400, fontSize: 16, lineHeightPx: 24, letterSpacing: 0 },
      },
    },
    '90:3': {
      document: {
        id: '90:3',
        name: 'Shadow/Card',
        type: 'RECTANGLE',
        effects: [{ type: 'DROP_SHADOW', visible: true, color: { r: 0, g: 0, b: 0, a: 0.08 }, offset: { x: 0, y: 2 }, radius: 6 }],
      },
    },
  },
};

function nodesResponse(ids) {
  const index = new Map();
  const walk = (n) => {
    index.set(n.id, n);
    (n.children || []).forEach(walk);
  };
  FILE.document.children.forEach(walk);
  const nodes = {};
  // Figma returns the styles used inside each requested node alongside the document.
  for (const id of ids) if (index.has(id)) nodes[id] = { document: index.get(id), styles: FILE.styles };
  return { name: FILE.name, nodes };
}

/* ---------- mock server ---------- */

let lastRawBytes = 0;
let lastQuery = '';
const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const path = url.pathname;
  lastQuery = url.search;
  const token = req.headers['x-figma-token'];
  const send = (status, body) => {
    const json = JSON.stringify(body);
    lastRawBytes = Buffer.byteLength(json);
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(json);
  };
  if (token !== 'test-token') return send(403, { status: 403, err: 'Invalid token' });

  if (path === '/me') return send(200, { id: '9001', email: 'user@example.com', handle: 'demo' });
  if (path === '/files/NOTFOUND123/') return send(404, { status: 404, err: 'Not found' });
  if (path.startsWith('/files/RATE1234567890')) return send(429, { status: 429, err: 'Rate limit' });

  const [, , key, sub] = path.split('/');
  if (key === 'NOTFOUND1234' ) return send(404, { status: 404, err: 'Not found' });

  if (path.startsWith('/images/')) {
    const ids = (url.searchParams.get('ids') || '').split(',');
    if (ids.includes('9:99')) return send(200, { err: 'Node 9:99 not found' });
    const images = {};
    for (const id of ids) images[id] = `https://figma-alpha-api.s3.us-west-2.amazonaws.com/images/${id.replace(':', '-')}?X-Amz-Signature=deadbeef`;
    return send(200, { err: null, images });
  }
  if (path.endsWith('.png-blob')) return send(200, {});

  if (sub === 'styles') {
    const unpublished = key === 'LOCAL1234567890' || key === 'HUGE1234567890'; // gitleaks:allow (fake fixture key)
    return send(200, unpublished ? { meta: { styles: [] } } : PUBLISHED_STYLES);
  }
  if (sub === 'components') {
    return send(200, {
      meta: {
        components: [
          { key: 'c1', node_id: '20:1', name: 'Button/Primary', description: 'Main call to action', containing_frame: {} },
          { key: 'c2', node_id: '20:2', name: 'Button/Secondary', description: '', containing_frame: {} },
        ],
      },
    });
  }
  if (sub === 'component_sets') return send(200, { meta: { component_sets: [{ key: 's1', node_id: '20:0', name: 'Button', description: 'All button variants' }] } });
  if (sub === 'comments') {
    return send(200, {
      comments: [
        { id: 'c-2', message: 'Spacing here should be 16 not 12, please match the token.', created_at: '2026-07-19T11:02:00Z', resolved_at: null, user: { handle: 'reviewer' }, client_meta: { node_id: '10:100' } },
        { id: 'c-1', message: 'Approved.', created_at: '2026-07-18T08:30:00Z', resolved_at: '2026-07-18T09:00:00Z', user: { handle: 'demo' }, client_meta: {} },
      ],
    });
  }
  if (sub === 'nodes') {
    const ids = (url.searchParams.get('ids') || '').split(',');
    if (ids.every((id) => id.startsWith('90:'))) return send(200, STYLE_NODES);
    return send(200, nodesResponse(ids));
  }
  if (!sub) {
    // Figma refuses a whole-file read once the document is big enough.
    if (key === 'HUGE1234567890' && !url.searchParams.get('depth')) { // gitleaks:allow (fake fixture key)
      return send(400, { status: 400, err: 'Request too large. If applicable, filter by query params.' });
    }
    return send(200, FILE);
  }
  return send(404, { status: 404, err: 'Not found' });
});

/* ---------- harness ---------- */

const results = [];
async function cli(args, { token = 'test-token', expect = 0 } = {}) {
  const env = { ...process.env, FIGMA_API_BASE: base, FIGMA_TOKEN: token };
  delete env.FIGMA_FILE_KEY;
  try {
    const { stdout } = await run('node', [CLI, ...args], { env, maxBuffer: 32 * 1024 * 1024 });
    assert.equal(expect, 0, `expected exit ${expect} for: ${args.join(' ')}\n${stdout}`);
    return stdout;
  } catch (err) {
    assert.equal(err.code, expect, `wrong exit code for: ${args.join(' ')}\n${err.stdout}`);
    return err.stdout;
  }
}

function check(name, fn) {
  results.push({ name, fn });
}

let base;
await new Promise((r) => server.listen(0, '127.0.0.1', r));
base = `http://127.0.0.1:${server.address().port}`;

const KEY = 'PUB1234567890'; // gitleaks:allow (fake fixture key)
const sizes = [];

if (process.env.STRESS) {
  for (const args of [['file', KEY], ['node', KEY, '1:42'], ['node', KEY, '1:42', '--depth', '3'], ['tokens', 'LOCAL1234567890']]) {
    const t = Date.now();
    const o = await cli(args);
    const peak = o.match(/tree\[(\d+)\]/);
    console.log(
      `${args.join(' ').padEnd(28)} raw ${String(lastRawBytes).padStart(9)}B  axi ${String(Buffer.byteLength(o)).padStart(8)}B  ${String(Date.now() - t).padStart(6)}ms  rows ${peak ? peak[1] : '-'}`,
    );
  }
  server.close();
  process.exit(0);
}

if (process.env.DUMP) {
  for (const args of [['file', KEY], ['node', KEY, '1:42'], ['node', KEY, '1:42', '--depth', '3'], ['tokens', KEY], ['tokens', 'LOCAL1234567890'], ['styles', KEY], ['comments', KEY]]) {
    console.log(`\n$ figma-axi ${args.join(' ')}\n${await cli(args)}`);
  }
  server.close();
  process.exit(0);
}

/* ---------- cases ---------- */

check('me returns the account', async () => {
  const o = await cli(['me']);
  assert.match(o, /handle: demo/);
});

check('bad token is translated, not leaked', async () => {
  const o = await cli(['me'], { token: 'wrong', expect: 1 });
  assert.match(o, /error: figma api 403: token rejected/);
  assert.doesNotMatch(o, /Invalid token/, 'raw dependency error leaked to the agent');
});

check('404 is translated', async () => {
  const o = await cli(['file', 'NOTFOUND1234'], { expect: 1 });
  assert.match(o, /error: figma api 404: not found/);
});

check('429 tells the agent to wait', async () => {
  const o = await cli(['file', 'RATE1234567890'], { expect: 1 });
  assert.match(o, /rate limited/);
});

check('file lists pages and frames with ids', async () => {
  const o = await cli(['file', KEY]);
  assert.match(o, /name: Demo App$/m);
  assert.match(o, /pages\[3\]\{id,name,frames\}:/);
  assert.match(o, /frames\[2\]\{id,page,name,type,size\}:/);
  assert.match(o, /"1:42",User Onboarding,Step 1 — Profile,FRAME,375x812/);
  assert.match(o, /help\[2\]:/);
  sizes.push({ command: 'file', rawBytes: lastRawBytes, outBytes: Buffer.byteLength(o) });
});

check('file caps the frame list and says how to narrow it', async () => {
  const o = await cli(['file', KEY, '--limit', '1']);
  assert.match(o, /frames\[1\]/);
  assert.match(o, /shown: 1 of 2 frames \(capped at --limit 1\)/);
  assert.match(o, /--page "<page name>"/, 'no way offered to narrow the list');
});

check('file --page filters to one page and drops the page table', async () => {
  const o = await cli(['file', KEY, '--page', 'User Onboarding']);
  assert.match(o, /frames\[2\]/);
  assert.doesNotMatch(o, /pages\[/, 'page table is noise once a page is chosen');
});

check('file --page with no match is a definitive empty state', async () => {
  const o = await cli(['file', KEY, '--page', 'Nonexistent']);
  assert.match(o, /frames: 0 frames on any page matching "Nonexistent"/);
});

check('empty page reports zero frames, not silence', async () => {
  const o = await cli(['file', KEY]);
  assert.match(o, /"0:2",Components,0/);
});

check('node compresses the tree and stops at the depth limit', async () => {
  const o = await cli(['node', KEY, '1:42']);
  assert.match(o, /nodes: 49/, 'total node count must include the node itself');
  assert.match(o, /tree\[25\]\{depth,id,name,type,box,style,text\}:/, 'depth 2 should stop above the text nodes');
  assert.match(o, /shown: 25 of 49 nodes \(depth 2\)/, 'no report of what was hidden');
  assert.doesNotMatch(o, /Profile card headline/, 'depth limit did not stop the walk');
  assert.match(o, /col gap16 pad24/, 'auto-layout not summarised');
  assert.match(o, /radius12/, 'corner radius missing');
  assert.match(o, /drop_shadow/, 'effects missing');
  assert.match(o, /border #E6E8EB 1px/, 'stroke missing');
  assert.match(o, /row gap12 pad0/, 'horizontal auto-layout not summarised');
  sizes.push({ command: 'node --depth 2', rawBytes: lastRawBytes, outBytes: Buffer.byteLength(o) });
});

check('node depth 3 reaches the text and truncates it', async () => {
  const o = await cli(['node', KEY, '1:42', '--depth', '3']);
  assert.match(o, /tree\[49\]/);
  assert.doesNotMatch(o, /shown: /, 'nothing was hidden at this depth');
  assert.match(o, /Inter 14\/20 w600 ls-0\.14 #0F1729/, 'typography not summarised');
  assert.match(o, /Profile card headline number 0/);
  assert.match(o, /…/, 'long copy was not truncated');
  assert.doesNotMatch(o, /120 character preview limit/, 'truncation did not apply');
  sizes.push({ command: 'node --depth 3', rawBytes: lastRawBytes, outBytes: Buffer.byteLength(o) });
});

check('node accepts a figma url with node-id and dash form', async () => {
  const o = await cli(['node', `https://www.figma.com/design/${KEY}/Demo?node-id=1-42&t=abc`]);
  assert.match(o, /node: "1:42"/);
});

check('node handles several ids and flags the missing one', async () => {
  const o = await cli(['node', KEY, '1:42,1:88,9:99', '--depth', '1']);
  assert.match(o, /node: "1:42"/);
  assert.match(o, /node: "1:88"/);
  assert.match(o, /Not found: 9:99/);
});

check('node caps a huge tree instead of dumping it', async () => {
  const o = await cli(['node', KEY, '1:42', '--depth', '3', '--limit', '10']);
  assert.match(o, /tree\[10\]/);
  assert.match(o, /shown: 10 of 49 nodes \(depth 3, capped at --limit 10\)/);
  assert.match(o, /Pick a child id from the rows above/);
  assert.match(o, /--limit 50/, 'no way offered to see more');
});

check('node --full returns raw json for the whole subtree', async () => {
  const o = await cli(['node', KEY, '1:88', '--full']);
  assert.match(o, /"absoluteBoundingBox"/);
  assert.doesNotMatch(lastQuery, /depth=/, '--full must not cap depth, or the raw json is truncated');
});

check('node with no id is a usage error', async () => {
  const o = await cli(['node', KEY], { expect: 2 });
  assert.match(o, /error: node requires at least one node id/);
});

check('styles lists published metadata', async () => {
  const o = await cli(['styles', KEY]);
  assert.match(o, /styles\[3\]\{node_id,name,type,description\}:/);
  assert.match(o, /"90:1",Color\/Ink,FILL,Primary text colour/);
});

check('tokens resolves published styles to real values', async () => {
  const o = await cli(['tokens', KEY]);
  assert.match(o, /source: published styles/);
  assert.match(o, /colors\[1\]\{name,value,description\}:/);
  assert.match(o, /Color\/Ink,#0F1729,Primary text colour/);
  assert.match(o, /Text\/Body,Inter,16,400,24,0/);
  assert.match(o, /Shadow\/Card,"drop_shadow 0,2 blur6 #00000014"/);
  sizes.push({ command: 'tokens', rawBytes: lastRawBytes, outBytes: Buffer.byteLength(o) });
});

check('tokens falls back to local styles when nothing is published', async () => {
  const o = await cli(['tokens', 'LOCAL1234567890']);
  assert.match(o, /source: local styles resolved from usage/);
  assert.match(o, /Color\/Ink,#0F1729/);
  assert.match(o, /Text\/Body,Inter,14,600,20,-0\.14/);
  assert.doesNotMatch(o, /Never Used/, 'a style no node references cannot be resolved');
});

check('tokens on a file too big to read tells the agent how to scope it', async () => {
  const o = await cli(['tokens', 'HUGE1234567890'], { expect: 1 }); // gitleaks:allow (fake fixture key)
  assert.match(o, /error: this file is too big for Figma to return in one request/);
  assert.match(o, /--page "User Onboarding"/, 'suggested page must be one that has frames');
  assert.match(o, /--from <node-id>/);
});

check('tokens --page skips the empty divider page of the same name', async () => {
  const o = await cli(['tokens', 'LOCAL1234567890', '--page', 'User Onboarding']);
  assert.match(o, /source: local styles resolved from usage/);
  assert.match(o, /Color\/Ink,#0F1729/);
  assert.doesNotMatch(o, /0 styles defined/, 'scope resolved to the empty divider page');
});

check('tokens --page with no match names the problem', async () => {
  const o = await cli(['tokens', 'LOCAL1234567890', '--page', 'Nonexistent'], { expect: 1 });
  assert.match(o, /error: no page matching "Nonexistent"/);
});

check('tokens collapses identical rows from duplicate style ids', async () => {
  const o = await cli(['tokens', 'LOCAL1234567890', '--page', 'User Onboarding']);
  const rows = o.split('\n').filter((l) => l.includes('Text/Body,Inter'));
  assert.equal(rows.length, 1, 'the same style resolved to the same values should appear once');
});

check('components lists components and sets', async () => {
  const o = await cli(['components', KEY]);
  assert.match(o, /components\[2\]\{node_id,name,set,description\}:/);
  assert.match(o, /component_sets\[1\]/);
});

check('comments are newest first with a total', async () => {
  const o = await cli(['comments', KEY]);
  assert.match(o, /count: 2 of 2 total/);
  assert.match(o, /c-2,reviewer,"2026-07-19 11:02",false,"10:100"/);
  assert.match(o, /c-1,demo,.*,true/);
});

check('comments --limit reports the remainder', async () => {
  const o = await cli(['comments', KEY, '--limit', '1']);
  assert.match(o, /count: 1 of 2 total/);
  assert.match(o, /--limit 2/);
});

check('images prints urls by default', async () => {
  const o = await cli(['images', KEY, '1:42']);
  assert.match(o, /images\[1\]\{id,url\}:/);
  assert.match(o, /Add `--out <dir>`/);
});

check('images surfaces a render error from figma', async () => {
  const o = await cli(['images', KEY, '9:99'], { expect: 1 });
  assert.match(o, /error: figma could not render: Node 9:99 not found/);
});

check('unknown flag names the flag and lists the valid ones', async () => {
  const o = await cli(['comments', KEY, '--limits', '5'], { expect: 2 });
  assert.match(o, /error: unknown flag --limits for `comments`/);
  assert.match(o, /valid flags for `comments`: --limit/);
});

check('every command rejects an unknown flag before calling the api', async () => {
  for (const cmd of ['file', 'node', 'styles', 'components', 'tokens', 'images', 'comments']) {
    const o = await cli([cmd, KEY, '--nope'], { expect: 2 });
    assert.match(o, new RegExp(`unknown flag --nope for \`${cmd}\``));
  }
});

check('--help works on every command without a key', async () => {
  for (const cmd of Object.keys({ me: 1, file: 1, node: 1, styles: 1, components: 1, tokens: 1, images: 1, comments: 1 })) {
    const o = await cli([cmd, '--help']);
    assert.match(o, new RegExp(`command: ${cmd}`));
    assert.match(o, /usage: /);
  }
});

check('home view shows the default file when FIGMA_FILE_KEY is set', async () => {
  const { stdout } = await run('node', [CLI], {
    env: { ...process.env, FIGMA_API_BASE: base, FIGMA_TOKEN: 'test-token', FIGMA_FILE_KEY: KEY },
  });
  assert.match(stdout, /bin: /);
  assert.match(stdout, /default_file: PUB1234567890/);
  assert.match(stdout, /name: Demo App$/m, 'home view is not content-first');
});

/* ---------- run ---------- */

let failed = 0;
for (const { name, fn } of results) {
  try {
    await fn();
    console.log(`  pass  ${name}`);
  } catch (err) {
    failed++;
    console.log(`  FAIL  ${name}\n        ${err.message.split('\n').slice(0, 6).join('\n        ')}`);
  }
}

console.log(`\n${results.length - failed}/${results.length} passed`);
console.log('\noutput size vs raw figma json (bytes):');
for (const s of sizes) {
  const pct = ((1 - s.outBytes / s.rawBytes) * 100).toFixed(1);
  console.log(`  ${s.command.padEnd(16)} raw ${String(s.rawBytes).padStart(7)}  axi ${String(s.outBytes).padStart(6)}  -${pct}%`);
}

server.close();
process.exit(failed ? 1 : 0);
