#!/bin/bash
#
# tx-pull.sh - Pull translations from Transifex
#
# This script downloads the latest translations from Transifex
# and updates the local PO files.
#
# Prerequisites:
#   - Transifex CLI (tx) must be installed
#   - Project must be configured in .tx/config
#   - User must be authenticated with: tx init
#

set -e

PACKAGE="budgie-radio-widget"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Check if tx is installed
if ! command -v tx &> /dev/null; then
    echo "ERROR: Transifex CLI (tx) is not installed."
    echo "Install with: pip install transifex-client"
    exit 1
fi

# Check if .tx/config exists
if [ ! -f ".tx/config" ]; then
    echo "ERROR: Transifex is not configured for this project."
    echo "Please create .tx/config or run: tx init"
    exit 1
fi

echo "Pulling translations from Transifex..."
echo ""

# Pull all translations with a completion threshold
# Only pull translations that are at least 75% complete
tx pull --all --minimum-perc=75

echo ""
echo "Translations updated successfully!"
echo ""
echo "Translation statistics:"
for po_file in po/*.po; do
    if [ -f "$po_file" ]; then
        lang=$(basename "$po_file" .po)
        echo -n "  $lang: "
        msgfmt --statistics -o /dev/null "$po_file" 2>&1 || true
    fi
done
