// SPDX-License-Identifier: Apache-2.0
// Builds keyholder/index.html from src/page.html, src/page.css, core.js and src/page.js. The
// script and style are inlined byte for byte, and the Content-Security-Policy allows exactly
// these inline parts by their SHA-256 hashes and nothing else (SD-155; chapter 07, 7.13).
//
//   node keyholder/build.mjs           write index.html and print its SHA-256
//   node keyholder/build.mjs --check   fail if index.html is not what the sources build
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const OUTPUT = join(here, 'index.html');

function read(path) {
  return readFileSync(join(here, path), 'utf8');
}

function cspHash(text) {
  return `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;
}

function fill(template, marker, value) {
  const parts = template.split(marker);
  if (parts.length !== 2) throw new Error(`${marker} must appear exactly once in src/page.html`);
  return parts[0] + value + parts[1];
}

export function sources() {
  return { template: read('src/page.html'), css: read('src/page.css'), core: read('core.js'), page: read('src/page.js') };
}

export function policy({ css, core, page }) {
  return [
    "default-src 'none'",
    `script-src ${cspHash(core)} ${cspHash(page)}`,
    `style-src ${cspHash(css)}`,
    'img-src data:',
    "connect-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
  ].join('; ');
}

export function build() {
  const src = sources();
  for (const [name, text] of [['core.js', src.core], ['src/page.js', src.page]]) {
    if (/<\/script/i.test(text)) throw new Error(`${name} must not contain a closing script tag`);
  }
  if (/<\/style/i.test(src.css)) throw new Error('src/page.css must not contain a closing style tag');
  let html = src.template;
  html = fill(html, '{{CSP}}', policy(src));
  html = fill(html, '{{STYLE}}', src.css);
  html = fill(html, '{{CORE}}', src.core);
  html = fill(html, '{{PAGE}}', src.page);
  return html;
}

export function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const html = build();
  if (process.argv.includes('--check')) {
    let current = '';
    try {
      current = readFileSync(OUTPUT, 'utf8');
    } catch (e) {
      current = '';
    }
    if (current !== html) {
      console.error('keyholder/index.html is out of date. Run: node keyholder/build.mjs');
      process.exit(1);
    }
    console.log(`keyholder/index.html is up to date. SHA-256 ${sha256Hex(html)}`);
  } else {
    writeFileSync(OUTPUT, html);
    console.log(`Wrote keyholder/index.html. SHA-256 ${sha256Hex(html)}`);
  }
}
