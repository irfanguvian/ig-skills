#!/usr/bin/env node
// figma-axi — AXI-shaped CLI over the Figma REST API.
// Output is TOON on stdout, including errors. Exit: 0 ok, 1 error, 2 usage.

import { realpathSync } from 'node:fs';
import { writeFile, mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const API = process.env.FIGMA_API_BASE || 'https://api.figma.com/v1';
const DESCRIPTION = 'Read Figma files, styles, design tokens, renders and comments';

/* ---------- TOON output ---------- */

const NUMBERISH = /^-?\d+(\.\d+)?$/;

export function toonValue(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  const s = String(v);
  const needsQuote =
    s === '' ||
    s !== s.trim() ||
    /[",:\n]/.test(s) ||
    NUMBERISH.test(s) ||
    s === 'true' ||
    s === 'false' ||
    s === 'null';
  if (!needsQuote) return s;
  return `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
}

export function toonTable(name, rows, fields, indent = '') {
  const head = `${indent}${name}[${rows.length}]{${fields.join(',')}}:`;
  const body = rows.map((r) => `${indent}  ${fields.map((f) => toonValue(r[f])).join(',')}`);
  return [head, ...body].join('\n');
}

export function toonObject(obj, indent = '') {
  return Object.entries(obj)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${indent}${k}: ${toonValue(v)}`)
    .join('\n');
}

function toonHelp(lines) {
  if (!lines.length) return '';
  if (lines.length === 1) return `help: ${lines[0]}`;
  return [`help[${lines.length}]:`, ...lines.map((l) => `  ${l}`)].join('\n');
}

function out(...blocks) {
  console.log(blocks.filter(Boolean).join('\n'));
}

function fail(message, help, code = 1) {
  out(`error: ${message}`, help && toonHelp(Array.isArray(help) ? help : [help]));
  process.exit(code);
}

/* ---------- input parsing ---------- */

export function parseFileKey(input) {
  if (!input) return null;
  const url = input.match(/figma\.com\/(?:file|design|proto)\/([A-Za-z0-9]+)/);
  if (url) return url[1];
  if (/^[A-Za-z0-9]{10,}$/.test(input)) return input;
  return null;
}

export function parseNodeIds(input) {
  // Figma URLs write node ids as 1-23; the API wants 1:23.
  const fromUrl = input.match(/[?&]node-id=([^&]+)/);
  const raw = fromUrl ? decodeURIComponent(fromUrl[1]) : input;
  return raw
    .split(',')
    .map((id) => id.trim().replace(/-/g, ':'))
    .filter(Boolean);
}

// The token and render downloads go over https only; plain http is for a local mock server.
export function isSafeUrl(url) {
  try {
    const { protocol, hostname } = new URL(url);
    return protocol === 'https:' || (protocol === 'http:' && (hostname === '127.0.0.1' || hostname === 'localhost'));
  } catch {
    return false;
  }
}

export const IMAGE_FORMATS = ['png', 'jpg', 'svg', 'pdf'];

// Node ids come from the server: keep file names inside --out.
export function imageFileName(id, format) {
  return `${id.replace(/[^A-Za-z0-9_-]/g, '-')}.${format}`;
}

export function parseFlags(argv, spec, command) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }
    const eq = arg.indexOf('=');
    const name = (eq === -1 ? arg : arg.slice(0, eq)).slice(2);
    if (name === 'help') {
      flags.help = true;
      continue;
    }
    const kind = spec[name];
    if (!kind) {
      const known = Object.keys(spec);
      return {
        error: `unknown flag --${name} for \`${command}\``,
        help: `valid flags for \`${command}\`: ${known.length ? known.map((f) => `--${f}`).join(', ') : 'none'} (--help always allowed)`,
      };
    }
    if (kind === 'bool') {
      flags[name] = true;
      continue;
    }
    const value = eq === -1 ? argv[++i] : arg.slice(eq + 1);
    if (value === undefined || value.startsWith('--')) {
      return { error: `--${name} requires a value`, help: `${command} --${name} <value>` };
    }
    flags[name] = kind === 'int' ? Number(value) : value;
    if (kind === 'int' && !Number.isFinite(flags[name])) {
      return { error: `--${name} must be a number`, help: `${command} --${name} 2` };
    }
  }
  return { flags, positional };
}

