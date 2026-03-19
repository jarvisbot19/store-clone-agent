#!/usr/bin/env bash
# Extract all homepage section IDs and their HTML from a Shopify store
# Usage: ./extract-sections.sh <store-domain> [output-dir]
# Example: ./extract-sections.sh getvision4k.com /tmp/sections
#
# Output: One HTML file per section in the output directory + sections-manifest.json

set -euo pipefail

DOMAIN="${1:?Usage: extract-sections.sh <store-domain> [output-dir]}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

OUTPUT_DIR="${2:-/tmp/shopify-sections-${DOMAIN}}"
mkdir -p "$OUTPUT_DIR"

echo "📦 Extracting sections from https://${DOMAIN}..."

# Step 1: Get all section IDs from homepage
HOMEPAGE=$(curl -sL "https://${DOMAIN}")

SECTION_IDS=$(echo "$HOMEPAGE" | python3 -c "
import sys, re
html = sys.stdin.read()
ids = re.findall(r'id=\"shopify-section-([^\"]+)\"', html)
for sid in ids:
    print(sid)
")

if [ -z "$SECTION_IDS" ]; then
  echo '{"error": "No sections found", "domain": "'${DOMAIN}'"}'
  exit 1
fi

SECTION_COUNT=$(echo "$SECTION_IDS" | wc -l | tr -d ' ')
echo "Found ${SECTION_COUNT} sections"

# Step 2: Fetch each section's rendered HTML via Section Rendering API
MANIFEST="[]"
INDEX=0

while IFS= read -r SID; do
  INDEX=$((INDEX + 1))
  echo "  [${INDEX}/${SECTION_COUNT}] Fetching: ${SID}"
  
  # Fetch section HTML
  SECTION_HTML=$(curl -sL "https://${DOMAIN}/?section_id=${SID}")
  
  # Save raw HTML
  echo "$SECTION_HTML" > "${OUTPUT_DIR}/${SID}.html"
  
  # Extract a preview (first 200 chars of text content)
  PREVIEW=$(echo "$SECTION_HTML" | python3 -c "
import sys, re
html = sys.stdin.read()
text = re.sub(r'<[^>]+>', ' ', html)
text = re.sub(r'\s+', ' ', text).strip()[:200]
print(text)
" 2>/dev/null || echo "")
  
  # Detect section type based on content patterns
  SECTION_TYPE=$(echo "$SECTION_HTML" | python3 -c "
import sys, re
html = sys.stdin.read().lower()
if 'announcement-bar' in html or 'announcement_bar' in html:
    print('announcement-bar')
elif '<header' in html or 'site-header' in html or 'header-group' in html:
    print('header')
elif '<footer' in html or 'site-footer' in html or 'footer-group' in html:
    print('footer')
elif '<video' in html or 'video-section' in html:
    print('video-hero')
elif 'featured-product' in html or 'product-form' in html or 'add-to-cart' in html:
    print('featured-product')
elif 'faq' in html or '<details' in html or 'accordion' in html:
    print('faq')
elif 'testimonial' in html or 'review' in html:
    print('testimonials')
elif 'newsletter' in html or 'subscribe' in html:
    print('newsletter')
elif 'custom-html' in html or 'custom_html' in html:
    print('custom-html')
else:
    print('unknown')
" 2>/dev/null || echo "unknown")
  
  # Get approximate size
  SIZE=$(wc -c < "${OUTPUT_DIR}/${SID}.html" | tr -d ' ')
  
  # Add to manifest
  MANIFEST=$(echo "$MANIFEST" | python3 -c "
import json, sys
manifest = json.loads(sys.stdin.read())
manifest.append({
    'id': '${SID}',
    'type': '${SECTION_TYPE}',
    'file': '${SID}.html',
    'size_bytes': ${SIZE},
    'preview': '''${PREVIEW}'''[:200]
})
print(json.dumps(manifest, indent=2))
")
  
done <<< "$SECTION_IDS"

# Save manifest
echo "$MANIFEST" > "${OUTPUT_DIR}/sections-manifest.json"

echo ""
echo "✅ Extracted ${SECTION_COUNT} sections to ${OUTPUT_DIR}/"
echo "📋 Manifest: ${OUTPUT_DIR}/sections-manifest.json"
echo ""
echo "Section types found:"
echo "$MANIFEST" | python3 -c "
import json, sys
from collections import Counter
manifest = json.loads(sys.stdin.read())
for t, c in Counter(s['type'] for s in manifest).most_common():
    print(f'  {t}: {c}')
"
