# Glint landing page

Static site for Glint's public landing page. Plain HTML, CSS and a small script, no build step and no package manager.

Intended URL: **https://drewsephski.github.io/glint/** (GitHub Pages project site; canonical URL in `index.html`).

## Files

| Path | Published | Purpose |
|---|---|---|
| `index.html` | yes | The landing page |
| `styles.css` | yes | All styles (light and dark, responsive, reduced motion) |
| `main.js` | yes | Mobile menu, copy buttons, one lane reveal. No tracking. |
| `404.html` | yes | Not-found page (uses absolute `/glint/` paths because it is served at any depth) |
| `robots.txt`, `sitemap.xml` | yes | Crawling hints |
| `assets/icon.svg`, `assets/apple-touch-icon.png` | yes | Favicon and touch icon, from `assets/icon.svg` |
| `assets/img/*.jpg` | yes | Real app screenshots resized from `docs/images/*.png`; `og.jpg` is a 1200×630 crop of `editor.png` |
| `tests/check_site.py` | no | Static checks |
| `CONTENT-CHECKLIST.md` | no | Every product claim on the page and where it comes from |
| `README.md` | no | This file |

All paths inside `index.html` are relative, so the page works under the `/glint/` project base and when opened from disk.

## Checks

```bash
python3 site/tests/check_site.py            # static: HTML structure, ids/anchors, local files, alt/size on images,
                                            # heading order, https links, release tag in download URLs,
                                            # no analytics or third-party scripts/fonts, CSS sanity, node --check main.js
python3 site/tests/check_site.py --online   # also requests every external link (skips the site's own URL until deployed)
```

Preview locally under the same base path as Pages:

```bash
mkdir -p /tmp/glint-pages/glint && rsync -a --exclude README.md --exclude CONTENT-CHECKLIST.md --exclude tests/ site/ /tmp/glint-pages/glint/
python3 -m http.server 8765 -d /tmp/glint-pages      # open http://127.0.0.1:8765/glint/
```

## Deploying

`.github/workflows/pages.yml` runs on pushes to `main` that touch `site/**` or the workflow, and on manual dispatch. It runs the static checks, copies `site/` to `_site/` without `README.md`, `CONTENT-CHECKLIST.md` and `tests/`, and deploys with the official Pages actions. Permissions: `contents: read`, `pages: write`, `id-token: write`. No secrets or paid services.

GitHub Pages is enabled with **GitHub Actions** as its source. For a fork, select that source in **Settings › Pages** before the first deployment, or run `gh api -X POST repos/OWNER/REPO/pages -f build_type=workflow`. Update the canonical URL and project base when using a different repository.

## Updating for a new release

The release version appears in the download URLs, hero, closing section, JSON-LD and the FAQ. Change `RELEASE` in `tests/check_site.py` along with them so the check catches stale links:

```bash
grep -n "0\.4\.0" site/index.html
```