/* ---------- Figma API ---------- */

function token() {
  return process.env.FIGMA_TOKEN || process.env.FIGMA_PERSONAL_ACCESS_TOKEN || '';
}

async function api(path, { soft = false } = {}) {
  const pat = token();
  if (!pat) {
    fail('no Figma token found', [
      'Create a personal access token at https://www.figma.com/settings (Security > Personal access tokens)',
      'Then export FIGMA_TOKEN=<token> in your shell profile',
    ]);
  }
  if (!isSafeUrl(API)) {
    fail(`FIGMA_API_BASE must use https (http only for localhost or 127.0.0.1): ${API}`, [
      'Unset FIGMA_API_BASE to use https://api.figma.com/v1',
    ]);
  }
  // fetch keeps custom headers across a redirect: never follow one with the token attached
  const res = await fetch(`${API}${path}`, { headers: { 'X-Figma-Token': pat }, redirect: 'error' });
  if (res.ok) return res.json();
  const body = await res.text().catch(() => '');
  const tooLarge = res.status === 400 && /too large/i.test(body);
  if (soft) return { __err: res.status, tooLarge };
  const messages = {
    400: tooLarge
      ? 'that request covers too much of the file for Figma to return — scope it to a page or node'
      : 'bad request — check the file key and node ids',
    403: 'token rejected — expired, or missing scope for this file',
    404: 'not found — wrong file key, or the token has no access to it',
    429: 'rate limited by Figma — wait a minute and retry',
  };
  fail(`figma api ${res.status}: ${messages[res.status] || body.slice(0, 200) || res.statusText}`, [
    'Run `figma-axi me` to check the token',
  ]);
}

function requireKey(positional, command) {
  const key = parseFileKey(positional[0]);
  if (!key) {
    fail(
      `${command} requires a file key or figma.com url`,
      `figma-axi ${command} <file-key|url>`,
      2,
    );
  }
  return key;
}

/* ---------- node compression ---------- */

const round = (n) => (typeof n === 'number' ? Math.round(n) : undefined);

export function rgbaToHex(color, opacity = 1) {
  if (!color) return undefined;
  const hex = (v) =>
    Math.round(Math.min(1, Math.max(0, v)) * 255)
      .toString(16)
      .padStart(2, '0');
  const alpha = (color.a ?? 1) * opacity;
  const base = `#${hex(color.r)}${hex(color.g)}${hex(color.b)}`.toUpperCase();
  return alpha < 0.999 ? `${base}${hex(alpha).toUpperCase()}` : base;
}

function firstSolidFill(fills) {
  const fill = (fills || []).find((f) => f.visible !== false && f.type === 'SOLID');
  return fill ? rgbaToHex(fill.color, fill.opacity ?? 1) : undefined;
}

