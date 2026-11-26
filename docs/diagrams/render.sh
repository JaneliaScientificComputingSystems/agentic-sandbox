#!/bin/bash
# Re-render the README diagrams after editing a .mmd file here:  ./render.sh
# Writes NAME-light.svg and NAME-dark.svg next to each NAME.mmd. The GitHub mobile app does not
# draw ```mermaid blocks, so the README shows these images. htmlLabels is off in the .mmd files
# so that the SVGs hold plain text, which every image viewer draws.
# Needs node (npx) and a Chrome or Chromium; set CHROME to its path if it is not google-chrome.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT
chrome=${CHROME:-$(command -v google-chrome || command -v chromium || command -v chromium-browser)}
args='[]'; [ "$(id -u)" -eq 0 ] && args='["--no-sandbox"]'   # Chrome refuses to start as root otherwise
printf '{"executablePath":"%s","args":%s}' "$chrome" "$args" > "$cfg"
for f in *.mmd; do
    n=${f%.mmd}
    PUPPETEER_SKIP_DOWNLOAD=1 npx -y @mermaid-js/mermaid-cli@11 -p "$cfg" -i "$f" -o "$n-light.svg" -t default -b transparent
    PUPPETEER_SKIP_DOWNLOAD=1 npx -y @mermaid-js/mermaid-cli@11 -p "$cfg" -i "$f" -o "$n-dark.svg"  -t dark    -b transparent
done
