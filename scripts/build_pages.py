#!/usr/bin/env python3
"""Builds the website's secondary pages.

- docs/changelog.html from CHANGELOG.md
- docs/<name>.html from each site-src/<name>.html (page body only; a leading
  comment's "title:" and "description:" lines set the page's title)
- docs/manual/: one page per site-src/manual/<topic>.html (with a sidebar
  and search), plus an index of every topic and docs/manual/search.js

The header, icon sprite and footer are copied from docs/index.html so every
page stays in step. Run by deploy-site.sh before every deploy.
"""
import html
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
site = "https://video.mistr.uk"
# Every page's public URL, for the sitemap (the home page is hand-written).
sitemap_urls = [f"{site}/"]
index = (root / "docs/index.html").read_text()
changelog = (root / "CHANGELOG.md").read_text()


def block(pattern: str) -> str:
    match = re.search(pattern, index, re.S)
    if not match:
        raise SystemExit(f"docs/index.html is missing {pattern!r}")
    return match.group(0)


sprite = block(r'<svg width="0" height="0".*?</svg>')
header = block(r'<header class="header">.*?</header>')
footer = block(r'<footer class="footer">.*?</footer>')
# In-page links point back at the home page from here.
header = header.replace('href="#top"', 'href="index.html"')
# Only links: <use href="#icon"> must keep pointing at this page's sprite.
header = re.sub(r'(<a\b[^>]*?)href="#([\w-]+)"', r'\1href="index.html#\2"', header)



def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r'<span class="inline-code">\1</span>', text)
    return text


intro_lines, releases, current = [], [], None
for line in changelog.splitlines():
    if line.startswith("# "):
        continue
    heading = re.match(r"^## (\S+)(?:\s+[—-]\s+(.+))?$", line)
    if heading:
        current = {"version": heading.group(1), "date": heading.group(2) or "", "body": []}
        releases.append(current)
    elif current is None:
        if line.strip():
            intro_lines.append(line.strip())
    else:
        current["body"].append(line)


def render(lines: list[str]) -> str:
    out, in_list = [], False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- "):
            if not in_list:
                out.append('<ul class="list">')
                in_list = True
            out.append(f'<li><svg class="i"><use href="#check"/></svg><span>{inline(stripped[2:])}</span></li>')
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if stripped.startswith("### "):
            out.append(f"<h3>{inline(stripped[4:])}</h3>")
        elif stripped:
            out.append(f"<p>{inline(stripped)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


entries = []
for index_number, release in enumerate(releases):
    version = html.escape(release["version"])
    latest = ' <span class="tag">Latest</span>' if index_number == 0 else ""
    entries.append(f"""      <article class="release" id="v{version}">
        <div class="release-meta">
          <h2>{version}{latest}</h2>
          <p>{html.escape(release["date"])}</p>
        </div>
        <div class="release-body">
{render(release["body"])}
        </div>
      </article>""")

def rooted(markup: str) -> str:
    """Makes relative links root-relative, for pages inside docs/manual/."""
    return re.sub(r'(href|src)="(?!https?:|/|#|mailto:)([^"]*)"', r'\1="/\2"', markup)


def public_url(name: str) -> str:
    """Cloudflare Pages serves "a/b.html" at /a/b and "a/index.html" at /a/."""
    path = name.removesuffix(".html")
    path = path.removesuffix("index") if path.endswith("index") else path
    return f"{site}/{path}"


def write_page(name: str, title: str, description: str, body: str, generated_from: str,
               current: str | None = None, indexed: bool = True) -> None:
    url = public_url(name)
    if indexed:
        sitemap_urls.append(url)
    seo = (f"""<link rel="canonical" href="{url}">
<meta property="og:type" content="website">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(description)}">
<meta property="og:image" content="{site}/og.jpg">""" if indexed else '<meta name="robots" content="noindex">')
    page_header = header.replace(f'<a href="{current or name}">', f'<a href="{current or name}" aria-current="page">')
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(description)}">
{seo}
<meta name="theme-color" content="#0b0b0c">
<link rel="icon" href="icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="site.css">
</head>
<body>
<!-- Generated from {generated_from} by scripts/build_pages.py. Edit that file instead. -->
{sprite}