export function extractStyle(node) {
  const parts = [];
  if (node.type === 'TEXT' && node.style) {
    const s = node.style;
    const size = round(s.fontSize);
    const line = round(s.lineHeightPx);
    parts.push(`${s.fontFamily || '?'} ${size}/${line ?? 'auto'} w${s.fontWeight ?? '?'}`);
    if (s.letterSpacing) parts.push(`ls${s.letterSpacing.toFixed(2)}`);
    if (s.textAlignHorizontal && s.textAlignHorizontal !== 'LEFT') parts.push(s.textAlignHorizontal.toLowerCase());
  }
  const fill = firstSolidFill(node.fills);
  if (fill) parts.push(fill);
  const stroke = firstSolidFill(node.strokes);
  if (stroke) parts.push(`border ${stroke}${node.strokeWeight ? ` ${round(node.strokeWeight)}px` : ''}`);
  if (node.layoutMode && node.layoutMode !== 'NONE') {
    const pads = [node.paddingTop, node.paddingRight, node.paddingBottom, node.paddingLeft].map(
      (p) => round(p) || 0,
    );
    const pad = pads.every((p) => p === pads[0]) ? `${pads[0]}` : pads.join('/');
    parts.push(`${node.layoutMode === 'HORIZONTAL' ? 'row' : 'col'} gap${round(node.itemSpacing) || 0} pad${pad}`);
  }
  if (node.cornerRadius) parts.push(`radius${round(node.cornerRadius)}`);
  if (node.opacity !== undefined && node.opacity < 1) parts.push(`opacity${node.opacity.toFixed(2)}`);
  if (node.effects?.some((e) => e.visible !== false)) {
    parts.push(node.effects.filter((e) => e.visible !== false).map((e) => e.type.toLowerCase()).join('+'));
  }
  if (node.visible === false) parts.push('hidden');
  return parts.join(' ');
}

const TEXT_LIMIT = 120;

function truncate(text, limit) {
  if (!text) return '';
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > limit ? `${flat.slice(0, limit)}…` : flat;
}

export function flattenNode(node, maxDepth, depth = 0, rows = []) {
  const box = node.absoluteBoundingBox;
  rows.push({
    depth,
    id: node.id,
    name: node.name,
    type: node.type,
    box: box ? `${round(box.x)},${round(box.y)} ${round(box.width)}x${round(box.height)}` : '',
    style: extractStyle(node),
    text: node.type === 'TEXT' ? truncate(node.characters, TEXT_LIMIT) : '',
  });
  if (depth < maxDepth) {
    for (const child of node.children || []) flattenNode(child, maxDepth, depth + 1, rows);
  }
  return rows;
}

function countDescendants(node) {
  return (node.children || []).reduce((n, c) => n + 1 + countDescendants(c), 0);
}

/* ---------- commands ---------- */

const COMMANDS = {
  me: {
    spec: {},
    usage: 'figma-axi me',
    about: 'Verify the token and show the authenticated account.',
    examples: ['figma-axi me'],
  },
  file: {
    spec: { depth: 'int', page: 'string', limit: 'int' },
    usage: 'figma-axi file <file-key|url> [--page <id|name>] [--limit 50] [--depth 2]',
    about: 'File metadata plus its pages and their top-level frames.',
    examples: [
      'figma-axi file <key>',
      'figma-axi file <key> --page Onboarding',
      'figma-axi file <url> --depth 3',
    ],
  },
  node: {
    spec: { depth: 'int', limit: 'int', full: 'bool' },
    usage: 'figma-axi node <file-key|url> <node-id[,node-id]> [--depth 2] [--limit 200] [--full]',
    about: 'Compressed layout and style tree for specific nodes. --full prints raw Figma JSON.',
    examples: [
      'figma-axi node <key> 1:42',
      'figma-axi node "https://figma.com/design/KEY/N?node-id=1-42" --depth 4',
    ],
  },
  styles: {
    spec: {},
    usage: 'figma-axi styles <file-key|url>',
    about: 'Published styles in the file (name, type, description).',
    examples: ['figma-axi styles <key>'],
  },
  components: {
    spec: {},
    usage: 'figma-axi components <file-key|url>',
    about: 'Published components and component sets.',
    examples: ['figma-axi components <key>'],
  },
  tokens: {
    spec: { page: 'string', from: 'string' },
    usage: 'figma-axi tokens <file-key|url> [--page <id|name>] [--from <node-id>]',
    about: 'Design tokens — colour, text and effect styles resolved to real values.',
    examples: [
      'figma-axi tokens <key>',
      'figma-axi tokens <key> --page Onboarding',
      'figma-axi tokens <key> --from 12:345',
    ],
  },
  images: {
    spec: { format: 'string', scale: 'string', out: 'string' },
    usage: 'figma-axi images <file-key|url> <node-id[,node-id]> [--format png] [--scale 2] [--out dir]',
    about: 'Render nodes to images. Without --out it prints the signed urls.',
    examples: ['figma-axi images <key> 1:42 --scale 2', 'figma-axi images <key> 1:42 --out ./shots'],
  },
  comments: {
    spec: { limit: 'int' },
    usage: 'figma-axi comments <file-key|url> [--limit 30]',
    about: 'Comments on the file, newest first.',
    examples: ['figma-axi comments <key> --limit 10'],
  },
};

