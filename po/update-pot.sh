#!/bin/bash
#
# update-pot.sh - Generate POT file from source files
#
# This script extracts translatable strings from Python and Vala source files
# and generates a POT (Portable Object Template) file for translation.
#

set -e

PACKAGE="budgie-radio-widget"
VERSION="0.0.1"
BUGZILLA="https://github.com/ubuntubudgie/budgie-radio-widget/issues"
COPYRIGHT="Ubuntu Budgie Developers"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PO_DIR="$SCRIPT_DIR"

cd "$PROJECT_ROOT"

echo "Generating POT file for $PACKAGE..."

# Create temporary file lists
TEMP_FILES=$(mktemp)
TEMP_DESKTOP=$(mktemp)

# Find all Python files
find daemon gui-app -name "*.py" -type f >> "$TEMP_FILES"

# Find all Vala files
find raven-widget -name "*.vala" -type f >> "$TEMP_FILES"

# Find desktop file (handle separately)
find po -name "*.desktop" -type f > "$TEMP_DESKTOP"

# Generate POT file from code
xgettext \
    --package-name="$PACKAGE" \
    --package-version="$VERSION" \
    --msgid-bugs-address="$BUGZILLA" \
    --copyright-holder="$COPYRIGHT" \
    --from-code=UTF-8 \
    --add-comments=TRANSLATORS: \
    --keyword=_ \
    --keyword=N_ \
    --output="$PO_DIR/$PACKAGE.pot" \
    --files-from="$TEMP_FILES"

# Extract desktop file strings and merge
if [ -s "$TEMP_DESKTOP" ]; then
    DESKTOP_FILE=$(cat "$TEMP_DESKTOP")
    if [ -f "$DESKTOP_FILE" ]; then
        echo "Extracting desktop file strings..."
        
        # Use desktop file-specific extraction
        xgettext \
            --language=Desktop \
            --keyword=Name \
            --keyword=GenericName \
            --keyword=Comment \
            --keyword=Keywords \
            --join-existing \
            --output="$PO_DIR/$PACKAGE.pot" \
            "$DESKTOP_FILE" 2>/dev/null || {
            
            # Fallback: manually extract desktop file strings if xgettext doesn't support Desktop
            echo "Note: Using manual desktop file extraction"
            TEMP_DESKTOP_POT=$(mktemp)
            
            # Extract strings from desktop file
            grep -E "^_(Name|GenericName|Comment|Keywords)=" "$DESKTOP_FILE" | \
            sed 's/^_//; s/=/\nmsgid "/; s/$/"\nmsgstr ""\n/' | \
            cat > "$TEMP_DESKTOP_POT"
            
            # Merge with main POT if we got any strings
            if [ -s "$TEMP_DESKTOP_POT" ]; then
                msgcat --use-first "$PO_DIR/$PACKAGE.pot" "$TEMP_DESKTOP_POT" \
                    -o "$PO_DIR/$PACKAGE.pot" 2>/dev/null || true
            fi
            
            rm -f "$TEMP_DESKTOP_POT"
        }
    fi
fi

# Clean up
rm "$TEMP_FILES" "$TEMP_DESKTOP"

echo "POT file generated: $PO_DIR/$PACKAGE.pot"
echo ""
echo "Translation statistics:"
msgfmt --statistics -o /dev/null "$PO_DIR/$PACKAGE.pot" 2>&1 || true
