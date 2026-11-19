<!-- SPDX-License-Identifier: Apache-2.0 -->
# The SafeSight Mac website

Two static pages: `index.html` (the home page) and `terms.html` (terms and risks). There's no build step and nothing to install. Each page carries its own CSS, uses the system fonts, has no scripts, and loads nothing from any other site.

## Preview it

Open `site/index.html` in any browser. Everything works from the file, links between the two pages included.

To see it as a web server would serve it:

```sh
python3 -m http.server 8000 --directory site
```

then visit <http://localhost:8000>. Switch your Mac between light and dark appearance to see both themes.

## Check it

```sh
node site/check.mjs
```

The check needs Node 18 or later and nothing else. It fails if:

- a page links or loads anything outside `github.com/lumen-open`, `shiftyourphone.com` and the Apache licence text, or a local link or `#anchor` points nowhere;
- a page uses a phrase the project never uses ("can't be bypassed", "100%", "blocks all", "treats addiction", "nobody can ever unlock it") or claims it is tested, audited or unbeatable;
- the home page is missing the "Why it exists" text or the "free forever" sentence, or its "Why it exists" paragraphs and promise no longer match `README.md` word for word;
- a page has no Content-Security-Policy, or one that allows more than its own inline styles.

## Changing it

- **Words.** The home page follows `README.md`. "Why it exists" and the promise are copied word for word, and the check compares them, so change them in the README first. The terms page follows `TERMS-AND-RISKS.md` (version 0.1, on the `terms-page` branch); when that file changes, change `terms.html` with it.
- **Styles.** The CSP allows each page's `<style>` block by its hash. After editing the CSS, run `node site/check.mjs --print-csp` and put the new hash in that page's `Content-Security-Policy` meta tag. Until you do, the check fails and the page shows unstyled.
- **Colours and type.** Both pages carry the desert study (`DESIGN-desert.md` at the top of the repository): lime plaster, malachite and a little gold leaf, with serif headings from the system's own fonts. The colours are variables at the top of each style block, with the dark theme underneath. The study isn't merged; Lumen is in the history if the owner keeps it.
- **No scripts, no trackers.** The CSP blocks scripts, and the footer promises that the site sets no cookies and loads nothing from anywhere else. Keep it that way.

## Publishing

The site isn't published anywhere yet. Whether and where to publish it (GitHub Pages, for example) is a later decision for the owner. Nothing in this folder turns publishing on, and the pages will work as they are on any static host.