function commandHelp(name) {
  const c = COMMANDS[name];
  const flags = Object.keys(c.spec);
  out(
    toonObject({ command: name, usage: c.usage, about: c.about }),
    flags.length ? `flags[${flags.length}]: ${flags.map((f) => `--${f}`).join(',')}` : 'flags: none',
    toonTable('examples', c.examples.map((e) => ({ e })), ['e']),
  );
}

async function cmdMe() {
  const me = await api('/me');
  out(toonObject({ id: me.id, handle: me.handle, email: me.email }));
}

async function cmdFile(key, flags) {
  const depth = flags.depth ?? 2;
  const file = await api(`/files/${key}?depth=${depth}`);
  const pages = (file.document.children || []).map((page) => ({
    id: page.id,
    name: page.name,
    frames: (page.children || []).length,
  }));
  const needle = (flags.page || '').toLowerCase();
  const all = [];
  for (const page of file.document.children || []) {
    if (needle && page.id !== flags.page && !page.name.toLowerCase().includes(needle)) continue;
    for (const frame of page.children || []) {
      const box = frame.absoluteBoundingBox;
      all.push({
        id: frame.id,
        page: page.name,
        name: frame.name,
        type: frame.type,
        size: box ? `${round(box.width)}x${round(box.height)}` : '',
      });
    }
  }
  // A design file can hold hundreds of top-level frames; the page list is the map.
  const limit = flags.limit ?? 50;
  const frames = all.slice(0, limit);
  const help = [];
  if (all.length > frames.length) {
    help.push(`Run \`figma-axi file ${key} --page "<page name>"\` to narrow to one page`);
  }
  help.push(`Run \`figma-axi node ${key} <id>\` for a frame's layout and styles`);
  help.push(`Run \`figma-axi tokens ${key}\` for colour and text tokens`);
  out(
    toonObject({
      name: file.name,
      key,
      lastModified: file.lastModified,
      version: file.version,
      editorType: file.editorType,
      pages: pages.length,
    }),
    needle ? '' : pages.length ? toonTable('pages', pages, ['id', 'name', 'frames']) : 'pages: 0 pages in this file',
    frames.length
      ? toonTable('frames', frames, ['id', 'page', 'name', 'type', 'size'])
      : needle
        ? `frames: 0 frames on any page matching "${flags.page}"`
        : 'frames: 0 top-level frames at this depth',
    all.length > frames.length ? `shown: ${frames.length} of ${all.length} frames (capped at --limit ${limit})` : '',
    toonHelp(help),
  );
}

