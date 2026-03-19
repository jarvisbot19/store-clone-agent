#!/usr/bin/env bash
# Download all assets from a Shopify store for cloning
# Usage: ./download-assets.sh <store-domain> [output-dir]
# Example: ./download-assets.sh getvision4k.com /tmp/getvision4k-assets
#
# Downloads: product images, branding (logo/favicon/OG), homepage images/GIFs/videos

set -euo pipefail

DOMAIN="${1:?Usage: download-assets.sh <store-domain> [output-dir]}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

OUTPUT_DIR="${2:-/tmp/${DOMAIN}-assets}"
mkdir -p "$OUTPUT_DIR"/{branding,product,homepage,gifs,video}

echo "📥 Downloading assets from https://${DOMAIN}..."

# ─── Product Images ─────────────────────────────────────────────────
echo ""
echo "📸 Product images..."
PRODUCTS_JSON=$(curl -sL "https://${DOMAIN}/products.json?limit=250")
PRODUCT_COUNT=$(echo "$PRODUCTS_JSON" | jq '.products | length')
echo "  Found ${PRODUCT_COUNT} products"

IMAGE_COUNT=0
echo "$PRODUCTS_JSON" | jq -r '.products[] | .handle as $h | .images[] | "\($h)|\(.position)|\(.src)"' | while IFS='|' read -r handle pos url; do
  filename="${handle}-${pos}.$(echo "$url" | sed 's/.*\.//' | sed 's/\?.*//')"
  if [ ! -f "${OUTPUT_DIR}/product/${filename}" ]; then
    curl -sL "$url" -o "${OUTPUT_DIR}/product/${filename}" &
  fi
  IMAGE_COUNT=$((IMAGE_COUNT + 1))
done
wait
echo "  Downloaded product images to ${OUTPUT_DIR}/product/"

# ─── Branding ───────────────────────────────────────────────────────
echo ""
echo "🎨 Branding assets..."
HTML=$(curl -sL "https://${DOMAIN}")

