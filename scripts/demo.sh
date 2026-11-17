#!/bin/sh
# Renders the page clips with the app's demo mode and encodes them.
# Usage: sh scripts/demo.sh <out dir> [clip]   (needs ffmpeg)
# Writes <out>/<clip>.mp4 (H.264, muted, loops), <clip>.webp (poster) and <clip>.gif (for the README).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: sh scripts/demo.sh <out dir> [clip]}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
FRAMES="$OUT/frames"

"$ROOT/build.sh" >/dev/null
if [ $# -ge 2 ]; then
    "$ROOT/build.noindex/BetterMacScreenshot.app/Contents/MacOS/BetterMacScreenshot" --demo "$FRAMES" --clip "$2"
    CLIPS=$2
else
    "$ROOT/build.noindex/BetterMacScreenshot.app/Contents/MacOS/BetterMacScreenshot" --demo "$FRAMES"
    CLIPS="capture blur unblur backgrounds"
fi

# Poster frame per clip, in seconds: the moment that explains the clip without motion.
poster() {
    case $1 in
        capture) echo 6.4 ;;
        blur) echo 3.6 ;;
        unblur) echo 2.2 ;;
        backgrounds) echo 2.6 ;;
    esac
}

for clip in $CLIPS; do
    ffmpeg -v error -y -framerate 30 -i "$FRAMES/$clip/f%04d.png" \
        -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$OUT/$clip.mp4"
    n=$(awk -v s="$(poster "$clip")" 'BEGIN { printf "%04d", s * 30 }')
    ffmpeg -v error -y -i "$FRAMES/$clip/f$n.png" -c:v libwebp -quality 82 "$OUT/$clip.webp"
    ffmpeg -v error -y -framerate 30 -i "$FRAMES/$clip/f%04d.png" \
        -vf "fps=15,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a" \
        "$OUT/$clip.gif"
    printf '%s: mp4 %s KB, webp %s KB, gif %s KB\n' "$clip" \
        $(( $(stat -f %z "$OUT/$clip.mp4") / 1024 )) $(( $(stat -f %z "$OUT/$clip.webp") / 1024 )) $(( $(stat -f %z "$OUT/$clip.gif") / 1024 ))
done
