#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KSP_CANDIDATES=(
    "$HOME/.local/share/Steam/steamapps/common/Kerbal Space Program"
    "$HOME/snap/steam/common/.local/share/Steam/steamapps/common/Kerbal Space Program"
    "$HOME/.steam/steam/steamapps/common/Kerbal Space Program"
)

find_ksp() {
    for dir in "${KSP_CANDIDATES[@]}"; do
        if [[ -d "$dir/Ships/Script" ]]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

if [[ $# -ge 1 ]]; then
    KSP_DIR="$1"
else
    KSP_DIR="$(find_ksp)" || {
        echo "Error: KSP install not found. Pass the KSP directory as an argument:" >&2
        echo "  $0 \"/path/to/Kerbal Space Program\"" >&2
        exit 1
    }
fi

DEST="$KSP_DIR/Ships/Script"

if [[ ! -d "$DEST" ]]; then
    echo "Error: Ships/Script not found in: $KSP_DIR" >&2
    exit 1
fi

mkdir -p "$DEST/boot"

cp "$SCRIPT_DIR"/*.ks "$DEST/"
cp "$SCRIPT_DIR"/boot/*.ks "$DEST/boot/"

echo "Installed kOS scripts to: $DEST"
