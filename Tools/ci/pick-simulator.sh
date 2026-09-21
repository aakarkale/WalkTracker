#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator, or fails loudly.
#
# Matched by UDID rather than by name. Simulator names change with every
# runner image, and several of them contain parentheses ("iPhone SE (3rd
# generation)"), which makes name parsing a reliable source of destinations
# that look plausible and match nothing.
set -euo pipefail

LIST=$(xcrun simctl list devices available)

UDID=$(printf '%s\n' "$LIST" \
    | grep -E '^[[:space:]]+iPhone' \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
    | tail -1)

if [ -z "$UDID" ]; then
    echo "No available iPhone simulator on this runner." >&2
    printf '%s\n' "$LIST" >&2
    exit 1
fi

printf '%s\n' "$UDID"