async function cmdNode(key, positional, flags) {
  if (!positional[1] && !/node-id=/.test(positional[0])) {
    fail('node requires at least one node id', COMMANDS.node.usage, 2);
  }
  const ids = parseNodeIds(positional[1] || positional[0]);
  const depth = flags.depth ?? 2;
  // --full means the whole subtree; a depth cap would silently truncate it.
  const depthParam = flags.full ? '' : `&depth=${depth + 1}`;
  const data = await api(`/files/${key}/nodes?ids=${encodeURIComponent(ids.join(','))}${depthParam}`);
  const missing = ids.filter((id) => !data.nodes[id]);
  if (missing.length === ids.length) {
    fail(`no node found for ${ids.join(', ')}`, [
      `Run \`figma-axi file ${key}\` to list valid node ids`,
    ]);
  }
  if (flags.full) {
    out(JSON.stringify(data, null, 2));
    return;
  }
  // A single frame can hold tens of thousands of nodes; never dump them all.
  const limit = flags.limit ?? 200;
  const blocks = [];
  let capped = false;
  for (const id of ids) {
    const entry = data.nodes[id];
    if (!entry) continue;
    const doc = entry.document;
    const walked = flattenNode(doc, depth);
    const rows = walked.slice(0, limit);
    const total = countDescendants(doc) + 1;
    if (walked.length > rows.length) capped = true;
    blocks.push(toonObject({ node: id, name: doc.name, type: doc.type, nodes: total }));
    blocks.push(toonTable('tree', rows, ['depth', 'id', 'name', 'type', 'box', 'style', 'text']));
    if (total > rows.length) {
      const why = walked.length > rows.length ? `depth ${depth}, capped at --limit ${limit}` : `depth ${depth}`;
      blocks.push(`shown: ${rows.length} of ${total} nodes (${why})`);
    }
  }
  const help = [];
  if (missing.length) help.push(`Not found: ${missing.join(', ')} — check the ids`);
  if (capped) {
    help.push('Pick a child id from the rows above and inspect that subtree instead of raising --limit');
    help.push(`Run \`figma-axi node ${key} ${ids[0]} --limit ${limit * 5}\` to see more of this one`);
  } else {
    help.push(`Run \`figma-axi node ${key} ${ids[0]} --depth ${depth + 2}\` to go deeper`);
  }
  help.push(`Run \`figma-axi node ${key} ${ids[0]} --full\` for raw Figma JSON`);
  out(...blocks, toonHelp(help));
}

async function cmdStyles(key) {
  const data = await api(`/files/${key}/styles`);
  const styles = data.meta?.styles || [];
  if (!styles.length) {
    out(
      'styles: 0 published styles in this file',
      toonHelp([
        `Run \`figma-axi tokens ${key}\` — it falls back to local styles used in the file`,
      ]),
    );
    return;
  }
  out(
    toonTable(
      'styles',
      styles.map((s) => ({
        node_id: s.node_id,
        name: s.name,
        type: s.style_type,
        description: truncate(s.description, 80),
      })),
      ['node_id', 'name', 'type', 'description'],
    ),
    toonHelp([`Run \`figma-axi tokens ${key}\` to resolve these to hex and font values`]),
  );
}

async function cmdComponents(key) {
  const [components, sets] = await Promise.all([
    api(`/files/${key}/components`),
    api(`/files/${key}/component_sets`),
  ]);
  const rows = (components.meta?.components || []).map((c) => ({
    node_id: c.node_id,
    name: c.name,
    set: c.containing_frame?.containingStateGroup?.name || '',
    description: truncate(c.description, 80),
  }));
  const setRows = (sets.meta?.component_sets || []).map((s) => ({
    node_id: s.node_id,
    name: s.name,
    description: truncate(s.description, 80),
  }));
  out(
    rows.length
      ? toonTable('components', rows, ['node_id', 'name', 'set', 'description'])
      : 'components: 0 published components in this file',
    setRows.length ? toonTable('component_sets', setRows, ['node_id', 'name', 'description']) : '',
    rows.length
      ? toonHelp([`Run \`figma-axi node ${key} ${rows[0].node_id}\` to inspect a component`])
      : '',
  );
}

