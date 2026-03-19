#!/usr/bin/env bash
# Extract theme name and version from a Shopify store
# Usage: ./extract-theme.sh <store-domain>
# Example: ./extract-theme.sh getvision4k.com
#
# Output: JSON with theme name, schema_name, schema_version

set -euo pipefail

DOMAIN="${1:?Usage: extract-theme.sh <store-domain>}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

# Fetch page source and extract Shopify.theme object
THEME_RAW=$(curl -sL "https://${DOMAIN}" | grep -o 'Shopify\.theme = {[^}]*}' | head -1 | sed 's/Shopify\.theme = //')

if [ -z "$THEME_RAW" ]; then
  echo '{"error": "Could not find Shopify.theme in page source", "domain": "'${DOMAIN}'"}'
  exit 1
fi

# Parse with python for reliable JSON extraction
python3 -c "
import json, sys, re

raw = r'''${THEME_RAW}'''
# Clean up JS object to valid JSON (handle unquoted keys, trailing commas)
# Shopify.theme is usually valid JSON already
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    # Try fixing common JS→JSON issues
    fixed = re.sub(r'(\w+):', r'\"\\1\":', raw)
    fixed = re.sub(r',\s*}', '}', fixed)
    data = json.loads(fixed)

result = {
    'domain': '${DOMAIN}',
    'theme_name': data.get('name', 'Unknown'),
    'schema_name': data.get('schema_name', 'Unknown'),
    'schema_version': data.get('schema_version', 'Unknown'),
    'theme_store_id': data.get('theme_store_id'),
    'role': data.get('role', 'main'),
}
print(json.dumps(result, indent=2))
"
