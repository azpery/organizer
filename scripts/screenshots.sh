#!/bin/bash
# Régénère les captures du README (docs/screenshots) à partir d'une instance de démonstration :
# données fictives, aucune synchronisation, l'app capture sa propre fenêtre (voir Sources/Organizer/Demo.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN="$PWD/.build/debug/Organizer"
OUT="$PWD/docs/screenshots"
DEMO="$(mktemp -d)"
trap 'pkill -f "$BIN" 2>/dev/null || true; rm -rf "$DEMO"' EXIT
mkdir -p "$OUT"
export ORGANIZER_DEMO_DIR="$DEMO" ORGANIZER_DEMO_WIDTH=1500 ORGANIZER_DEMO_HEIGHT=940

# 1. Lancer l'app à vide et la remplir par son API.
"$BIN" -apiToken demo >/dev/null 2>&1 &
for _ in $(seq 1 40); do [ -f "$DEMO/api.json" ] && curl -s -m 1 -o /dev/null http://127.0.0.1:47899/api/health && break; sleep 0.25; done
python3 scripts/demo-data.py "$DEMO"
pkill -f "$BIN"; sleep 1

# 2. Une capture par onglet : shot <fichier> <apparence> <réglages -clé valeur…>
shot() {
  local name="$1" look="$2"; shift 2
  ORGANIZER_DEMO_APPEARANCE="$look" ORGANIZER_SHOT="$OUT/$name.png" ORGANIZER_SHOT_DELAY="${DELAY:-3}" "$BIN" -apiToken demo "$@" >/dev/null 2>&1
  sips --resampleWidth 1500 "$OUT/$name.png" >/dev/null
  echo "✓ $name"
}
shot board light -sidebar board
shot today light -sidebar today
shot timer light -sidebar timer
shot mindmap light -sidebar mindmap
shot reports light -sidebar reports
shot cleaner light -sidebar cleaner -cleanerTab clean
shot genart-moire dark -sidebar genart -art.style moire -art.palette Océan -art.seed 1231 -art.density 0.55 -art.animate NO
shot genart-flow dark -sidebar genart -art.style flow -art.palette Aurore -art.seed 4242 -art.density 0.6 -art.animate NO
