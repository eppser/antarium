#!/bin/bash
# Regenerates docs/assets/antarium-demo.gif and docs/assets/antarium-dashboard.png.
#
# Everything drawn comes from DemoScene's invented roster, rendered through the
# app's own views. ANTARIUM_HOME points at a throwaway folder with fixed display
# settings, so the result is the same on every machine and this Mac's own
# configuration is neither read nor written.
#
# Requires ffmpeg (brew install ffmpeg).
set -euo pipefail

cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/frames"
cat > "$work/home/config.json" <<'JSON'
{
  "agentListCompact": false,
  "agentSort": "activity",
  "meterMode": "remaining",
  "showAgentCount": true,
  "notifyOnIdle": true
}
JSON

swift build --product Antarium >/dev/null
ANTARIUM_HOME="$work/home" .build/debug/Antarium --demo-frames "$work/frames"

out=docs/assets
width=900
ffmpeg -v error -y -f concat -safe 0 -i "$work/frames/frames.txt" \
  -vf "fps=20,scale=${width}:-1:flags=lanczos,palettegen=max_colors=192:stats_mode=diff" \
  "$work/palette.png"
ffmpeg -v error -y -f concat -safe 0 -i "$work/frames/frames.txt" -i "$work/palette.png" \
  -lavfi "fps=20,scale=${width}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  -loop 0 "$out/antarium-demo.gif"

last="$(ls "$work/frames"/frame-*.png | tail -1)"
cp "$last" "$out/antarium-dashboard.png"

echo "wrote $out/antarium-demo.gif ($(du -h "$out/antarium-demo.gif" | cut -f1))"
echo "wrote $out/antarium-dashboard.png"
