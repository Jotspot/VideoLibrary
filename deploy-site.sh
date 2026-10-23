#!/usr/bin/env bash
# Publishes docs/ (the website) to Cloudflare Pages, served at video.mistr.uk.
# Needs a Cloudflare login once: npx wrangler login
set -euo pipefail
cd "$(dirname "$0")"

# Stamp the app version from Info.plist into the pages (they also check
# the latest GitHub release when it loads).
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
sed -i '' -E "s#<span data-version>[^<]*</span>#<span data-version>${VERSION}</span>#g" docs/index.html site-src/*.html

# The changelog and install-guide pages are generated (scripts/build_pages.py).
python3 scripts/build_pages.py

npx -y wrangler@4 pages deploy docs --project-name videolibrary --branch main --commit-dirty=true