function tokenRowsFromNode(style, node) {
  const type = style.style_type || style.styleType;
  if (type === 'FILL') {
    const fills = (node.fills || []).filter((f) => f.visible !== false);
    const solid = fills.find((f) => f.type === 'SOLID');
    return {
      kind: 'color',
      row: {
        name: style.name,
        value: solid ? rgbaToHex(solid.color, solid.opacity ?? 1) : fills[0]?.type?.toLowerCase() || '',
        description: truncate(style.description, 60),
      },
    };
  }
  if (type === 'TEXT') {
    const s = node.style || {};
    return {
      kind: 'text',
      row: {
        name: style.name,
        font: s.fontFamily || '',
        size: round(s.fontSize) ?? '',
        weight: s.fontWeight ?? '',
        lineHeight: round(s.lineHeightPx) ?? '',
        letterSpacing: s.letterSpacing ? Number(s.letterSpacing.toFixed(2)) : 0,
      },
    };
  }
  if (type === 'EFFECT') {
    const effects = (node.effects || []).filter((e) => e.visible !== false);
    return {
      kind: 'effect',
      row: {
        name: style.name,
        value: effects
          .map((e) => `${e.type.toLowerCase()} ${round(e.offset?.x) || 0},${round(e.offset?.y) || 0} blur${round(e.radius) || 0} ${rgbaToHex(e.color) || ''}`)
          .join(' | '),
      },
    };
  }
  return null;
}

// Local (unpublished) styles carry no values on the styles endpoint, so find one
// node that references each style and read the value off that node.
function collectLocalStyleUsage(node, wanted, found = new Map()) {
  for (const [, styleId] of Object.entries(node.styles || {})) {
    if (wanted.has(styleId) && !found.has(styleId)) found.set(styleId, node);
  }
  for (const child of node.children || []) collectLocalStyleUsage(child, wanted, found);
  return found;
}

async function resolveScope(key, flags) {
  if (flags.from) return parseNodeIds(flags.from)[0];
  const outline = await api(`/files/${key}?depth=2`);
  const pages = outline.document.children || [];
  const needle = flags.page.toLowerCase();
  const matches = pages.filter((p) => p.id === flags.page || p.name.toLowerCase().includes(needle));
  // Divider pages hold no frames and share names with the real ones — never scan those.
  const match = matches.find((p) => (p.children || []).length) || matches[0];
  if (!match) {
    fail(`no page matching "${flags.page}"`, [
      `Run \`figma-axi file ${key}\` to list the pages`,
    ]);
  }
  return match.id;
}

