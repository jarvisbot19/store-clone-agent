#!/usr/bin/env bash
# Upload theme assets (templates, settings) to a Shopify store's active theme
# Usage: ./upload-theme-assets.sh <store-domain> <access-token> <theme-id> <asset-key> <file-path>
# Example: ./upload-theme-assets.sh vision4k-clone.myshopify.com shpat_xxx 12345 templates/index.json /tmp/index.json
#
# For bulk upload, use: ./upload-theme-assets.sh <store> <token> <theme-id> --bulk <dir>
# This uploads all .json files from <dir> mapped to their Shopify asset keys.

set -euo pipefail

STORE="${1:?Usage: upload-theme-assets.sh <store-domain> <token> <theme-id> <asset-key|--bulk> <file|dir>}"
TOKEN="${2:?Missing access token}"
THEME_ID="${3:?Missing theme ID}"
ASSET_KEY="${4:?Missing asset key or --bulk}"
FILE="${5:?Missing file path or directory}"

STORE="${STORE#https://}"
STORE="${STORE#http://}"
API="https://${STORE}/admin/api/2026-01"

upload_asset() {
  local key="$1"
  local file="$2"
  
  if [ ! -f "$file" ]; then
    echo "❌ File not found: $file" >&2
    return 1
  fi
  
  # Read file content and escape for JSON
  local value
  value=$(python3 -c "
import json, sys
with open('$file') as f:
    content = f.read()
# If the content is valid JSON, compact it slightly to save space
try:
    data = json.loads(content)
    print(json.dumps({'asset': {'key': '$key', 'value': json.dumps(data)}}))
except json.JSONDecodeError:
    print(json.dumps({'asset': {'key': '$key', 'value': content}}))
")
  
  RESULT=$(curl -s -X PUT "${API}/themes/${THEME_ID}/assets.json" \
    -H "X-Shopify-Access-Token: ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$value")
  
  ERROR=$(echo "$RESULT" | jq -r '.errors // empty' 2>/dev/null)
  if [ -n "$ERROR" ] && [ "$ERROR" != "null" ]; then
    echo "❌ Failed to upload ${key}: ${ERROR}" >&2
    return 1
  fi
  
  echo "✅ Uploaded: ${key}"
}

if [ "$ASSET_KEY" = "--bulk" ]; then
  DIR="$FILE"
  if [ ! -d "$DIR" ]; then
    echo "❌ Directory not found: $DIR" >&2
    exit 1
  fi
  
  echo "📦 Bulk uploading theme assets from ${DIR}..."
  
  # Upload each JSON file, mapping filename to Shopify asset key
  find "$DIR" -name "*.json" -type f | while read -r filepath; do
    # Determine the asset key based on file location
    relative=$(python3 -c "import os; print(os.path.relpath('$filepath', '$DIR'))")
    
    # Map common filenames to Shopify asset keys
    case "$relative" in
      index.json|templates/index.json)
        key="templates/index.json"
        ;;
      product.json|templates/product.json)
        key="templates/product.json"
        ;;
      settings_data.json|config/settings_data.json)
        key="config/settings_data.json"
        ;;
      header-group.json|sections/header-group.json)
        key="sections/header-group.json"
        ;;
      footer-group.json|sections/footer-group.json)
        key="sections/footer-group.json"
        ;;
      *)
        key="$relative"
        ;;
    esac
    
    upload_asset "$key" "$filepath"
  done
  
  echo ""
  echo "✅ Bulk upload complete"
else
  upload_asset "$ASSET_KEY" "$FILE"
fi
