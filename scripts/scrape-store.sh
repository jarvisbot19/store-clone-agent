#!/bin/bash
# scrape-store.sh — Phase 0+1+2 combined: setup run log, scrape source, verify prices, flag issues
# Usage: bash scrape-store.sh https://source-store.com
# Outputs: run log at $RUN_FILE, assets at $ASSET_DIR, scrape data at /tmp/{domain}-scrape/

set -euo pipefail

SOURCE_URL="${1:?Usage: scrape-store.sh <source_url>}"
DATE=$(date +%Y-%m-%d)
DOMAIN=$(echo "$SOURCE_URL" | sed 's|https\?://||;s|/.*||')
RUN_DIR=~/clawd/projects/store-factory/runs
RUN_FILE="$RUN_DIR/${DATE}-${DOMAIN%.myshopify.com}.md"
ASSET_DIR="$RUN_DIR/${DOMAIN%.myshopify.com}-assets"
SCRAPE_DIR="/tmp/${DOMAIN}-scrape"

mkdir -p "$ASSET_DIR"/{branding,product,homepage,gifs,video,sections}
mkdir -p "$SCRAPE_DIR"

echo "⚡ Scraping $SOURCE_URL"
echo "   Run log: $RUN_FILE"
echo "   Assets:  $ASSET_DIR"
echo "   Data:    $SCRAPE_DIR"
echo ""

# ─── Phase 0: Create run log ──────────────────────────────────────────────────
cat > "$RUN_FILE" << EOF
# Clone Run: $DOMAIN
**Date:** $DATE
**Source:** $SOURCE_URL
**Status:** 🔄 In Progress

## Phase 1: Scrape
EOF

# ─── Phase 1a: Theme identification ──────────────────────────────────────────
echo "📦 Identifying theme..."
THEME_JSON=$(curl -s "$SOURCE_URL" | grep -o 'Shopify\.theme = {[^}]*}' | head -1)
SCHEMA_NAME=$(echo "$THEME_JSON" | grep -o '"schema_name":"[^"]*"' | cut -d'"' -f4)
SCHEMA_VERSION=$(echo "$THEME_JSON" | grep -o '"schema_version":"[^"]*"' | cut -d'"' -f4)

echo "   Theme: $SCHEMA_NAME v$SCHEMA_VERSION"
echo "## Theme: $SCHEMA_NAME v$SCHEMA_VERSION" >> "$RUN_FILE"

# Determine if we have the theme
HAVE_THEME="no"
if [[ "$SCHEMA_NAME" == "Impact" ]]; then
  HAVE_THEME="yes"
  echo "   ✅ Impact — using exact theme"
elif [[ "$SCHEMA_NAME" == "Shrine" ]]; then
  HAVE_THEME="yes"
  echo "   ✅ Shrine — using exact theme"
else
  echo "   ⚠️  $SCHEMA_NAME not in library — will use Impact + custom-html sections"
fi
echo "HAVE_THEME=$HAVE_THEME" > "$SCRAPE_DIR/theme.env"
echo "SCHEMA_NAME=\"$SCHEMA_NAME\"" >> "$SCRAPE_DIR/theme.env"
echo "SCHEMA_VERSION=\"$SCHEMA_VERSION\"" >> "$SCRAPE_DIR/theme.env"

