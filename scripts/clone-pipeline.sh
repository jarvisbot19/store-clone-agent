#!/bin/bash
# clone-pipeline.sh — Phases 4–9: theme + products + homepage + visual polish
# Usage: bash clone-pipeline.sh <shop-domain> <access-token> <source-url>
# Requires: scrape-store.sh to have been run first (data in /tmp/{domain}-scrape/)

set -euo pipefail

SHOP="${1:?Usage: clone-pipeline.sh <shop-domain> <access-token> <source-url>}"
TOKEN="${2:?}"
SOURCE_URL="${3:?}"

DOMAIN=$(echo "$SOURCE_URL" | sed 's|https\?://||;s|/.*||')
DATE=$(date +%Y-%m-%d)
SCRAPE_DIR="/tmp/${DOMAIN}-scrape"
ASSET_DIR=~/clawd/projects/store-factory/runs/${DOMAIN}-assets
RUN_FILE=~/clawd/projects/store-factory/runs/${DATE}-${DOMAIN}.md

[ ! -d "$SCRAPE_DIR" ] && echo "❌ Scrape data not found at $SCRAPE_DIR — run scrape-store.sh first" && exit 1

# Load scrape env
source "$SCRAPE_DIR/theme.env"

echo "⚡ Clone pipeline starting"
echo "   Store: $SHOP"
echo "   Source: $SOURCE_URL"
echo "   Theme: $SCHEMA_NAME"
echo ""

# ─── Phase 4: Install Impact theme ───────────────────────────────────────────
echo "🎨 Phase 4: Installing Impact theme..."

# Clone theme
if [ ! -d "/tmp/impact-theme" ]; then
  gh repo clone jarvisbot19/impact-theme /tmp/impact-theme -- --depth 1 2>/dev/null
  echo "   Cloned impact-theme from GitHub"
fi

