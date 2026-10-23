#!/usr/bin/env python3
"""Builds the website's secondary pages.

- docs/changelog.html from CHANGELOG.md
- docs/<name>.html from each site-src/<name>.html (page body only; a leading
  comment's "title:" and "description:" lines set the page's title)

The header, icon sprite and footer are copied from docs/index.html so every
page stays in step. Run by deploy-site.sh before every deploy.
"""
import html
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
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
header = re.sub(r'href="#([\w-]+)"', r'href="index.html#\1"', header)



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

def write_page(name: str, title: str, description: str, body: str, generated_from: str) -> None:
    page_header = header.replace(f'<a href="{name}">', f'<a href="{name}" aria-current="page">')
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(description)}">
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