# ─── Phase 1b: Currency detection ─────────────────────────────────────────────
echo ""
echo "💱 Detecting currency..."
HOMEPAGE_HTML=$(curl -s "$SOURCE_URL")
CURRENCY=$(echo "$HOMEPAGE_HTML" | python3 -c "
import sys, re
html = sys.stdin.read()
for pattern in [r'Shopify\.currency\s*=\s*[\"\\'](\w{3})[\"\\']', r'\"currency\":\s*\"(\w{3})\"', r'data-currency=\"(\w{3})\"']:
    m = re.search(pattern, html)
    if m:
        print(m.group(1)); exit()
if '£' in html: print('GBP'); exit()
if '€' in html: print('EUR'); exit()
print('USD')
")
echo "   Currency: $CURRENCY"
echo "CURRENCY=\"$CURRENCY\"" >> "$SCRAPE_DIR/theme.env"

# ─── Phase 1c: Color palette ──────────────────────────────────────────────────
echo ""
echo "🎨 Extracting color palette..."
python3 << PYEOF
import re
from collections import Counter
html = open('/dev/stdin').read()
colors = re.findall(r'#[0-9a-fA-F]{6}\b', html)
c = Counter(colors)
top = c.most_common(8)
print("   Top colors:")
for color, count in top:
    print(f"   {color}: {count}x")
lines = [f"COLOR_{i+1}=\"{color}\"" for i, (color, _) in enumerate(top)]
open('$SCRAPE_DIR/colors.env', 'w').write('\n'.join(lines))
PYEOF <<< "$HOMEPAGE_HTML"

# ─── Phase 1d: Products + price verification ──────────────────────────────────
echo ""
echo "📦 Scraping products..."
python3 << PYEOF
import json, re, urllib.request, time

base = "$SOURCE_URL"
all_products = []
page = 1
while True:
    url = f"{base}/products.json?limit=250&page={page}"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            data = json.loads(r.read())
        prods = data.get('products', [])
        if not prods:
            break
        all_products.extend(prods)
        if len(prods) < 250:
            break
        page += 1
        time.sleep(0.5)
    except:
        break

print(f"   Total products scraped: {len(all_products)}")

# Save all products
with open('$SCRAPE_DIR/products.json', 'w') as f:
    json.dump(all_products, f, indent=2)

# ─── UTILITY PRODUCT FILTER ───
UTILITY_VENDORS = ['S:EDD', 'Route', 'Navidium', 'Corso', 'Upsell', 'Rebuy', 'Loyalty']
UTILITY_TITLES = ['shipping protection', 'shipping insurance', 'shipping - returns',
                  'item personalization', 'bundle test', 'addons', 'test']

def is_utility(p):
    v = p.get('vendor', '').lower()
    t = p.get('title', '').lower()
    for uv in UTILITY_VENDORS:
        if uv.lower() in v:
            return True, f"vendor match: {uv}"
    for ut in UTILITY_TITLES:
        if ut in t:
            return True, f"title match: {ut}"
    return False, ""

# ─── PRICE CROSS-CHECK ────────────────────────────────────────────────────────
zero_price_products = [p for p in all_products if float(p['variants'][0].get('price', 0)) == 0]
real_products = []
skipped_utility = []
price_fixes = {}

print(f"\n   Products with £0 price: {len(zero_price_products)}")
for p in zero_price_products:
    util, reason = is_utility(p)
    if util:
        skipped_utility.append((p['title'], reason))
        continue
    # Cross-check against source
    try:
        url = f"{base}/products/{p['handle']}.json"
        with urllib.request.urlopen(url, timeout=10) as r:
            detail = json.loads(r.read())
        real_price = detail['product']['variants'][0].get('price', '0.00')
        if real_price != '0.00':
            price_fixes[p['handle']] = real_price
            print(f"   ⚠️  PRICE FIX: {p['title']} ({p['handle']}): £0 → £{real_price}")
        time.sleep(0.3)
    except:
        pass

# ─── FILTER FINAL LIST ────────────────────────────────────────────────────────
final_products = []
for p in all_products:
    util, reason = is_utility(p)
    if util:
        skipped_utility.append((p['title'], reason))
        continue
    # Apply price fix if found
    if p['handle'] in price_fixes:
        for v in p['variants']:
            v['price'] = price_fixes[p['handle']]
    final_products.append(p)

print(f"\n   ✅ Real products: {len(final_products)}")
print(f"   🗑️  Utility products skipped: {len(set(t for t,_ in skipped_utility))}")

with open('$SCRAPE_DIR/products-final.json', 'w') as f:
    json.dump(final_products, f, indent=2)

with open('$SCRAPE_DIR/price-fixes.json', 'w') as f:
    json.dump(price_fixes, f, indent=2)

with open('$SCRAPE_DIR/skipped.json', 'w') as f:
    json.dump(list(set(t for t,_ in skipped_utility)), f, indent=2)
PYEOF

# ─── Phase 1e: Collections ────────────────────────────────────────────────────
echo ""
echo "📂 Scraping collections..."
python3 << PYEOF
import json, urllib.request, time

base = "$SOURCE_URL"
data = json.loads(urllib.request.urlopen(f"{base}/collections.json", timeout=15).read())
collections = data.get('collections', [])
print(f"   Collections: {len(collections)}")

col_map = {}
for c in collections:
    try:
        prods_data = json.loads(urllib.request.urlopen(f"{base}/collections/{c['handle']}/products.json?limit=250", timeout=10).read())
        handles = [p['handle'] for p in prods_data.get('products', [])]
        col_map[c['handle']] = handles
        time.sleep(0.2)
    except:
        col_map[c['handle']] = []

with open('$SCRAPE_DIR/collections.json', 'w') as f:
    json.dump({'collections': collections, 'product_map': col_map}, f, indent=2)
PYEOF

# ─── Phase 1f: Homepage sections ──────────────────────────────────────────────
echo ""
echo "🖼️  Extracting homepage sections..."
SECTION_IDS=$(echo "$HOMEPAGE_HTML" | python3 -c "
import sys, re
ids = re.findall(r'id=\"shopify-section-([^\"]+)\"', sys.stdin.read())
print('\n'.join(ids))
")
echo "$SECTION_IDS" > "$SCRAPE_DIR/section-ids.txt"
N=$(echo "$SECTION_IDS" | wc -l)
echo "   Found $N sections"

# Download each section's HTML
mkdir -p "$ASSET_DIR/sections"
while IFS= read -r sid; do
  [ -z "$sid" ] && continue
  out="$ASSET_DIR/sections/${sid}.html"
  if [ ! -f "$out" ]; then
    curl -s "$SOURCE_URL/?section_id=$sid" -o "$out"
    sleep 0.25
  fi
done <<< "$SECTION_IDS"
echo "   Section HTML downloaded to $ASSET_DIR/sections/"

# ─── Phase 1g: Branding / logos ───────────────────────────────────────────────
echo ""
echo "🎨 Extracting branding assets..."
python3 << PYEOF
import re, urllib.request, os, time

html = open('/dev/stdin').read()
base = "$SOURCE_URL"
asset_dir = "$ASSET_DIR"

# All CDN image URLs
cdn_urls = list(set(re.findall(r'//[a-z0-9.-]*\.com/cdn/shop/files/[^\s"\'?&<>]+', html)))
print(f"   Found {len(cdn_urls)} unique CDN image refs")

with open('$SCRAPE_DIR/cdn-images.txt', 'w') as f:
    for url in cdn_urls:
        f.write(('https:' + url) + '\n')
PYEOF <<< "$HOMEPAGE_HTML"

# ─── Phase 2: Download branding assets ────────────────────────────────────────
echo ""
echo "⬇️  Downloading branding assets..."
if [ -f "$SCRAPE_DIR/cdn-images.txt" ]; then
  count=0
  while IFS= read -r url; do
    fname=$(basename "$url" | sed 's/\?.*//' | sed 's/&.*//')
    out="$ASSET_DIR/homepage/$fname"
    if [ ! -f "$out" ]; then
      curl -sL "$url" -o "$out" 2>/dev/null && count=$((count+1))
      sleep 0.2
    fi
  done < "$SCRAPE_DIR/cdn-images.txt"
  echo "   Downloaded $count new assets"
fi

# ─── Finalize run log ─────────────────────────────────────────────────────────
PROD_COUNT=$(python3 -c "import json; print(len(json.load(open('$SCRAPE_DIR/products-final.json'))))" 2>/dev/null || echo "?")
COL_COUNT=$(python3 -c "import json; print(len(json.load(open('$SCRAPE_DIR/collections.json'))['collections']))" 2>/dev/null || echo "?")

cat >> "$RUN_FILE" << LOGEOF

## Phase 1 Complete
- Products: $PROD_COUNT (after filtering)
- Collections: $COL_COUNT
- Currency: $CURRENCY
- Theme: $SCHEMA_NAME v$SCHEMA_VERSION
- Section IDs: $(cat "$SCRAPE_DIR/section-ids.txt" | wc -l | tr -d ' ')
- Assets: $(ls "$ASSET_DIR/homepage/" 2>/dev/null | wc -l | tr -d ' ') CDN images downloaded

## Tokens (fill after Phase 3)
\`\`\`
SHOP=""
TOKEN=""
\`\`\`
LOGEOF

echo ""
echo "✅ Phase 0+1+2 complete!"
echo "   Run log: $RUN_FILE"
echo "   Products: $PROD_COUNT | Collections: $COL_COUNT | Currency: $CURRENCY"
echo "   Theme: $SCHEMA_NAME v$SCHEMA_VERSION"
echo ""
echo "Next: Create dev store in browser (Phase 3), then run clone-pipeline.sh SHOP TOKEN"
echo "      Source env: source $SCRAPE_DIR/theme.env"
