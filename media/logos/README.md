# FrontSeat logos

The SVG files in `svg/` are the source of truth. Everything else is generated from them. To rebuild all rasters and the copies the app serves, run `./generate.sh` (requires `inkscape` and ImageMagick).

## Files

| File | Use |
| --- | --- |
| `svg/frontseat-mark.svg` | Primary icon: rounded accent square with the two-bar glyph |
| `svg/frontseat-mark-square.svg` | Full-bleed square for app stores and maskable icons, where the platform applies its own corner mask |
| `svg/frontseat-glyph.svg` | Bars only, in `currentColor`, for monochrome use |
| `svg/frontseat-glyph-white.svg`, `-accent.svg` | Bars only, in a fixed color |
| `svg/frontseat-lockup-light.svg` | Mark + wordmark for light backgrounds |
| `svg/frontseat-lockup-dark.svg` | Mark + wordmark for dark backgrounds |
| `svg/frontseat-lockup-mono.svg` | Single-color lockup in `currentColor`, with the bars knocked out |
| `png/frontseat-mark-{16…1024}.png` | Mark at 16, 32, 48, 64, 128, 180, 192, 256, 512 and 1024 px |
| `png/frontseat-mark-square-{180,192,512,1024}.png` | App-store and maskable icons |
| `png/frontseat-lockup-{light,dark}-h{64,128,256}.png` | Lockup at fixed heights, with a transparent background |
| `png/frontseat-og-1200x630.png` | Social and Open Graph card |
| `favicon.ico` | Contains 16, 32 and 48 px icons |

The wordmark is DM Sans Bold (OFL), converted to outlines, so no font is needed.

## Colors

- Accent: `#7c7ae6`. In dark mode it is `#9c9af2`.
- Bars: `#ffffff`. The short bar has 75% opacity.
- Wordmark: `#1d1c19` on light backgrounds, `#eceae4` on dark backgrounds.

## Clear space

Keep at least half the mark's height clear on every side of the logo. Don't recolor, stretch or rearrange the mark.