{page_header}

{body}

{footer}
<script src="site.js"></script>
</body>
</html>
"""
    if "/" in name:
        page = rooted(page)
    (root / "docs" / name).parent.mkdir(parents=True, exist_ok=True)
    (root / "docs" / name).write_text(page)
    print(f"docs/{name}")


changelog_body = f"""<main class="changelog">
  <div class="container">
    <div class="section-head">
      <h2>Changelog</h2>
      <p>{inline(" ".join(intro_lines))}</p>
    </div>
{chr(10).join(entries)}
  </div>
</main>"""
write_page("changelog.html", "Changelog · VideoLibrary", "What changed in each version of VideoLibrary for Mac.",
           changelog_body, "CHANGELOG.md")

for source in sorted((root / "site-src").glob("*.html")):
    text = source.read_text()
    meta = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    fields = dict(re.findall(r"^\s*(title|description):\s*(.+?)\s*$", meta.group(1), re.M)) if meta else {}
    body = text[meta.end():] if meta else text
    write_page(source.name, fields.get("title", "VideoLibrary"), fields.get("description", ""),
               body.strip(), f"site-src/{source.name}")


# User manual: docs/manual/index.html and one page per topic.
def front_matter(text: str) -> tuple[dict, list, str]:
    meta = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    lines = re.findall(r"^\s*(\w+):\s*(.+?)\s*$", meta.group(1), re.M) if meta else []
    return dict(lines), lines, text[meta.end():] if meta else text


manual_dir = root / "site-src/manual"
index_fields, index_lines, _ = front_matter((manual_dir / "index.html").read_text())
groups = [tuple(part.strip() for part in value.split("|", 1)) for key, value in index_lines if key == "group"]
topics = []
for source in manual_dir.glob("*.html"):
    if source.name == "index.html":
        continue
    fields, _, body = front_matter(source.read_text())
    topics.append({"slug": source.stem, "body": body.strip(), **fields})
topics.sort(key=lambda topic: int(topic.get("order", 999)))
for topic in topics:
    if topic["group"] not in [name for name, _ in groups]:
        raise SystemExit(f"site-src/manual/{topic['slug']}.html: unknown group {topic['group']!r}")


def icon(name: str) -> str:
    return f'<svg class="i"><use href="#{name}"/></svg>'


def plain(markup: str) -> str:
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", markup))).strip()


def search_box(placeholder: str = "Search the manual") -> str:
    return f"""<label class="msearch">{icon("search")}<input type="search" placeholder="{placeholder}" aria-label="Search the manual" autocomplete="off" spellcheck="false" data-manual-search><kbd>/</kbd></label>"""


def card(topic: dict) -> str:
    return f"""<a class="mcard" href="/manual/{topic['slug']}">
          <span class="mcard-icon">{icon(topic.get('icon', 'book'))}</span>
          <span><span class="mcard-title">{topic['title']}</span><span class="mcard-text">{topic['summary']}</span></span>
        </a>"""


sections = []
for name, blurb in groups:
    cards = "\n        ".join(card(topic) for topic in topics if topic["group"] == name)
    sections.append(f"""    <section class="mgroup" data-group>
      <div class="mgroup-head"><h2>{name}</h2><p>{blurb}</p></div>
      <div class="mcards">
        {cards}
      </div>
    </section>""")

first = topics[0]
shortcuts = next((topic for topic in topics if topic["slug"] == "keyboard-shortcuts"), first)
index_body = f"""<main class="mindex">
  <div class="mcontainer">
    <div class="mhero">
      <div>
        <h1>{index_fields['title']}</h1>
        <p>{index_fields['intro']}</p>
        <div class="mhero-actions">
          <a class="btn btn-light" href="/manual/{first['slug']}">{first['title']}</a>
          <a class="btn btn-secondary" href="/manual/{shortcuts['slug']}">{shortcuts['title']}</a>
        </div>
      </div>
      {search_box()}
    </div>
    <div class="mresults" hidden data-manual-results></div>
{chr(10).join(sections)}
  </div>
