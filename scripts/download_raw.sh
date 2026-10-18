#!/usr/bin/env bash
# Download CubeCobra's public JSON export into raw/ (public bucket, no AWS CLI needed).
set -euo pipefail

BASE="https://cubecobra-public.s3.amazonaws.com"
mkdir -p raw

# <remote path> <local name>; 4 at a time. A failing curl fails the whole script (xargs -> exit 123).
xargs -P 4 -L 1 sh -c 'curl -fsSL -o "raw/$1" "$0/$2"' "$BASE" <<'EOF'
export/cubes.json              cubes.json
export/indexToOracleMap.json   export_indexToOracle.json
cards/indexToOracle.json       cards_indexToOracle.json
cards/carddict.json            carddict.json
cards/metadatadict.json        metadatadict.json
cards/oracleToId.json          oracleToId.json
cards/manifest.json            manifest.json
cards/oracleTagDict.json       oracleTagDict.json
cards/oracleTagNames.json      oracleTagNames.json
EOF

echo "---- raw file sizes ----"
ls -lh raw/
