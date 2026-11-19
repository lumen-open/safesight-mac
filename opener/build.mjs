// SPDX-License-Identifier: Apache-2.0
// Builds opener/index.html (SD-066): the opener page, one self-contained file.
//
// 1. Checks that the page's core adds no crate: every crate in opener/wasm/Cargo.lock is
//    in keeper/Cargo.lock, at the same version and checksum.
// 2. Compiles the core (opener/wasm) to WebAssembly with the toolchain pinned in
//    opener/wasm/rust-toolchain.toml, with the build machine's own paths taken out of the
//    output, so that the same sources give the same bytes wherever they are built.
// 3. Asks the core for its version and its mirrors, and writes the page: src/page.html
//    with src/page.css, src/core.js, src/page.js and the core (base64) inlined. The
//    Content-Security-Policy allows exactly those inline parts, by their SHA-256 hashes,
//    WebAssembly, and connections to the core's mirrors, and nothing else.
//
//   node opener/build.mjs                  compile, write opener/index.html, print hashes
//   node opener/build.mjs --out <file>     write the page there instead
//   node opener/build.mjs --check          compile, and fail if opener/index.html differs
//   node opener/build.mjs --wasm <file>    use this core instead of compiling one
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
export const PAGE = join(here, 'index.html');
export const WASM_DIR = join(here, 'wasm');
export const WASM_OUT = join(WASM_DIR, 'target', 'wasm32-unknown-unknown', 'release', 'safesightmac_opener_wasm.wasm');
const OWN_CRATES = new Set(['safesightmac-keeper', 'safesightmac-opener-wasm']);
const WASM_LINE = 100;

function read(path) {
  return readFileSync(join(here, path), 'utf8');
}

export function sha256Hex(data) {
  return createHash('sha256').update(data).digest('hex');
}

function cspHash(text) {
  return `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;
}

// ----- 1. No new crate -----

function lockPackages(text) {
  const out = new Map();
  for (const block of text.split('[[package]]').slice(1)) {
    const field = (name) => {
      const m = block.match(new RegExp(`^${name} = "([^"]*)"`, 'm'));
      return m ? m[1] : null;
    };
    out.set(`${field('name')} ${field('version')}`, { name: field('name'), source: field('source'), checksum: field('checksum') });
  }
  return out;
}

export function checkLock() {
  const keeper = lockPackages(readFileSync(join(repo, 'keeper', 'Cargo.lock'), 'utf8'));
  const page = lockPackages(readFileSync(join(WASM_DIR, 'Cargo.lock'), 'utf8'));
  const problems = [];
  for (const [id, p] of page) {
    if (OWN_CRATES.has(p.name)) {
      if (p.source !== null) problems.push(`${id} must be the repository's own crate`);
      continue;
    }
    const k = keeper.get(id);
    if (!k) problems.push(`${id} is not in keeper/Cargo.lock`);
    else if (k.source !== p.source || k.checksum !== p.checksum) problems.push(`${id} differs from keeper/Cargo.lock`);
  }
  if (problems.length) throw new Error(`The page's core may only use the keeper's crates:\n  ${problems.join('\n  ')}`);
  return page.size;
}

// ----- 2. The core -----

export function compile() {
  const cargoHome = process.env.CARGO_HOME || join(homedir(), '.cargo');
  const flags = [`--remap-path-prefix=${repo}=/safesight-mac`, `--remap-path-prefix=${cargoHome}=/cargo`];
  const env = { ...process.env, CARGO_ENCODED_RUSTFLAGS: flags.join('\x1f'), CARGO_INCREMENTAL: '0' };
  delete env.RUSTFLAGS;
  execFileSync('cargo', ['build', '--release', '--locked', '--target', 'wasm32-unknown-unknown'], {
    cwd: WASM_DIR,
    env,
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  return readFileSync(WASM_OUT);
}

export async function describe(wasm) {
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const x = instance.exports;
  x.ss_about();
  const bytes = new Uint8Array(x.memory.buffer, x.ss_output_ptr() >>> 0, x.ss_output_len() >>> 0);
  const about = JSON.parse(new TextDecoder().decode(bytes));
  for (const m of about.mirrors) {
    if (!/^https:\/\/[a-z0-9.-]+$/.test(m)) throw new Error(`a mirror must be a plain https origin: ${m}`);
  }
  if (about.mirrors.length < 2) throw new Error('the core names fewer than two mirrors');
  return about;
}

// ----- 3. The page -----

export function sources() {
  return { template: read('src/page.html'), css: read('src/page.css'), core: read('src/core.js'), page: read('src/page.js') };
}

export function policy({ css, core, page }, mirrors) {
  return [
    "default-src 'none'",
    `script-src ${cspHash(core)} ${cspHash(page)} 'wasm-unsafe-eval'`,
    `style-src ${cspHash(css)}`,
    'img-src data:',
    `connect-src ${mirrors.join(' ')}`,
    "base-uri 'none'",
    "form-action 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
  ].join('; ');
}

function fill(template, marker, value) {
  const parts = template.split(marker);
  if (parts.length !== 2) throw new Error(`${marker} must appear exactly once in src/page.html`);
  return parts[0] + value + parts[1];
}

function wrapped(base64) {
  const lines = [];
  for (let i = 0; i < base64.length; i += WASM_LINE) lines.push(base64.slice(i, i + WASM_LINE));
  return lines.join('\n');
}

export function assemble(wasm, about, src = sources()) {
  for (const [name, text] of [['src/core.js', src.core], ['src/page.js', src.page]]) {
    if (/<\/script/i.test(text)) throw new Error(`${name} must not contain a closing script tag`);
  }
  if (/<\/style/i.test(src.css)) throw new Error('src/page.css must not contain a closing style tag');
  let html = src.template;
  html = fill(html, '{{CSP}}', policy(src, about.mirrors));
  html = fill(html, '{{STYLE}}', src.css);
  html = fill(html, '{{WASM}}', wrapped(Buffer.from(wasm).toString('base64')));
  html = fill(html, '{{CORE_JS}}', src.core);
  html = fill(html, '{{PAGE_JS}}', src.page);
  return html;
}

// ----- Command line -----

const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const args = process.argv.slice(2);
  const value = (name) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const crates = checkLock();
  console.log(`Crates: ${crates}, none beyond the keeper's.`);
  const wasmPath = value('--wasm');
  const wasm = wasmPath ? readFileSync(wasmPath) : compile();
  const about = await describe(wasm);
  const html = assemble(wasm, about);
  console.log(`Core:   ${wasm.length} bytes, SHA-256 ${sha256Hex(wasm)}`);
  console.log(`Page:   ${Buffer.byteLength(html)} bytes, SHA-256 ${sha256Hex(html)} (opener ${about.version})`);
  if (args.includes('--check')) {
    let current = '';
    try {
      current = readFileSync(PAGE, 'utf8');
    } catch (e) {
      current = '';
    }
    if (current !== html) {
      console.error(`opener/index.html is not what the sources build (committed SHA-256 ${sha256Hex(current)}).`);
      process.exit(1);
    }
    console.log('opener/index.html is what the sources build.');
  } else {
    const out = value('--out') || PAGE;
    mkdirSync(dirname(resolve(out)), { recursive: true });
    writeFileSync(out, html);
    console.log(`Wrote ${out}`);
  }
}
