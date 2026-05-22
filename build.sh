#!/usr/bin/env bash
# Builds AlterraAudit-${VERSION}.zip from Scripts/ + enabled.txt, where
# VERSION is read out of Scripts/config.lua so the filename can't drift
# from what the running mod reports.

set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(grep -oP 'VERSION\s*=\s*"\K[^"]+' Scripts/config.lua)
if [[ -z "$VERSION" ]]; then
    echo "could not parse VERSION from Scripts/config.lua" >&2
    exit 1
fi

OUT="AlterraAudit-${VERSION}.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/AlterraAudit"
cp -r Scripts "$STAGE/AlterraAudit/"
cp enabled.txt "$STAGE/AlterraAudit/"

rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OLDPWD/$OUT" AlterraAudit)

echo "built $OUT"
unzip -l "$OUT"
