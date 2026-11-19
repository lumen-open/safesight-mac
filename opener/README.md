<!-- SPDX-License-Identifier: Apache-2.0 -->
# The opener

The opener is your way back into your Mac if nothing else works. It opens a **recovery copy** of your Mac's hidden admin password, once the wait you chose is over, with your **Recovery Key**. It needs no SafeSight Mac server and nobody's help, and it works on any computer or phone.

It comes in two forms that do exactly the same thing:

- **A web page**: one file (`safesightmac-opener.html` in each release, `opener/index.html` in this repository), which works offline in any recent browser. SafeSight Mac saves a copy of it beside your recovery copy.
- **A command-line tool**, `safesightmac-opener`, for people who prefer a terminal.

## What you need

1. **The recovery copy.** SafeSight Mac saves it in the folder you chose when you set it up (a cloud folder is a good choice). It is a small file of 4 KB.
2. **Your Recovery Key.** It is in your password manager, in the entry named "SafeSight Mac Recovery Key" and your Mac's name. It is one line that starts with `AGE-SECRET-KEY-1`.
3. **One public number from the internet, called the time signal.** The page can get it for you, or you can get it on another device and paste it in.

## When it works

A recovery copy opens no earlier than a date set when it was saved: one full wait after the Mac last saved a copy. The opener shows that date as soon as you give it the copy.

Before that date, **nothing can open it**: not you, not anyone, not the people who made SafeSight Mac. The lock is the public time signal of the League of Entropy (the "drand quicknet" chain), which publishes a new signed number every 3 seconds. Your copy needs the number for one exact moment, and that number does not exist until the moment comes. A wrong clock on your computer changes nothing.

## Using the page

1. Open the opener page from the folder where your recovery copy is. Use that copy, or the one on the SafeSight Mac release page. **Never use an opener that someone sent you.**
2. Choose your recovery copy. The page shows the date it opens.
3. Press **Get the time signal**. The page asks a public time service for that one number. Nothing about you or your Mac is sent. If this device has no internet, open the address the page shows on another device, copy everything it shows, and paste it in.
4. Paste your Recovery Key and press **Open my copy**.
5. The page shows your Mac's admin password, and what to do next.

## Using the command-line tool

```text
safesightmac-opener <recovery copy>
```

It says when the copy opens and gives the exact address to download the time signal from, for example:

```text
curl -fsS -o round.json https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000
```

Then:

```text
safesightmac-opener <recovery copy> --round round.json
```

It checks the time signal, then asks for your Recovery Key. Nothing shows while you type or paste it; press Return. You can also give the key through a pipe, or with `--key-file <file>`. **Never type your Recovery Key on the command line itself**: your shell would save it in its history. The tool refuses if you do.

The password goes to standard output, once. Everything else goes to standard error. The tool ends with status 0 when it opened the copy, 1 when it refused, 2 when it was used wrongly, and 3 when the copy isn't ready yet.

To build it from this repository (Rust needed): `cd keeper && cargo build --release --features opener --bin safesightmac-opener`.

## After it opens

1. Start your Mac.
2. At the login window, choose the account named **SafeSight Mac administrator** and type the password. If it isn't in the list, choose **Other…** and type that name.
3. The SafeSight Mac app offers **Finish leaving** and **Stay**.
4. You have 7 days from the Mac's first start to choose. After that the password stops working, and SafeSight Mac goes on protecting the Mac.

Keep the password private: whoever has it can use the Mac as an administrator until SafeSight Mac replaces it. The opener keeps no copy of it, or of your key.

## What the opener sends

Nothing, except one request for one public number, and only when you ask for it: to `api.drand.sh` (run by Protocol Labs) or, if that one fails, `drand.cloudflare.com` (run by Cloudflare). The page's security policy allows no other connection, and the command-line tool makes none at all. Your recovery copy and your Recovery Key never leave your device.

## Checking your copy of the opener

Each release lists the SHA-256 of `safesightmac-opener.html` and of the command-line tool. To check a page you have, run `shasum -a 256 safesightmac-opener.html` (Mac or Linux) or `certutil -hashfile safesightmac-opener.html SHA256` (Windows) and compare. The page also shows its version at the bottom.

## For people who build it

| Part | Where |
|---|---|
| The core: reading the copy, the time signal and the key, and opening | `keeper/src/opener.rs`, with `keeper/src/capsule.rs`, `age.rs`, `timelock.rs` and `beacon.rs`, built only with the `opener` feature |
| The command-line tool | `keeper/src/bin/safesightmac-opener.rs`; tests in `keeper/tests/opener_cli.rs` |
| The page's core, compiled to WebAssembly | `opener/wasm/` (a handful of exported functions, no generated glue) |
| The page | `opener/src/page.html`, `page.css`, `core.js`, `page.js`, put together by `opener/build.mjs` |
| Stored version 1 recovery copies, which every later opener must open | `opener/vectors/v1.txt` (made-up keys and secrets only) |

`node opener/build.mjs` compiles the core with the Rust version pinned in `opener/wasm/rust-toolchain.toml`, takes the build machine's own folder names out of it, inlines it into the page as base64, and writes `opener/index.html`. The page's Content-Security-Policy allows its own inline style and two scripts by their SHA-256, WebAssembly, and connections to the two time-signal addresses; nothing else. The build also checks that the core uses no crate the keeper does not already use.

CI builds the page on every pull request, keeps it as the `opener-page` artifact, runs `opener/tests/page.test.mjs` on it, and fails unless the committed `opener/index.html` is byte for byte what it built. To run the tests yourself: `cargo test --features opener` in `keeper/`, `cargo test` in `opener/wasm/`, and `node --test opener/tests/*.test.mjs`.