async function cmdTokens(key, flags) {
  const published = (await api(`/files/${key}/styles`)).meta?.styles || [];
  let pairs = [];
  if (published.length) {
    const ids = published.map((s) => s.node_id);
    const data = await api(`/files/${key}/nodes?ids=${encodeURIComponent(ids.join(','))}&depth=1`);
    pairs = published
      .map((s) => ({ style: s, node: data.nodes[s.node_id]?.document }))
      .filter((p) => p.node);
  } else {
    // Unpublished styles carry no values, so scan real nodes for one that uses each.
    // A whole design file is usually too big for Figma to return — scope the scan.
    let root;
    let styleMap;
    if (flags.page || flags.from) {
      const scope = await resolveScope(key, flags);
      const data = await api(`/files/${key}/nodes?ids=${encodeURIComponent(scope)}`);
      const entry = data.nodes[scope];
      if (!entry) fail(`no node ${scope} in this file`, `Run \`figma-axi file ${key}\` to list ids`);
      root = entry.document;
      styleMap = entry.styles || {};
    } else {
      const file = await api(`/files/${key}`, { soft: true });
      if (file.__err) {
        // depth=2 so pages report their frames — a page with none is no use as a scan scope.
        const outline = await api(`/files/${key}?depth=2`);
        const pages = (outline.document.children || []).filter((p) => (p.children || []).length);
        fail(
          file.tooLarge
            ? 'this file is too big for Figma to return in one request'
            : `figma api ${file.__err} while reading the file`,
          [
            `Run \`figma-axi tokens ${key} --page "${pages[0]?.name.trim() || '<page>'}"\` to scan one page`,
            `Run \`figma-axi tokens ${key} --from <node-id>\` to scan one frame`,
            `Run \`figma-axi file ${key}\` to list pages and frame ids`,
          ],
        );
      }
      root = file.document;
      styleMap = file.styles || {};
    }
    const local = Object.entries(styleMap);
    if (!local.length) {
      out(
        'tokens: 0 styles defined in this scope',
        toonHelp([`Run \`figma-axi node ${key} <id>\` to read raw values off a frame`]),
      );
      return;
    }
    const usage = collectLocalStyleUsage(root, new Set(local.map(([id]) => id)));
    pairs = local
      .filter(([id]) => usage.has(id))
      .map(([id, meta]) => ({ style: { ...meta, style_type: meta.styleType }, node: usage.get(id) }));
  }

  // One library style is reachable through many node ids; identical rows are noise.
  // Rows that differ are kept: the same style name resolving to two values is real,
  // and usually means a usage site overrides it.
  const seen = new Set();
  const colors = [];
  const text = [];
  const effects = [];
  for (const { style, node } of pairs) {
    const parsed = tokenRowsFromNode(style, node);
    if (!parsed) continue;
    const fingerprint = `${parsed.kind}:${JSON.stringify(parsed.row)}`;
    if (seen.has(fingerprint)) continue;
    seen.add(fingerprint);
    if (parsed.kind === 'color') colors.push(parsed.row);
    if (parsed.kind === 'text') text.push(parsed.row);
    if (parsed.kind === 'effect') effects.push(parsed.row);
  }
  const source = published.length ? 'published styles' : 'local styles resolved from usage';
  out(
    toonObject({ source, colors: colors.length, text: text.length, effects: effects.length }),
    colors.length ? toonTable('colors', colors, ['name', 'value', 'description']) : 'colors: 0 colour styles found',
    text.length
      ? toonTable('text', text, ['name', 'font', 'size', 'weight', 'lineHeight', 'letterSpacing'])
      : 'text: 0 text styles found',
    effects.length ? toonTable('effects', effects, ['name', 'value']) : '',
  );
}

async function cmdImages(key, positional, flags) {
  if (!positional[1] && !/node-id=/.test(positional[0])) {
    fail('images requires at least one node id', COMMANDS.images.usage, 2);
  }
  const ids = parseNodeIds(positional[1] || positional[0]);
  const format = flags.format || 'png';
  if (!IMAGE_FORMATS.includes(format)) {
    fail(`--format must be one of ${IMAGE_FORMATS.join(', ')}`, COMMANDS.images.usage, 2);
  }
  const scale = flags.scale || '2';
  const query = `ids=${encodeURIComponent(ids.join(','))}&format=${encodeURIComponent(format)}&scale=${encodeURIComponent(scale)}`;
  const data = await api(`/images/${key}?${query}`);
  if (data.err) fail(`figma could not render: ${data.err}`, 'Check the node ids and --format');
  const rendered = Object.entries(data.images || {}).filter(([, url]) => url);
  if (!rendered.length) {
    fail(`no image rendered for ${ids.join(', ')}`, `Run \`figma-axi file ${key}\` to list node ids`);
  }
  if (!flags.out) {
    out(
      toonTable('images', rendered.map(([id, url]) => ({ id, url })), ['id', 'url']),
      toonHelp(['Add `--out <dir>` to download these instead of printing urls']),
    );
    return;
  }
  const unsafe = rendered.find(([, url]) => !isSafeUrl(url));
  if (unsafe) fail(`refusing non-https render url for ${unsafe[0]}: ${unsafe[1]}`, 'Re-run without --out to inspect the urls');
  const dir = resolve(flags.out);
  await mkdir(dir, { recursive: true });
  const saved = [];
  for (const [id, url] of rendered) {
    const res = await fetch(url);
    if (!res.ok) {
      fail(`download failed for ${id}: http ${res.status}`, 'Signed urls expire — re-run the command');
    }
    const path = join(dir, imageFileName(id, format));
    const bytes = Buffer.from(await res.arrayBuffer());
    await writeFile(path, bytes);
    saved.push({ id, path, bytes: bytes.length });
  }
  out(toonTable('saved', saved, ['id', 'path', 'bytes']));
}

