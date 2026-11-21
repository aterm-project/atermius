#!/usr/bin/env bash
# Builds the site and publishes dist/ as the only commit of the gh-pages branch,
# which GitHub Pages serves at https://aterm-project.github.io/atermius/.
# The branch holds build output only, so it is replaced on every publish.
set -euo pipefail
cd "$(dirname "$0")"
remote="${1:-$(git remote get-url origin)}"
source_commit="$(git rev-parse --short=12 HEAD)"

npm ci --no-audit --no-fund
npm run build

touch dist/.nojekyll
publish="$(mktemp -d)"
trap 'rm -rf "$publish"' EXIT
cp -a dist/. "$publish/"
git -C "$publish" init -q -b gh-pages
git -C "$publish" add -A
git -C "$publish" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -q -m "Site build from ${source_commit}"
git -C "$publish" push -f "$remote" gh-pages
