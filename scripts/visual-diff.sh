#!/bin/bash
# visual-diff.sh — Phase 9.5: screenshot both stores, compare, output diff report
# Usage: bash visual-diff.sh <source-url> <clone-url> [clone-password]
# Requires: browser tool (OpenClaw) for screenshots

SOURCE_URL="${1:?Usage: visual-diff.sh <source-url> <clone-url> [clone-password]}"
CLONE_URL="${2:?}"
CLONE_PW="${3:-}"

DATE=$(date +%Y-%m-%d-%H%M)
DIFF_DIR="/tmp/visual-diff-$DATE"
mkdir -p "$DIFF_DIR"

echo "📸 Visual diff: $SOURCE_URL vs $CLONE_URL"
echo "   Output: $DIFF_DIR"
echo ""
echo "Run the following in your agent session to complete Phase 9.5:"
echo ""
cat << 'INSTRUCTIONS'
# Phase 9.5: Visual Diff Checklist

## Step 1: Screenshots
Take full-page screenshots of both stores:
  - Source: open $SOURCE_URL in browser, fullPage=true
  - Clone: open $CLONE_URL in browser, fullPage=true (enter password if prompted)

## Step 2: Compare with AI
Use the image tool with both screenshots and this prompt:
  "Compare these two Shopify store homepages side by side in detail.
   Left = original. Right = clone.
   List every visual difference: header/logo, nav items, announcement bar color,
   hero section, colors, fonts, trust sections, collection cards, footer.
   Priority: which differences are most impactful?"

## Step 3: Fix by priority
For each difference identified:

### Colors (API — fast):
  - Extract hex from source HTML: curl -s $SOURCE | grep -o '#[0-9a-fA-F]{6}' | sort | uniq -c | sort -rn | head -10
  - Update config/settings_data.json: header_background, footer_background, primary_button_background

### Logo (API — fast):
  - Check if logo is uploaded: query files API for logo filename
  - Set in header-group.json: "logo": "shopify://shop_images/{filename}"

### Announcement bar color (API — fast):
  - Update header-group.json: announcement-bar.settings.background

### Nav items (API — fast):
  - menuUpdate via GraphQL to match source nav exactly

### Homepage sections (API — medium):
  - For each section that doesn't match: rebuild HTML block
  - Upload updated templates/index.json

### Currency symbol (API — fast):
  - Already patched in clone-pipeline.sh via js-variables.liquid

### Footer (API — fast):
  - Update footer-group.json to match source footer structure

## Step 4: Verify
Take screenshots again, compare visually, iterate until:
  ✅ Header logo matches
  ✅ Header nav matches source
  ✅ Announcement bar color matches
  ✅ Hero section matches (image, headline, CTA style)
  ✅ All homepage sections present and in correct order
  ✅ Colors match (buttons, accents, backgrounds)
  ✅ Footer matches source structure
  ✅ Currency symbol correct
INSTRUCTIONS
