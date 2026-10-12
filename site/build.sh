#!/bin/sh
# Builds the site into site/dist.
#
# The output is plain static files: index.html, site.css, the Markdown pages
# and images from public/, and the compiled Gleam modules under js/. Host the
# dist directory with any static file server, or publish it to GitHub Pages.
#
# Usage: ./build.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

gleam build --target javascript

rm -rf dist
mkdir -p dist/js
cp index.html dist/index.html
cp -R public/. dist/

# Copy only the compiled ES modules, keeping the package layout that their
# relative imports expect. Erlang sources and build caches are left out.
rsync -am --include='*/' --include='*.mjs' --exclude='*' \
  build/dev/javascript/ dist/js/

# GitHub Pages runs Jekyll unless told not to, and Jekyll hides files that
# start with an underscore.
touch dist/.nojekyll

echo "built $here/dist"