</main>
<script>
// Links to the old one-page manual (manual#sabr) open the topic's page.
(function () {{
  var old = {{"shortcuts": "keyboard-shortcuts", "watching": "player", "files-out": "getting-videos-out", "sharing": "wifi-sharing", "files": "where-files-live"}};
  var hash = location.hash.slice(1);
  if (hash) location.replace("/manual/" + (old[hash] || hash));
}})();
</script>
<script src="/manual/search.js"></script>"""
write_page("manual/index.html", f"{index_fields['title']}", index_fields.get("description", ""),
           index_body, "site-src/manual/", current="manual/")


def sidebar(active: str) -> str:
    parts = []
    for name, _ in groups:
        links = "".join(
            f"""<a href="/manual/{topic['slug']}"{' aria-current="page"' if topic['slug'] == active else ''} data-slug="{topic['slug']}">{topic['title']}</a>"""
            for topic in topics if topic["group"] == name)
        parts.append(f"""<div class="mside-group" data-group><p>{name}</p>{links}</div>""")
    return f"""<aside class="mside">
      <a class="mside-home" href="/manual/">{icon("book")}<span>VideoLibrary Manual</span></a>
      {search_box("Search")}
      <nav class="mside-nav" aria-label="Manual">{"".join(parts)}<p class="mside-empty" hidden data-manual-empty>No matches</p></nav>
    </aside>"""


for number, topic in enumerate(topics):
    previous = topics[number - 1] if number > 0 else None
    following = topics[number + 1] if number + 1 < len(topics) else None
    pager = "".join([
        f"""<a class="mpager-prev" href="/manual/{previous['slug']}"><span>{icon("arrow-left")}Previous</span>{previous['title']}</a>""" if previous else "<span></span>",
        f"""<a class="mpager-next" href="/manual/{following['slug']}"><span>Next{icon("arrow-right")}</span>{following['title']}</a>""" if following else "<span></span>",
    ])
    body = f"""<main class="mpage">
  <div class="mcontainer mlayout">
    {sidebar(topic['slug'])}
    <article class="mdoc">
      <p class="mdoc-eyebrow">{topic['group']}</p>
      <h1>{topic['title']}</h1>
      <p class="mdoc-lede">{topic['summary']}</p>
      <div class="mdoc-body">
{topic['body']}
      </div>
      <nav class="mpager" aria-label="More topics">{pager}</nav>
    </article>
  </div>
</main>
<script src="/manual/search.js"></script>"""
    write_page(f"manual/{topic['slug']}.html", f"{topic['title']} · VideoLibrary Manual", topic["summary"],
               body, f"site-src/manual/{topic['slug']}.html", current="manual/")

search_index = [{"slug": t["slug"], "title": t["title"], "group": t["group"], "icon": t.get("icon", "book"),
                 "summary": t["summary"], "text": plain(t["body"])} for t in topics]
(root / "docs/manual/search.js").write_text(
    "// Generated by scripts/build_pages.py from site-src/manual/.\n"
    f"window.MANUAL_TOPICS = {json.dumps(search_index, ensure_ascii=False)};\n"
    + (root / "scripts/manual-search.js").read_text())
print("docs/manual/search.js")


# Cloudflare Pages answers unknown paths with the home page and a 200 unless
# there's a 404.html; a real 404 keeps search engines from indexing them.
write_page("404.html", "Page not found · VideoLibrary", "", """<main class="notfound">
  <div class="container">
    <h1>Page not found</h1>
    <p>That page doesn't exist. Try the <a href="/">home page</a> or the <a href="/manual/">manual</a>.</p>
  </div>
</main>""", "scripts/build_pages.py", indexed=False)
(root / "docs/404.html").write_text(rooted((root / "docs/404.html").read_text()))

(root / "docs/sitemap.xml").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    + "".join(f"  <url><loc>{url}</loc></url>\n" for url in sitemap_urls)
    + "</urlset>\n")
(root / "docs/robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {site}/sitemap.xml\n")
print("docs/404.html, docs/sitemap.xml, docs/robots.txt")
