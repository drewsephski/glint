#!/usr/bin/env python3
"""Static checks for the Glint landing page. Standard library only.

Usage:  python3 site/tests/check_site.py [--online]

Checks:
  * HTML parses; no duplicate ids; in-page #anchors and aria-controls/labelledby resolve
  * every local src/href exists inside site/ and is relative (works under /glint/)
  * images have alt and width/height; one h1; heading levels don't skip
  * external links use https; download links point at the release named in RELEASE
  * no analytics/tracking scripts, no third-party scripts or fonts
  * CSS braces balance and declares reduced-motion and focus-visible rules
  * main.js passes `node --check` when node is installed
  * --online: HEAD-checks external URLs (GitHub) and fails on non-2xx/3xx
"""
import os
import re
import subprocess
import sys
import urllib.request
from html.parser import HTMLParser

SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGES = ["index.html", "404.html"]
RELEASE = "v0.4.0"
errors = []


def err(msg):
    errors.append(msg)


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids, self.refs, self.links, self.imgs, self.headings = [], [], [], [], []
        self.scripts, self.aria = [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.append(a["id"])
        for k in ("href", "src"):
            if k in a and a[k] is not None:
                self.links.append((tag, k, a[k]))
        if tag == "img":
            self.imgs.append(a)
        if re.fullmatch(r"h[1-6]", tag):
            self.headings.append(int(tag[1]))
        if tag == "script":
            self.scripts.append(a)
        for k in ("aria-controls", "aria-labelledby", "aria-describedby", "data-copy-target"):
            if a.get(k):
                self.aria.extend((k, v) for v in a[k].split())


external = set()
for name in PAGES:
    path = os.path.join(SITE, name)
    if not os.path.exists(path):
        err(f"{name}: missing")
        continue
    html = open(path, encoding="utf-8").read()
    p = Page()
    p.feed(html)
    p.close()

    if not html.lower().startswith("<!doctype html>"):
        err(f"{name}: missing <!doctype html>")
    if '<html lang="' not in html:
        err(f"{name}: <html> needs lang")
    dupes = {i for i in p.ids if p.ids.count(i) > 1}
    if dupes:
        err(f"{name}: duplicate ids {sorted(dupes)}")
    ids = set(p.ids)
    for k, v in p.aria:
        if v not in ids:
            err(f"{name}: {k}={v!r} has no matching id")

    for tag, attr, url in p.links:
        if url.startswith("#"):
            if len(url) > 1 and url[1:] not in ids:
                err(f"{name}: anchor {url} has no target")
        elif re.match(r"^[a-z]+:", url):
            if url.startswith("http://"):
                err(f"{name}: insecure link {url}")
            if url.startswith("https://"):
                external.add(url)
                if tag == "script":
                    err(f"{name}: third-party script {url}")
                if "fonts.googleapis" in url or "fonts.gstatic" in url:
                    err(f"{name}: third-party font {url}")
        else:
            if url.startswith("/glint/") and name == "404.html":
                # 404.html is served at arbitrary depths, so it uses the project base explicitly.
                url = url[len("/glint/"):]
            elif url.startswith("/"):
                err(f"{name}: root-absolute path {url} breaks under /glint/")
                continue
            local = os.path.normpath(os.path.join(SITE, url.split("#")[0].split("?")[0] or "index.html"))
            if not local.startswith(SITE) or not os.path.exists(local):
                err(f"{name}: local {attr}={url} not found")

    for img in p.imgs:
        if "alt" not in img:
            err(f"{name}: <img src={img.get('src')}> missing alt")
        if not (img.get("width") and img.get("height")):
            err(f"{name}: <img src={img.get('src')}> missing width/height")

    if p.headings.count(1) != 1:
        err(f"{name}: expected exactly one h1, found {p.headings.count(1)}")
    for prev, cur in zip(p.headings, p.headings[1:]):
        if cur > prev + 1:
            err(f"{name}: heading jumps from h{prev} to h{cur}")

    if re.search(r"google-analytics|googletagmanager|gtag\(|plausible|segment\.com|hotjar|mixpanel|posthog", html, re.I):
        err(f"{name}: analytics/tracking reference found")

    for m in re.finditer(r"releases/download/(v[\d.]+)/", html):
        if m.group(1) != RELEASE:
            err(f"{name}: download link points at {m.group(1)}, expected {RELEASE}")

# Required SEO bits on the main page
index = open(os.path.join(SITE, "index.html"), encoding="utf-8").read()
for needle in ('<link rel="canonical" href="https://drewsephski.github.io/glint/">',
               'property="og:image"', '<meta name="description"', '<meta name="viewport"', 'rel="icon"'):
    if needle not in index:
        err(f"index.html: missing {needle}")

# CSS sanity
css = open(os.path.join(SITE, "styles.css"), encoding="utf-8").read()
css_nocomments = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
if css_nocomments.count("{") != css_nocomments.count("}"):
    err("styles.css: unbalanced braces")
for needle in ("prefers-reduced-motion", ":focus-visible", "@media (max-width"):
    if needle not in css:
        err(f"styles.css: missing {needle}")
for m in re.finditer(r"url\(([^)]+)\)", css_nocomments):
    u = m.group(1).strip("'\"")
    if not u.startswith("data:") and not os.path.exists(os.path.join(SITE, u)):
        err(f"styles.css: url({u}) not found")

# JS syntax
js = os.path.join(SITE, "main.js")
try:
    r = subprocess.run(["node", "--check", js], capture_output=True, text=True)
    if r.returncode != 0:
        err(f"main.js: node --check failed\n{r.stderr}")
except FileNotFoundError:
    print("note: node not installed, skipped JS syntax check")

# Optional: external links
if "--online" in sys.argv:
    for url in sorted(external):
        if url.startswith("https://drewsephski.github.io/glint/"):
            print(f"skip {url} (this site; verify after deploy)")
            continue
        try:
            req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "site-link-check"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                code = resp.status
        except urllib.error.HTTPError as e:
            code = e.code
            if code >= 500:  # retry once with GET for transient GitHub errors
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "site-link-check"}), timeout=20) as resp:
                        code = resp.status
                except urllib.error.HTTPError as e2:
                    code = e2.code
        except Exception as e:  # noqa: BLE001
            err(f"online: {url} -> {e}")
            continue
        ok = 200 <= code < 400
        print(f"{'ok ' if ok else 'BAD'} {code} {url}")
        if not ok:
            err(f"online: {url} -> HTTP {code}")

if errors:
    print("FAIL")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print(f"OK: {', '.join(PAGES)} passed static checks ({len(external)} external links{' verified' if '--online' in sys.argv else ' not fetched'})")
