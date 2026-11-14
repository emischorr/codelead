#!/usr/bin/env bash
# Rebuilds every raster asset in media/logos from the SVG masters in svg/,
# and refreshes the copies the app serves from priv/static.
# Requires inkscape and ImageMagick (`magick`); optipng is used when present.
set -euo pipefail

cd "$(dirname "$0")"
SVG=svg
PNG=png
STATIC=../../priv/static
mkdir -p "$PNG"

render() { # src out width [height]
  if [ -n "${4:-}" ]; then
    inkscape "$1" --export-type=png --export-filename="$2" --export-height="$4" >/dev/null 2>&1
  else
    inkscape "$1" --export-type=png --export-filename="$2" --export-width="$3" >/dev/null 2>&1
  fi
}

for s in 16 32 48 64 128 180 192 256 512 1024; do
  render "$SVG/frontseat-mark.svg" "$PNG/frontseat-mark-$s.png" "$s"
done

for s in 180 192 512 1024; do
  render "$SVG/frontseat-mark-square.svg" "$PNG/frontseat-mark-square-$s.png" "$s"
done

for theme in light dark; do
  for h in 64 128 256; do
    render "$SVG/frontseat-lockup-$theme.svg" "$PNG/frontseat-lockup-$theme-h$h.png" "" "$h"
  done
done

# Social / Open Graph card: light lockup centered on the app's light background.
og_tmp="$(mktemp -d)/og.png"
render "$SVG/frontseat-lockup-light.svg" "$og_tmp" 640
magick -size 1200x630 xc:'#f7f6f3' "$og_tmp" -gravity center -composite \
  "$PNG/frontseat-og-1200x630.png"
rm -f "$og_tmp"

magick "$PNG/frontseat-mark-16.png" "$PNG/frontseat-mark-32.png" "$PNG/frontseat-mark-48.png" \
  favicon.ico

if command -v optipng >/dev/null; then
  optipng -quiet -o5 "$PNG"/*.png
fi

# Copies served by the app (see root.html.heex).
cp favicon.ico "$STATIC/favicon.ico"
cp "$SVG/frontseat-mark.svg" "$STATIC/images/icon.svg"
cp "$PNG/frontseat-mark-square-180.png" "$STATIC/images/apple-touch-icon.png"
cp "$PNG/frontseat-mark-192.png" "$STATIC/images/icon-192.png"
cp "$PNG/frontseat-mark-512.png" "$STATIC/images/icon-512.png"
cp "$PNG/frontseat-mark-square-512.png" "$STATIC/images/icon-maskable-512.png"

echo "done: $(ls "$PNG" | wc -l | tr -d ' ') PNGs, favicon.ico, static copies refreshed"
