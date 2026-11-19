// SPDX-License-Identifier: Apache-2.0
// Checks the static website in this folder. No dependencies; run with Node 18 or later:
//
//   node site/check.mjs               check every page, exit 1 on any failure
//   node site/check.mjs --print-csp   print the style hashes each page's CSP needs
//
// It fails on:
//   - any external URL in src/href (or similar attributes, or CSS url()) other than
//     github.com/lumen-open, shiftyourphone.com and the Apache licence text;
//   - local links or #anchors that point nowhere;
//   - phrases the project never uses, and claims it never makes;
//   - the "Why it exists" text or the "free forever" sentence missing from the home page
//     (and, when ../README.md is present, any of its "Why it exists" paragraphs or its
//     promise not appearing word for word);
//   - a missing or loose Content-Security-Policy, or one whose style hashes don't match;
//   - a missing SPDX line, lang, title or viewport.

import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const PAGES = ['index.html', 'terms.html'];

const ALLOWED_EXTERNAL = [
  'https://github.com/lumen-open/',
  'https://shiftyourphone.com/',
  'https://www.apache.org/licenses/LICENSE-2.0',
];

// Matched against the visible text (and alt, title, aria-label and meta content),
// lower-cased, with curly quotes made straight.
const FORBIDDEN = [
  [/\bcan(?:'t| ?not) be (?:bypassed|beaten|got around|gotten around|circumvented)/, "can't be bypassed"],
  [/\bimpossible to (?:bypass|get around|circumvent)/, 'impossible to bypass'],
  [/\bbypass-?proof\b/, 'bypass-proof'],
  [/\bblocks? all\b/, 'blocks all'],
  [/\btreats? addiction\b/, 'treats addiction'],
  [/\bcures? addiction\b/, 'cures addiction'],
  [/\b(?:nobody|no one|no-one) can ever unlock it\b/, 'nobody can ever unlock it'],
  [/\b100 ?(?:%|percent\b|per cent\b)/, '100%'],
  [/\bunbeatable\b/, 'unbeatable'],
  [/\baudited\b/, 'audited'],
  [/\btested\b/, 'tested (the site never claims it is tested)'],
];

// Always required on the home page, even without the README beside it.
const REQUIRED_HOME = [
  ['why it exists', 'the "Why it exists" heading'],
  ['pornography is the most patient thing ever built.', 'the "Why it exists" opening'],
  ['being the same person at midnight that you were at noon.', 'the "Why it exists" closing line'],
  ["it's free forever.", 'the "free forever" sentence'],
  ['nobody else can, including us.', 'the promise'],
];

const failures = [];
const fail = (page, msg) => failures.push(`${page}: ${msg}`);

const sha256 = (s) => `'sha256-${createHash('sha256').update(s, 'utf8').digest('base64')}'`;

function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&nbsp;/g, ' ')
    .replace(/&quot;/g, '"')
    .replace(/&apos;|&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function normalise(s) {
  return s
    .replace(/[‘’ʼ]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[   ]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

const INLINE_TAGS = /^(a|strong|em|b|i|code|abbr|time|small|mark|q|cite|sub|sup)$/i;

function visibleText(html) {
  let s = html
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ');
  const extra = [];
  for (const m of s.matchAll(/\s(?:alt|title|aria-label|content)\s*=\s*"([^"]*)"/gi)) extra.push(m[1]);
  s = s.replace(/<\/?([a-z][a-z0-9-]*)\b[^>]*>/gi, (_, tag) => (INLINE_TAGS.test(tag) ? '' : ' '));
  return normalise(decodeEntities(`${s} ${extra.join(' ')}`));
}

function stripMarkdown(s) {
  return s
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1');
}

// Paragraphs under a "## Heading" in the README, as plain text.
function readmeSection(md, heading) {
  const lines = md.split('\n');
  const start = lines.findIndex((l) => l.trim() === `## ${heading}`);
  if (start < 0) return null;
  const body = [];
  for (const l of lines.slice(start + 1)) {
    if (/^#{1,2} /.test(l)) break;
    body.push(l.replace(/^>\s?/, ''));
  }
  return body
    .join('\n')
    .split(/\n\s*\n/)
    .map((p) => normalise(stripMarkdown(p)))
    .filter(Boolean);
}

function attrValues(html) {
  const out = [];
  const tagRe = /<([a-z][a-z0-9-]*)\b([^>]*)>/gi;
  for (const t of html.matchAll(tagRe)) {
    const [, tag, attrs] = t;
    for (const a of attrs.matchAll(/\s([a-z:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
      const name = a[1].toLowerCase();
      const value = decodeEntities(a[2] ?? a[3] ?? a[4] ?? '');
      if (['src', 'href', 'xlink:href', 'action', 'formaction', 'poster', 'data', 'cite', 'background', 'manifest', 'ping', 'longdesc'].includes(name)) {
        out.push({ tag: tag.toLowerCase(), name, value });
      } else if (name === 'srcset') {
        for (const part of value.split(',')) out.push({ tag, name, value: part.trim().split(/\s+/)[0] });
      }
    }
  }
  return out;
}

function cssUrls(css) {
  const out = [];
  for (const m of css.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi)) out.push(m[2].trim());
  for (const m of css.matchAll(/@import\s+(?:url\()?\s*['"]?([^'");\s]+)/gi)) out.push(m[1].trim());
  return out;
}

const idsOf = (html) => new Set([...html.matchAll(/\sid\s*=\s*"([^"]+)"/gi)].map((m) => m[1]));

function checkUrl(page, html, value, where) {
  if (value === '') return fail(page, `empty URL in ${where}`);
  if (value.startsWith('#')) {
    const id = decodeURIComponent(value.slice(1));
    if (id && !idsOf(html).has(id)) fail(page, `${where} points to #${id}, which isn't on the page`);
    return;
  }
  if (/^data:/i.test(value)) {
    if (!/^data:image\//i.test(value)) fail(page, `${where} uses a data: URL that isn't an image`);
    return;
  }
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith('//')) {
    const ok = ALLOWED_EXTERNAL.some((p) => value.startsWith(p));
    if (!ok) fail(page, `${where} links outside the allowed list: ${value}`);
    return;
  }
  const [path, frag] = value.split('#');
  const file = join(here, path.split('?')[0]);
  if (!existsSync(file)) return fail(page, `${where} points to a missing file: ${value}`);
  if (frag && file.endsWith('.html') && !idsOf(readFileSync(file, 'utf8')).has(frag)) {
    fail(page, `${where} points to #${frag} in ${path}, which isn't there`);
  }
}

function parseCsp(content) {
  const map = new Map();
  for (const part of content.split(';')) {
    const [name, ...vals] = part.trim().split(/\s+/);
    if (name) map.set(name.toLowerCase(), vals);
  }
  return map;
}

function checkCsp(page, html) {
  const metas = [...html.matchAll(/<meta\b[^>]*http-equiv\s*=\s*"content-security-policy"[^>]*>/gi)];
  if (metas.length !== 1) return fail(page, `needs exactly one Content-Security-Policy meta tag (found ${metas.length})`);
  const meta = metas[0];
  const head = html.slice(0, html.search(/<\/head>/i));
  if (meta.index > head.length) return fail(page, 'the CSP meta tag must be inside <head>');
  const firstLoad = head.search(/<(style|link|script)\b/i);
  if (firstLoad >= 0 && firstLoad < meta.index) fail(page, 'the CSP meta tag must come before any <style>, <link> or <script>');
  const content = decodeEntities((meta[0].match(/content\s*=\s*"([^"]*)"/i) || [])[1] || '');
  const csp = parseCsp(content);

  if ((csp.get('default-src') || []).join(' ') !== "'none'") fail(page, "CSP must start from default-src 'none'");
  if ((csp.get('base-uri') || []).join(' ') !== "'none'") fail(page, "CSP needs base-uri 'none'");
  if ((csp.get('form-action') || []).join(' ') !== "'none'") fail(page, "CSP needs form-action 'none'");
  for (const [name, vals] of csp) {
    for (const v of vals) {
      const okToken = v === "'none'" || /^'sha(256|384|512)-[A-Za-z0-9+/=]+'$/.test(v) || (name === 'img-src' && v === 'data:');
      if (!okToken) fail(page, `CSP ${name} allows "${v}"; only 'none', hashes and (for images) data: are allowed`);
    }
  }

  const styles = [...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]);
  const styleSrc = csp.get('style-src') || [];
  for (const s of styles) {
    const h = sha256(s);
    if (!styleSrc.includes(h)) fail(page, `CSP style-src doesn't match the page's <style>; it should list ${h}`);
  }
  if (styles.length === 0 && styleSrc.length) fail(page, 'CSP allows styles but the page has none');
  if (/<[a-z][^>]*\sstyle\s*=/i.test(html)) fail(page, 'style="" attributes are blocked by the CSP; use a class instead');

  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  const scriptSrc = csp.get('script-src') || [];
  for (const [, attrs, body] of scripts) {
    if (/\ssrc\s*=/i.test(attrs)) fail(page, 'scripts must be inline (no src)');
    else if (!scriptSrc.includes(sha256(body))) fail(page, `inline <script> isn't allowed by the CSP; script-src would need ${sha256(body)}`);
  }
  if (/\son[a-z]+\s*=/i.test(html.replace(/<!--[\s\S]*?-->/g, ''))) fail(page, 'inline event handlers (onclick= and so on) are not allowed');
}

function checkBasics(page, html) {
  if (!/^<!-- SPDX-License-Identifier: Apache-2\.0 -->/.test(html)) fail(page, 'must start with the SPDX licence comment');
  if (!/<html\b[^>]*\slang="[a-z]{2}(-[A-Z]{2})?"/.test(html)) fail(page, '<html> needs a lang attribute');
  if (!/<title>[^<]+<\/title>/i.test(html)) fail(page, 'needs a <title>');
  if (!/<meta\s+name="viewport"/i.test(html)) fail(page, 'needs a viewport meta tag');
  const h1s = (html.match(/<h1\b/gi) || []).length;
  if (h1s !== 1) fail(page, `needs exactly one <h1> (found ${h1s})`);
}

if (process.argv.includes('--print-csp')) {
  for (const page of PAGES) {
    const html = readFileSync(join(here, page), 'utf8');
    const hashes = [...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => sha256(m[1]));
    console.log(`${page}: style-src ${hashes.join(' ')}`);
  }
  process.exit(0);
}

for (const page of PAGES) {
  const file = join(here, page);
  if (!existsSync(file)) { fail(page, 'missing'); continue; }
  const html = readFileSync(file, 'utf8');

  checkBasics(page, html);
  checkCsp(page, html);

  for (const { tag, name, value } of attrValues(html)) checkUrl(page, html, value, `<${tag} ${name}>`);
  const css = [...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]).join('\n');
  for (const u of cssUrls(css)) checkUrl(page, html, u, 'CSS url()');

  const text = visibleText(html);
  for (const [re, label] of FORBIDDEN) {
    const m = text.match(re);
    if (m) fail(page, `uses a phrase the project never uses: "${label}" (…${text.slice(Math.max(0, m.index - 40), m.index + 50)}…)`);
  }

  if (page === 'index.html') {
    for (const [needle, label] of REQUIRED_HOME) {
      if (!text.includes(needle)) fail(page, `missing ${label}: "${needle}"`);
    }
    const readme = join(here, '..', 'README.md');
    if (existsSync(readme)) {
      const md = readFileSync(readme, 'utf8');
      for (const [heading, label] of [['Why it exists', '"Why it exists"'], ['Our promise', 'promise']]) {
        const paras = readmeSection(md, heading);
        if (!paras) { fail(page, `README.md has no "## ${heading}" section to compare against`); continue; }
        paras.forEach((p, i) => {
          if (!text.includes(p)) fail(page, `${label} paragraph ${i + 1} doesn't match README.md word for word: "${p.slice(0, 70)}…"`);
        });
      }
    }
  }
}

if (failures.length) {
  console.error(`Site check failed (${failures.length}):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(`Site check passed: ${PAGES.join(', ')} (links, wording, purpose text, free forever, CSP).`);