# Logo
LOGO_URL=$(echo "$HTML" | python3 -c "
import sys, re
html = sys.stdin.read()
# Try common patterns
patterns = [
    r'class=\"[^\"]*header[^\"]*logo[^\"]*\"[^>]*src=\"([^\"]+)\"',
    r'class=\"[^\"]*logo[^\"]*\"[^>]*src=\"([^\"]+)\"',
    r'<img[^>]*class=\"[^\"]*logo[^\"]*\"[^>]*src=\"([^\"]+)\"',
    r'<link[^>]*rel=\"icon\"[^>]*href=\"([^\"]+)\"',
]
# Also try og:image as fallback logo source
for p in patterns:
    m = re.search(p, html, re.IGNORECASE)
    if m:
        url = m.group(1)
        if url.startswith('//'):
            url = 'https:' + url
        print(url)
        break
" 2>/dev/null)

if [ -n "$LOGO_URL" ]; then
  EXT=$(echo "$LOGO_URL" | sed 's/.*\.//' | sed 's/\?.*//' | head -c 4)
  curl -sL "$LOGO_URL" -o "${OUTPUT_DIR}/branding/logo.${EXT}"
  echo "  ✅ Logo: logo.${EXT}"
fi

# Favicon
FAVICON_URL=$(echo "$HTML" | grep -oP 'rel="(?:icon|shortcut icon)"[^>]*href="\K[^"]+' | head -1)
if [ -n "$FAVICON_URL" ]; then
  [ "${FAVICON_URL:0:2}" = "//" ] && FAVICON_URL="https:${FAVICON_URL}"
  [ "${FAVICON_URL:0:1}" = "/" ] && FAVICON_URL="https://${DOMAIN}${FAVICON_URL}"
  EXT=$(echo "$FAVICON_URL" | sed 's/.*\.//' | sed 's/\?.*//' | head -c 4)
  curl -sL "$FAVICON_URL" -o "${OUTPUT_DIR}/branding/favicon.${EXT}"
  echo "  ✅ Favicon: favicon.${EXT}"
fi

# OG Image
OG_URL=$(echo "$HTML" | grep -oP 'property="og:image"[^>]*content="\K[^"]+' | head -1)
if [ -n "$OG_URL" ]; then
  [ "${OG_URL:0:2}" = "//" ] && OG_URL="https:${OG_URL}"
  EXT=$(echo "$OG_URL" | sed 's/.*\.//' | sed 's/\?.*//' | head -c 4)
  curl -sL "$OG_URL" -o "${OUTPUT_DIR}/branding/og-image.${EXT}"
  echo "  ✅ OG Image: og-image.${EXT}"
fi

# ─── Homepage Media (images, GIFs, videos) ──────────────────────────
echo ""
echo "🏠 Homepage media..."

# Extract all CDN image/GIF/video URLs from homepage
echo "$HTML" | python3 -c "
import sys, re, json

html = sys.stdin.read()
cdn_pattern = r'(https?://cdn\.shopify\.com/s/files/[^\"\\s>]+\.(?:jpg|jpeg|png|gif|webp|mp4|webm))'
urls = list(set(re.findall(cdn_pattern, html, re.IGNORECASE)))

# Separate by type
images = [u for u in urls if not u.lower().endswith(('.gif', '.mp4', '.webm'))]
gifs = [u for u in urls if u.lower().endswith('.gif')]
videos = [u for u in urls if u.lower().endswith(('.mp4', '.webm'))]

result = {'images': images, 'gifs': gifs, 'videos': videos}
print(json.dumps(result))
" > /tmp/_homepage_media.json

# Download homepage images (skip product images already downloaded)
jq -r '.images[]' /tmp/_homepage_media.json 2>/dev/null | while read -r url; do
  filename=$(basename "$url" | sed 's/\?.*//')
  if [ ! -f "${OUTPUT_DIR}/homepage/${filename}" ] && [ ! -f "${OUTPUT_DIR}/product/${filename}" ]; then
    curl -sL "$url" -o "${OUTPUT_DIR}/homepage/${filename}" &
  fi
done
wait

# Download GIFs
jq -r '.gifs[]' /tmp/_homepage_media.json 2>/dev/null | while read -r url; do
  filename=$(basename "$url" | sed 's/\?.*//')
  if [ ! -f "${OUTPUT_DIR}/gifs/${filename}" ]; then
    curl -sL "$url" -o "${OUTPUT_DIR}/gifs/${filename}" &
  fi
done
wait

# Download videos
jq -r '.videos[]' /tmp/_homepage_media.json 2>/dev/null | while read -r url; do
  filename=$(basename "$url" | sed 's/\?.*//')
  if [ ! -f "${OUTPUT_DIR}/video/${filename}" ]; then
    curl -sL "$url" -o "${OUTPUT_DIR}/video/${filename}" &
  fi
done
wait

rm -f /tmp/_homepage_media.json

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo "✅ Asset download complete!"
echo ""
echo "📊 Summary:"
find "$OUTPUT_DIR" -type f | python3 -c "
import sys, os
from collections import defaultdict

sizes = defaultdict(lambda: {'count': 0, 'bytes': 0})
for line in sys.stdin:
    path = line.strip()
    if not path: continue
    folder = os.path.basename(os.path.dirname(path))
    size = os.path.getsize(path)
    sizes[folder]['count'] += 1
    sizes[folder]['bytes'] += size

total_bytes = 0
for folder, info in sorted(sizes.items()):
    mb = info['bytes'] / (1024*1024)
    total_bytes += info['bytes']
    print(f\"  {folder}: {info['count']} files ({mb:.1f} MB)\")

print(f\"  ──────────────────\")
print(f\"  Total: {sum(i['count'] for i in sizes.values())} files ({total_bytes/(1024*1024):.1f} MB)\")
"
echo ""
echo "📁 Output: ${OUTPUT_DIR}/"