async function cmdComments(key, flags) {
  const limit = flags.limit ?? 30;
  const data = await api(`/files/${key}/comments`);
  const all = (data.comments || []).sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
  if (!all.length) {
    out(`comments: 0 comments on this file`);
    return;
  }
  const rows = all.slice(0, limit).map((c) => ({
    id: c.id,
    user: c.user?.handle || '',
    at: (c.created_at || '').slice(0, 16).replace('T', ' '),
    resolved: Boolean(c.resolved_at),
    node: c.client_meta?.node_id || '',
    message: truncate(c.message, 160),
  }));
  out(
    `count: ${rows.length} of ${all.length} total`,
    toonTable('comments', rows, ['id', 'user', 'at', 'resolved', 'node', 'message']),
    all.length > rows.length ? toonHelp([`Run \`figma-axi comments ${key} --limit ${all.length}\` for all of them`]) : '',
  );
}

async function home() {
  const bin = process.argv[1].replace(homedir(), '~');
  const defaultKey = parseFileKey(process.env.FIGMA_FILE_KEY || '');
  out(
    toonObject({
      bin,
      description: DESCRIPTION,
      auth: token() ? 'FIGMA_TOKEN set' : 'FIGMA_TOKEN missing',
      default_file: defaultKey || '',
    }),
  );
  if (defaultKey && token()) {
    await cmdFile(defaultKey, {});
    return;
  }
  out(
    toonTable(
      'commands',
      Object.entries(COMMANDS).map(([name, c]) => ({ name, about: c.about })),
      ['name', 'about'],
    ),
    toonHelp(
      token()
        ? [
            'Run `figma-axi file <file-key|url>` to explore a file',
            'Set FIGMA_FILE_KEY=<key> to make this home view show that file',
          ]
        : [
            'Create a token at https://www.figma.com/settings > Personal access tokens',
            'Then export FIGMA_TOKEN=<token> and re-run `figma-axi`',
          ],
    ),
  );
}

async function main(argv) {
  const [command, ...rest] = argv;
  if (!command) return home();
  if (command === '--help' || command === 'help') {
    out(
      toonObject({ bin: process.argv[1].replace(homedir(), '~'), description: DESCRIPTION }),
      toonTable(
        'commands',
        Object.entries(COMMANDS).map(([name, c]) => ({ name, usage: c.usage })),
        ['name', 'usage'],
      ),
      toonHelp(['Run `figma-axi <command> --help` for flags and examples']),
    );
    return;
  }
  if (!COMMANDS[command]) {
    fail(
      `unknown command \`${command}\``,
      `valid commands: ${Object.keys(COMMANDS).join(', ')}`,
      2,
    );
  }
  const parsed = parseFlags(rest, COMMANDS[command].spec, command);
  if (parsed.error) fail(parsed.error, parsed.help, 2);
  if (parsed.flags.help) return commandHelp(command);
  const { flags, positional } = parsed;

  if (command === 'me') return cmdMe();
  const key = requireKey(positional, command);
  if (command === 'file') return cmdFile(key, flags);
  if (command === 'node') return cmdNode(key, positional, flags);
  if (command === 'styles') return cmdStyles(key);
  if (command === 'components') return cmdComponents(key);
  if (command === 'tokens') return cmdTokens(key, flags);
  if (command === 'images') return cmdImages(key, positional, flags);
  if (command === 'comments') return cmdComments(key, flags);
}

// argv[1] is the symlink in ~/.local/bin; import.meta.url is the real file.
if (import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((err) => {
    fail(err.message || String(err), 'Re-run with a valid file key, or check network access');
  });
}
