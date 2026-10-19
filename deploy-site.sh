#!/usr/bin/env bash
# Publishes docs/ (the website) to Cloudflare Pages, served at video.mistr.uk.
# Needs a Cloudflare login once: npx wrangler login
set -euo pipefail
cd "$(dirname "$0")"
npx -y wrangler@4 pages deploy docs --project-name videolibrary --branch main --commit-dirty=true