# Create blank theme slot
THEME_ID=$(curl -s -X POST "https://$SHOP/admin/api/2024-01/themes.json" \
  -H "X-Shopify-Access-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"theme":{"name":"Impact Clone","role":"unpublished"}}' | python3 -c "
import sys, json; d = json.load(sys.stdin); print(d['theme']['id'])
")
echo "   Theme slot created: $THEME_ID"

# Push theme files via Shopify CLI
echo "   Pushing theme files..."
shopify theme push \
  --store "$SHOP" \
  --password "$TOKEN" \
  --theme "$THEME_ID" \
  --path /tmp/impact-theme 2>&1 | tail -5

# Publish
curl -s -X PUT "https://$SHOP/admin/api/2024-01/themes/$THEME_ID.json" \
  -H "X-Shopify-Access-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"theme":{"role":"main"}}' | python3 -c "
import sys, json; d = json.load(sys.stdin); print(f'   Published: {d[\"theme\"][\"name\"]} ({d[\"theme\"][\"role\"]})')
"

echo "" >> "$RUN_FILE"
echo "## Phase 4: Theme installed (Impact $THEME_ID)" >> "$RUN_FILE"

# ─── Phase 5: Products ────────────────────────────────────────────────────────
echo ""
echo "📦 Phase 5: Creating products..."

# Get Online Store publication ID
PUB_ID=$(curl -s "https://$SHOP/admin/api/2024-01/publications.json" \
  -H "X-Shopify-Access-Token: $TOKEN" | python3 -c "
import sys, json
pubs = json.load(sys.stdin)['publications']
pub = next(p for p in pubs if p['name'] == 'Online Store')
print(f'gid://shopify/Publication/{pub[\"id\"]}')
")
echo "   Online Store publication: $PUB_ID"

python3 << PYEOF
import json, urllib.request, time

shop = "$SHOP"
token = "$TOKEN"
pub_id = "$PUB_ID"
products = json.load(open('$SCRAPE_DIR/products-final.json'))

headers = {
    'X-Shopify-Access-Token': token,
    'Content-Type': 'application/json'
}

created = 0
failed = 0

for p in products:
    # Build REST payload
    variants = []
    for v in p.get('variants', []):
        var = {
            'price': str(v.get('price', '0.00')),
            'option1': v.get('option1'),
            'option2': v.get('option2'),
            'option3': v.get('option3'),
            'sku': v.get('sku', ''),
        }
        if v.get('compare_at_price'):
            var['compare_at_price'] = str(v['compare_at_price'])
        var = {k: v for k, v in var.items() if v is not None}
        variants.append(var)

    payload = {
        'product': {
            'title': p['title'],
            'body_html': p.get('body_html', ''),
            'vendor': p.get('vendor', ''),
            'product_type': p.get('product_type', ''),
            'handle': p['handle'],
            'tags': p.get('tags', ''),
            'status': 'active',
            'images': [{'src': img['src']} for img in p.get('images', [])[:10]],
            'variants': variants if variants else [{'price': '0.00'}],
        }
    }

    try:
        req = urllib.request.Request(
            f'https://{shop}/admin/api/2024-01/products.json',
            data=json.dumps(payload).encode(),
            headers=headers,
            method='POST'
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            result = json.loads(r.read())
        
        prod_id = result['product']['id']
        
        # Publish to Online Store
        pub_mutation = json.dumps({'query': f'mutation {{ publishablePublish(id: "gid://shopify/Product/{prod_id}", input: [{{publicationId: "{pub_id}"}}]) {{ userErrors {{ message }} }} }}'})
        pub_req = urllib.request.Request(
            f'https://{shop}/admin/api/2024-01/graphql.json',
            data=pub_mutation.encode(),
            headers=headers,
            method='POST'
        )
        urllib.request.urlopen(pub_req, timeout=10)
        
        created += 1
        if created % 5 == 0:
            print(f"   Created {created}/{len(products)} products...")
        time.sleep(0.4)
    except Exception as e:
        failed += 1
        print(f"   ❌ Failed: {p['title']} — {e}")

print(f"   ✅ Done: {created} created, {failed} failed")
PYEOF

# ─── Phase 5b: Collections + product linking ──────────────────────────────────
echo ""
echo "📂 Phase 5b: Creating collections + linking products..."

python3 << PYEOF
import json, urllib.request, time

shop = "$SHOP"
token = "$TOKEN"
headers = {'X-Shopify-Access-Token': token, 'Content-Type': 'application/json'}

# Load scrape data
col_data = json.load(open('$SCRAPE_DIR/collections.json'))
collections = col_data['collections']
product_map = col_data['product_map']

# Get all clone product handles → IDs
print("   Fetching clone product handles...")
handle_to_id = {}
page = 1
while True:
    req = urllib.request.Request(
        f'https://{shop}/admin/api/2024-01/products.json?limit=250&page={page}&fields=id,handle',
        headers=headers
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        prods = json.loads(r.read())['products']
    if not prods:
        break
    for p in prods:
        handle_to_id[p['handle']] = p['id']
    if len(prods) < 250:
        break
    page += 1

print(f"   Handle map: {len(handle_to_id)} products")

# Get Online Store pub ID
req = urllib.request.Request(f'https://{shop}/admin/api/2024-01/publications.json', headers=headers)
pubs = json.loads(urllib.request.urlopen(req, timeout=10).read())['publications']
pub_gid = f"gid://shopify/Publication/{next(p['id'] for p in pubs if p['name'] == 'Online Store')}"

created = 0
linked = 0

for c in collections:
    # Create collection
    payload = {'collection': {
        'title': c['title'],
        'body_html': c.get('body_html', ''),
        'handle': c['handle'],
        'published': True,
    }}
    
    try:
        req = urllib.request.Request(
            f'https://{shop}/admin/api/2024-01/custom_collections.json',
            data=json.dumps(payload).encode(),
            headers=headers,
            method='POST'
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            result = json.loads(r.read())
        col_id = result['custom_collection']['id']
        created += 1
        
        # Publish to Online Store
        pub_q = json.dumps({'query': f'mutation {{ publishablePublish(id: "gid://shopify/Collection/{col_id}", input: [{{publicationId: "{pub_gid}"}}]) {{ userErrors {{ message }} }} }}'})
        pub_req = urllib.request.Request(f'https://{shop}/admin/api/2024-01/graphql.json', data=pub_q.encode(), headers=headers, method='POST')
        urllib.request.urlopen(pub_req, timeout=10)
        
        # Link products via collects
        for handle in product_map.get(c['handle'], []):
            prod_id = handle_to_id.get(handle)
            if prod_id:
                collect = {'collect': {'product_id': prod_id, 'collection_id': col_id}}
                req = urllib.request.Request(
                    f'https://{shop}/admin/api/2024-01/collects.json',
                    data=json.dumps(collect).encode(),
                    headers=headers,
                    method='POST'
                )
                try:
                    urllib.request.urlopen(req, timeout=10)
                    linked += 1
                except:
                    pass
        
        time.sleep(0.3)
    except Exception as e:
        print(f"   ❌ Collection failed: {c['title']} — {e}")

print(f"   ✅ Collections: {created} created, {linked} product-collection links")
PYEOF

# ─── Phase 6: Theme settings + colors ────────────────────────────────────────
echo ""
echo "🎨 Phase 6: Configuring theme colors..."

source "$SCRAPE_DIR/colors.env" 2>/dev/null || true
PRIMARY="${COLOR_3:-#000000}"   # Usually the accent color
ACCENT="${COLOR_2:-#333333}"

python3 << PYEOF
import json

settings = {
    "current": {
        "background": "${COLOR_4:-#ffffff}",
        "text_color": "${COLOR_1:-#2E302C}",
        "header_background": "#ffffff",
        "header_text_color": "${COLOR_1:-#2E302C}",
        "footer_background": "#f3f5f6",
        "footer_text_color": "${COLOR_1:-#2E302C}",
        "primary_button_background": "${COLOR_3:-#000000}",
        "primary_button_text_color": "#ffffff",
        "secondary_button_background": "rgba(0,0,0,0)",
        "secondary_button_text_color": "${COLOR_1:-#2E302C}",
        "page_width": 1300,
        "section_spacing": 0,
    },
    "presets": {}
}

with open('/tmp/clone-settings.json', 'w') as f:
    json.dump(settings, f, indent=2)
print("   Settings JSON ready")
PYEOF

SETTINGS_CONTENT=$(cat /tmp/clone-settings.json | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
curl -s -X PUT "https://$SHOP/admin/api/2024-01/themes/$THEME_ID/assets.json" \
  -H "X-Shopify-Access-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "{\"asset\":{\"key\":\"config/settings_data.json\",\"value\":$SETTINGS_CONTENT}}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'   Settings: {d.get(\"asset\",{}).get(\"key\",\"error\")}')"

# ─── Phase 6b: Currency display patch (force source currency symbol) ──────────
echo ""
echo "💱 Phase 6b: Patching currency display..."

CURRENCY_SYMBOL="£"
if [ "$CURRENCY" = "EUR" ]; then CURRENCY_SYMBOL="€"; fi
if [ "$CURRENCY" = "USD" ]; then CURRENCY_SYMBOL="\$"; fi

curl -s "https://$SHOP/admin/api/2024-01/themes/$THEME_ID/assets.json?asset%5Bkey%5D=snippets%2Fjs-variables.liquid" \
  -H "X-Shopify-Access-Token: $TOKEN" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('asset',{}).get('value',''))" > /tmp/js-variables.liquid

python3 << PYEOF
content = open('/tmp/js-variables.liquid').read()
symbol = "$CURRENCY_SYMBOL"
currency = "$CURRENCY"

content = content.replace(
    'moneyFormat: {{ shop.money_format | json }},',
    f'moneyFormat: "{symbol}{{{{amount}}}}",  {{%- comment -%}} Override: force {currency} display {{%- endcomment -%}}'
).replace(
    'moneyWithCurrencyFormat: {{ shop.money_with_currency_format | json }},',
    f'moneyWithCurrencyFormat: "{symbol}{{{{amount}}}} {currency}",  {{%- comment -%}} Override: force {currency} display {{%- endcomment -%}}'
)

open('/tmp/js-variables-patched.liquid', 'w').write(content)
changed = content.count(symbol)
print(f"   Currency symbol {symbol} injected in {changed} place(s)")
PYEOF

JS_CONTENT=$(cat /tmp/js-variables-patched.liquid | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
curl -s -X PUT "https://$SHOP/admin/api/2024-01/themes/$THEME_ID/assets.json" \
  -H "X-Shopify-Access-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "{\"asset\":{\"key\":\"snippets/js-variables.liquid\",\"value\":$JS_CONTENT}}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'   js-variables: {d.get(\"asset\",{}).get(\"updated_at\",\"error\")}')"

echo ""
echo "✅ Phases 4–6 complete!"
echo "   Next steps (run manually or via build-homepage.py):"
echo "   7. Upload CDN assets via fileCreate mutations"
echo "   8. Build and upload templates/index.json (homepage)"
echo "   9. Configure header-group.json (logo, nav, announcement bar)"
echo "   10. Run visual diff (screenshot both stores, compare, fix)"
echo ""
echo "   THEME_ID=$THEME_ID" | tee -a "$RUN_FILE"
