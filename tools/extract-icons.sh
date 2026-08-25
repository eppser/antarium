#!/bin/bash
# Regenerates Resources/marks/*.png from the agent apps installed on this Mac.
# Agents whose app isn't installed keep their drawn vector fallback.
set -euo pipefail
cd "$(dirname "$0")"
OUT="../Resources/marks"
mkdir -p "$OUT"
swiftc -O -o extract-glyph ExtractGlyph.swift

emit() { # id  icns-path  extra-flags...
    local id="$1" icns="$2"; shift 2
    if [[ -f "$icns" ]]; then
        ./extract-glyph "$icns" "$OUT/$id.png" --size 256 "$@"
    else
        echo "skip $id — not installed at $icns"
    fi
}

# Light mark on a coloured canvas.
emit claude-code /Applications/Claude.app/Contents/Resources/electron.icns
# Dark mark on a white canvas; the knot's strokes need thickening for 14pt.
emit codex /Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.icns --invert --bold 14
# Cursor's mark is light-on-dark, so the default extraction is correct.
emit cursor /Applications/Cursor.app/Contents/Resources/Cursor.icns
# Kimi ships no macOS app. A developer may supply sources/kimi-logo.png locally;
# third-party artwork is intentionally not distributed by this repository.
# --alpha handles a flat colour on transparency and --trim removes outer canvas.
emit kimi sources/kimi-logo.png --trim --alpha

# VS Code is a saturated glyph on a white tile, which neither luma nor alpha
# can separate — see --chroma. It is often run from its disk image, so try both.
emit vscode /Applications/Visual\ Studio\ Code.app/Contents/Resources/Code.icns --trim --chroma
[[ -f "$OUT/vscode.png" ]] || emit vscode /Volumes/VS\ Code/Visual\ Studio\ Code.app/Contents/Resources/Code.icns --trim --chroma

# Copilot ships its own glyph inside VS Code: a dark mark over an opaque white
# fill, so the silhouette comes from luma, not alpha.
CODE_APP=/Applications/Visual\ Studio\ Code.app
[[ -d "$CODE_APP" ]] || CODE_APP=/Volumes/VS\ Code/Visual\ Studio\ Code.app
emit copilot "$CODE_APP/Contents/Resources/app/extensions/copilot/assets/copilot.png" --trim --invert

# Zed is drawn, not extracted. Its icon is a Z built from a squared spiral, and
# at a 12pt row that detail collapses into a grey smear — every luma threshold
# and every --bold value produced the same thing. See tools/ZedMark.swift.
swift "$(dirname "$0")/ZedMark.swift" "$(dirname "$0")/../Resources/marks/zed.png"

echo "done — rebuild with ./build.sh to bundle them"
