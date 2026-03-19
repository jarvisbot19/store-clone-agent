# Skill: Store Clone

Clone a live Shopify store into a development store. Produces a near-identical copy including products, pages, theme, branding, navigation, and markets.

## When to Use
- User drops a Shopify store URL in #store-factory
- User asks to clone/copy/replicate a Shopify store
- User says "clone this", "copy this store", or similar

## Prerequisites
- Store Factory repo at `~/projects/store-factory/`
- Shopify Partner account (org ID in env)
- Access to premium theme repos (if needed)
- `cloudflared` installed for tunnel hosting
- `jq`, `python3`, `curl` available

## Parallelization Strategy

**Run Track A and Track B simultaneously from the start.** They have zero dependencies on each other.

| Track A (terminal — run immediately) | Track B (browser — run simultaneously) |
|---|---|
| `bash scrape-store.sh https://source-store.com` | Open Shopify Partner Dashboard |
| Scrapes + price-checks + downloads assets | Create dev store (set correct country/currency!) |
| ~5 min | Create custom app, copy token |
| | ~5 min |

After both tracks complete, run:
```bash
bash clone-pipeline.sh {shop-domain} {token} {source-url}
```
Then complete Phases 6–9.5 manually (homepage, header config, visual diff).

**Time savings:** ~10–15 min vs sequential approach.

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/scrape-store.sh <url>` | Phases 0+1+2: scrape, price-check, download assets, create run log |
| `scripts/clone-pipeline.sh <shop> <token> <url>` | Phases 4+5+6: theme install, products+collections, color settings, currency patch |
| `scripts/visual-diff.sh <source> <clone>` | Phase 9.5: visual diff checklist |
| `scripts/build-homepage.py` | Build templates/index.json from extracted sections |

---

## Theme Policy

**Impact theme ALWAYS comes from `jarvisbot19/impact-theme` on GitHub.** Never download from Shopify theme store, never use zip upload.

**If source theme is available in our GitHub library** (`jarvisbot19/{theme}`): install it exactly using `shopify theme push` (CLI), NOT zip upload via API.
**If source theme is NOT available** (paid themes like Organic, Prestige, etc.): use **Impact + custom-html sections** automatically. No prompting needed — just note it in the run log.

Current library:
- `jarvisbot19/impact-theme` — Impact 6.4.1 ← **Use this for Impact and as fallback**
- `jarvisbot19/shrine_1-3-0_original` — Shrine 1.3.0 (if accessible)

### Impact Theme Install (ALWAYS use this method):
```bash
gh repo clone jarvisbot19/impact-theme /tmp/impact-theme -- --depth 1

THEME_ID=$(curl -s -X POST "https://${CLONE_DOMAIN}/admin/api/2024-01/themes.json" \
  -H "X-Shopify-Access-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"theme":{"name":"Impact","role":"unpublished"}}' | jq -r '.theme.id')

shopify theme push \
  --store "${CLONE_DOMAIN}" \
  --password "${TOKEN}" \
  --theme ${THEME_ID} \
  --path /tmp/impact-theme

curl -X PUT "https://${CLONE_DOMAIN}/admin/api/2024-01/themes/${THEME_ID}.json" \
  -H "X-Shopify-Access-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"theme":{"role":"main"}}'
```
⚠️ **DO NOT use zip upload via API** — premium themes get a "locked" role. CLI push bypasses this.

---

## Workflow

Execute these phases in order. Run **Track A** (`scrape-store.sh`) and **Track B** (browser dev store creation) in parallel. Log everything in the run file.

---

### Phase 0: Setup Run Log
```bash
DATE=$(date +%Y-%m-%d)
DOMAIN=$(echo "$SOURCE_URL" | sed 's|https\?://||;s|/.*||')
RUN_DIR=~/clawd/projects/store-factory/runs
RUN_FILE="$RUN_DIR/${DATE}-${DOMAIN%.myshopify.com}.md"
ASSET_DIR="$RUN_DIR/${DOMAIN%.myshopify.com}-assets"
mkdir -p "$ASSET_DIR"/{branding,product,homepage,gifs,video,bundles}
```
Create the run file with template from `references/run-template.md`.

---

### Phase 1: Scrape Source Store (~1 min)

#### 1a. Products
```bash
curl -s "https://${DOMAIN}/products.json?limit=250" | jq '.products | length'
# If >250, paginate: &page=2, &page=3, etc.
```
For each product, capture: handle, title, body_html, price, compare_at_price, images, variants, vendor, tags.

**Verify prices against source BEFORE creating products.** Many stores have products that look like £0 on `/products.json` because they're sold only in bundles — but on the source store they're actually priced. Always cross-check: `curl "https://{source}/products/{handle}.json" | jq '.product.variants[0].price'`

**Filter out** internal Shopify utility products — these are created by third-party apps and should never appear on a cloned storefront.
- Vendor matches: `S:EDD`, `Route`, `Navidium`, `Corso`, `Upsell`, `Rebuy`, `Loyalty` (case-insensitive)
- Title matches: `Shipping Protection`, `Shipping Insurance`, `Shipping - Returns`, `Item Personalization`, `Bundle Test`, `Addons`
This filter is now built into the scraper's `config-mapper.ts` (`isRealProduct()`), but validate manually before running the pipeline.

#### 1b. Collections
```bash
curl -s "https://${DOMAIN}/collections.json" | jq '.collections[] | {handle, title}'
```

#### 1c. Pages & Policies
Check each common handle:
```bash
for page in about contact faq shipping-and-returns; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/pages/${page}")
  echo "$page: $STATUS"
done
```
Scrape content from accessible pages. Also check `/policies/privacy-policy`, `/policies/terms-of-service`, `/policies/refund-policy`, `/policies/shipping-policy`.

#### 1d. Theme Identification (CRITICAL)
```bash
curl -s "https://${DOMAIN}" | grep -o 'Shopify\.theme = {[^}]*}'
```
Extract `schema_name` and `schema_version`. Record in run log.

#### 1e. Homepage Section IDs
```bash
curl -s "https://${DOMAIN}" | python3 -c "
import sys, re
for sid in re.findall(r'id=\"shopify-section-([^\"]+)\"', sys.stdin.read()):
    print(sid)"
```

#### 1f. Branding & SEO
Extract from page source: logo URL, favicon, OG image, meta title, meta description, social links.

#### 1g. CSS Design Audit — REQUIRED before any theme work ⚠️
**Run this via browser JS on the live source store BEFORE touching any theme files.**
This is the spec that prevents layout bugs in the clone.

```javascript
// Run in browser console on the source store
const sectionSpecs = {};
document.querySelectorAll('[id^="shopify-section-template"]').forEach(el => {
  const key = el.id.split('__')[1];
  const computed = window.getComputedStyle(el);
  const rect = el.getBoundingClientRect();
  
  // Capture all custom CSS properties used by Impact
  const cssVars = {};
  const varNames = [
    '--section-spacing-block', '--section-outer-spacing-block', '--section-spacing-inline',
    '--content-over-media-overlay', '--images-scrolling-block-count', '--images-scrolling-image-ratio',
    '--testimonial-list-items-per-row', '--product-grid', '--product-gallery-media-list-grid',
    '--logo-list-item-max-size', '--rich-text-max-width',
  ];
  varNames.forEach(v => {
    const val = computed.getPropertyValue(v).trim();
    if (val) cssVars[v] = val;
  });
  
  sectionSpecs[key] = {
    height: Math.round(rect.height),
    width: Math.round(rect.width),
    display: computed.display,
    visible: rect.height > 0,
    cssVars,
  };
});
console.log(JSON.stringify(sectionSpecs, null, 2));
```

Also capture global theme settings:
```javascript
// Global color/font settings
const root = window.getComputedStyle(document.documentElement);
const themeVars = [
  '--color-base-background-1','--color-base-accent-1','--color-base-text',
  '--font-heading-family','--font-body-family',
  '--page-width','--grid-gutter',
];
const settings = {};
themeVars.forEach(v => settings[v] = root.getPropertyValue(v).trim());
console.log(JSON.stringify(settings, null, 2));
```

**Save the output as `runs/{domain}-assets/css-audit.json`.**

Key values to capture and use when rebuilding sections:
- Section heights (to detect oversized sections in clone early)
- `display: none` sections (identify which are mobile-only vs desktop-only before stripping @media)
- CSS custom property values (inject these directly when the scoped styles can't be uploaded)
- Color palette hex values
- Font families

---

### Phase 2: Download Assets (~2 min)

Download all product images, branding, homepage images/GIFs/videos into `$ASSET_DIR`.

```bash
# Product images
curl -sL "https://${DOMAIN}/products.json?limit=250" | \
  jq -r '.products[].images[].src' | while read url; do
    filename=$(basename "$url" | sed 's/\?.*//')
    curl -sL "$url" -o "$ASSET_DIR/product/$filename"
  done
```

Note Unsplash/stock URLs separately (reuse, don't download).

---

### Phase 3: Create Dev Store (~5 min, browser)

1. Open Shopify Partner Dashboard via browser
2. Create development store:
   - Store name: `{brand}-clone` or `{domain}-clone`
   - Country/currency: MUST match source store's primary market (e.g. UK/GBP for feelhum.com)
   - ⚠️ **Dev store password CANNOT be removed** — this is a Shopify platform restriction. The store will always require a password until transferred to a paid plan.
3. Create custom app "Store Factory" with ALL Admin API scopes
4. **Verify scope count before saving** (Shopify's checkbox UI is unreliable)
5. Install the app → copy the one-time access token immediately
6. Record store URL + token in run file

> **Currency note:** If you set the wrong currency/country at store creation, you must fix it manually in Admin → Settings → Markets. The API (`PUT /shop.json`) does not allow currency changes — it returns 406.

---

### Phase 4: Install Matching Theme (~5 min)

Use the theme identified in Phase 1d.

**If available on GitHub (Impact, Shrine, etc.):**
1. Fork/use existing fork at `jarvisbot19/{theme}`
2. Clone locally:
   ```bash
   gh repo clone jarvisbot19/{theme} /tmp/{theme-dir} -- --depth 1
   ```
3. **Use Shopify CLI push (NOT zip upload)** — zip upload via `POST /themes.json` causes a "locked" role on dev stores when Shopify detects a premium theme. CLI push bypasses this:
   ```bash
   # First create an empty theme slot
   THEME_ID=$(curl -s -X POST "https://${CLONE_DOMAIN}/admin/api/2024-01/themes.json" \
     -H "X-Shopify-Access-Token: ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"theme":{"name":"${THEME_NAME}","role":"unpublished"}}' | jq -r '.theme.id')

   # Then push all files via CLI
   shopify theme push \
     --store "${CLONE_DOMAIN}" \
     --password "${TOKEN}" \
     --theme ${THEME_ID} \
     --path /tmp/{theme-dir}
   ```
4. Publish:
   ```bash
   curl -X PUT "https://${CLONE_DOMAIN}/admin/api/2024-01/themes/${THEME_ID}.json" \
     -H "X-Shopify-Access-Token: ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"theme":{"role":"main"}}'
   ```

**If theme is not available (e.g. paid theme like Organic, Dawn, Prestige):**
- State this explicitly to the user before proceeding
- Use Impact as the closest general-purpose fallback
- All section content gets ported as `custom-html` blocks
- Accept visual differences in font rendering, section chrome, and spacing

---

### Phase 5: Run Store Factory Pipeline (~2 min)

**Agent Mode does NOT use the Store Factory dashboard.** Run curl/API calls directly.

Pipeline steps to execute manually in sequence:
1. **Products** — scrape from `/products.json`, filter utility products, create via REST `POST /products.json`, publish to Online Store
2. **Collections** — scrape from `/collections.json`, create via GraphQL `collectionCreate`, publish to Online Store
3. **Link products to collections** — `POST /collects.json` for each product×collection pair — **DO NOT SKIP THIS STEP**
4. **Pages** — scrape and create via `POST /pages.json`
5. **Policies** — scrape and update via GraphQL `policyUpdate`
6. **Navigation** — create menus via GraphQL `menuCreate` or `menuUpdate`
7. **Markets** — create UK/EU markets via GraphQL if source is non-US

What the API can and cannot do:
- ✅ Product creation with handle, price, compare-at-price, body_html, images
- ✅ Auto-publish products and collections to Online Store
- ✅ Market creation + enable
- ✅ Menu creation + update
- ⚠️ Storefront password: **cannot be disabled on dev stores** — inform user upfront
- ⚠️ Store currency: cannot change via API — fix in Admin → Markets UI
- ⚠️ Shipping: configure manually in admin
- ⚠️ Taxes: configure manually in admin
- ⚠️ Logo/branding: `brandingUpdate` mutation does not exist on custom apps — set logo in theme editor UI

---

### Phase 6: Rebuild Homepage (~20-30 min)

Use the theme extraction scripts to automate most of this.

#### 6a. Extract Source Sections
Run the extraction script for each homepage section:
```bash
# Extract each section's HTML
for SECTION_ID in $(cat /tmp/source-sections.txt); do
  curl -s "https://${DOMAIN}/?section_id=${SECTION_ID}" > "/tmp/sections/${SECTION_ID}.html"
done
```

#### 6a-pre. Load CSS Audit
Before building any sections, load `runs/{domain}-assets/css-audit.json` and:
1. Identify which sections have `visible: false` (height=0) — these need `display:none` injected
2. For each section, note the CSS var values to inject if the scoped style block can't be uploaded
3. Cross-check target section heights — if any exceed source by >20%, flag as broken layout

#### 6b. Map to Theme Section Types
For Impact theme, common mappings:
| Source Content | Impact Section Type |
|---------------|-------------------|
| Hero video/image | `custom-html` |
| Social proof bar | `custom-html` |
| Benefits/features | `custom-html` |
| Featured product | `featured-product` (with `liquid` blocks) |
| How-it-works | `custom-html` |
| Testimonials | `custom-html` |
| FAQ accordion | `custom-html` |

#### 6c. Build and Upload templates/index.json
Assemble the section JSON and upload via Theme Asset API:
```bash
curl -X PUT "https://${CLONE_DOMAIN}/admin/api/2026-01/themes/${THEME_ID}/assets.json" \
  -H "X-Shopify-Access-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"asset":{"key":"templates/index.json","value":"..."}}'
```

#### 6d. Configure Theme Settings
Extract and apply:
- Color scheme (background, text, primary, secondary colors)
- Typography (heading + body fonts, sizes, letter-spacing)
- Header (sticky, logo position, nav items)
- Footer (newsletter, links, contact info)
- Announcement bar (scrolling text, colors)
- Cart drawer settings

Upload `config/settings_data.json` patch via Asset API.

#### 6e. Configure Section Groups
Upload header and footer group JSON:
- `sections/header-group.json`
- `sections/footer-group.json`

---

### Phase 6.5: Re-host All Source CDN Assets (CRITICAL)

After rebuilding the homepage, ALL references to the source store's CDN must be replaced with clone-hosted files. If skipped, the store breaks if the source deletes assets.

#### 6.5a. Upload all assets to clone's Files API
```python
# Use fileCreate mutation with originalSource URL — Shopify fetches from source CDN
mutation fileCreate($files: [FileCreateInput!]!) {
    fileCreate(files: $files) {
        files { ... on MediaImage { id image { url } } }
        userErrors { field message }
    }
}
# Input: {"files": [{"originalSource": "<source-CDN-URL>", "filename": "name.ext", "contentType": "IMAGE"}]}
```

For videos: download locally first, create staged upload, POST the file, then fileCreate with the resourceUrl.

#### 6.5b. Build URL replacement map
```bash
# Find ALL source store references (both formats):
# 1. https://source-store.com/cdn/shop/files/...
# 2. https://cdn.shopify.com/s/files/1/{SOURCE_STORE_ID}/files/...
# 3. //source-store.com/cdn/... (protocol-relative)
```

#### 6.5c. Replace in ALL theme assets
Templates to check: `templates/index.json`, `templates/product.json`, `config/settings_data.json`, `sections/header-group.json`, `sections/footer-group.json`

**Important:** URLs in theme JSON are escaped with `\\/` — replacements must match this exact format.

Also replace source store email addresses in footer/contact content.

#### 6.5d. Verify zero source refs remaining
```bash
for template in templates/index.json templates/product.json config/settings_data.json sections/header-group.json sections/footer-group.json; do
  # Count remaining source store references
  curl -s ".../assets.json?asset[key]=$template" | grep -c "source-domain\|SOURCE_STORE_ID"
done
```

---

### Phase 7: Product Page Template (~10 min)

If source has a customized product page:
1. Extract `templates/product.json` structure from source
2. Port custom blocks (specs, urgency, trust badges)
3. Upload via Asset API

---

### Phase 8: Menus & Navigation (~5 min)

Verify pipeline-created menus match source. Fix via Admin API if needed:
- Main menu items + URLs
- Footer menu items + URLs
- All links resolve to existing pages/collections

---

### Phase 9: Verify & Log (~5 min)

⛔ **HARD GATE — do NOT declare done until this checklist is fully green.**
Verify via actual storefront URL, not admin. Open the store in a browser before sending any "done" message.

Checklist:
- [ ] Products visible on storefront `/collections/all` (not just admin — visit the URL!)
- [ ] Product counts match source store (check `GET /products/count.json` vs source)
- [ ] Product prices correct (not £0.00 for paid items)
- [ ] Product handles match source
- [ ] Homepage sections render correctly
- [ ] Header/footer/announcement bar match
- [ ] Navigation links work
- [ ] Footer pages accessible
- [ ] Markets created and enabled
- [ ] Mobile layout works
- [ ] Cart drawer works

Update run file with final status and any remaining TODOs.

---

## ⚠️ HOMEPAGE HTML EXTRACTION RULES (CRITICAL — learned from Popcard 2026-03-19)

When porting source section HTML into `custom-html` blocks, follow this exact cleaning order:

### Step 1: Strip scripts only
```python
html = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL)
html = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
```

### Step 2: Strip `@keyframes` from style blocks (NOT entire style blocks)
Shopify's Liquid validator triggers on `@keyframes { 0% { ... } }` (nested braces).
Remove only animation keyframe blocks, NOT the scoped CSS vars Impact needs:
```python
html = re.sub(r'@keyframes\s+\w+\s*\{[^{]*(\{[^}]*\}[^{]*)*\}', '', html, flags=re.DOTALL)
```

### Step 3: Do NOT strip srcset
Keep `srcset` attributes — they're needed for responsive image sizing (no Liquid, just URLs).

### Step 4: Check for false-positive patterns
After cleaning, scan for anything that looks like nested braces to Shopify:
```python
bad = re.findall(r'\{[^}]{0,30}\{', html)  # catches @keyframes and JS template literals
```
If found, fix surgically (don't nuke the whole section).

### Step 5: Product prices
After pipeline run, ALWAYS verify prices with: `GET /products.json` and compare vs source.
The pipeline often creates products at `0.00` — this must be fixed before calling it done.

### Step 6: Shopify CDN cache
After uploading new theme assets, the storefront may serve stale HTML for 5-15 minutes.
To force recompile: push all files via `shopify theme push --allow-live` (CLI, not just API).
To verify you're seeing the latest: check `server-timing: theme;desc="{THEME_ID}"` in response headers matches the expected theme.

---

## Phase 9.5: Side-by-Side Visual Diff (NEW — required after Phase 9)

After declaring Phase 9 complete, take full-page screenshots of BOTH the source store and the clone, then compare them with an image model prompt:

```
Compare these two Shopify store homepages side by side in detail. 
List every visual difference: header, navigation, announcement bar, hero, colors, fonts, 
sections, images, footer, spacing. Be specific.
```

⛔ **DO NOT send a "done" message until this screenshot comparison passes.**
The exit criterion is visual parity at the hero level, not just content presence in HTML.

Then systematically fix each difference:
1. **Color palette** — extract exact hex values from source HTML (`#2c423f`, `#e9a360`, etc.)
2. **Impact color settings** — use `config/settings_data.json` `current` object with Impact's specific keys:
   - `header_background`, `header_text_color` — controls header
   - `footer_background`, `footer_text_color` — controls footer
   - `primary_button_background`, `primary_button_text_color` — CTA buttons
   - `background`, `text_color` — global page colors
3. **Logo** — use `shopify://shop_images/{filename}` format in `sections/header-group.json` → `header.settings.logo`
4. **Currency display** — if API-blocked, patch `snippets/js-variables.liquid` to hardcode `moneyFormat: "£{{amount}}"` and `moneyWithCurrencyFormat: "£{{amount}} GBP"`
5. **Announcement bar color** — set in `sections/header-group.json` → `announcement-bar.settings.background`
6. **Nav items** — update `main-menu` via `menuUpdate` GraphQL mutation to exactly match source

## Known Issues & Workarounds

| Issue | Workaround |
|-------|-----------|
| `stagedUploadsCreate` denied for SHOP_IMAGE | Upload branding manually in admin |
| Shipping DeliveryProfile location group input | Manual shipping config in admin |
| Tax-inclusive pricing not in API | Configure manually in admin |
| `shopUpdate` mutation removed | Use REST `PUT /shop.json` (406 on some fields — unavoidable) |
| Theme zip upload → "locked" role | Use `shopify theme push --store --password --theme <id>` CLI instead |
| GitHub archive zips nest files in folder | Repackage flat before upload |
| Dev store storefront password | CANNOT be removed — Shopify enforces it. Only option: upgrade to paid plan |
| Store currency (USD→GBP) via API | `PUT /shop.json` returns 406. `marketCurrencySettingsUpdate` blocked by Unified Markets. Workaround: patch `snippets/js-variables.liquid` to hardcode `moneyFormat: "£{{amount}}"` for display. Header currency selector still shows store default — delete extra markets to minimize selector. |
| Logo in Impact header-group.json | Use `shopify://shop_images/{filename}` format — NOT a GID, NOT a CDN URL. Works via Asset API. |
| `brandingUpdate` mutation | Does not exist on custom apps. Set logo via `shopify://shop_images/` in header-group.json instead. |
| `marketSetPrimary` mutation | Does not exist. Change primary market via Shopify Admin UI |

## Timing Targets
| Phase | Target | Notes |
|-------|--------|-------|
| Scrape | 1 min | Automated |
| Assets | 2 min | Automated |
| Dev store + app | 5 min | Browser |
| Theme install | 5 min | Semi-automated |
| Pipeline | 2 min | Automated |
| Homepage rebuild | 20-30 min | Biggest variable |
| Product page | 10 min | If customized |
| Menus/nav | 5 min | Verify + fix |
| Verify | 5 min | Checklist |
| **Total** | **~55-65 min** | Down from ~2h |

## Run Log Location
`~/clawd/projects/store-factory/runs/YYYY-MM-DD-{domain}.md`

## References
- `references/run-template.md` — Template for run log files
- Playbooks at `~/clawd/projects/store-factory/playbooks/`
- Project memory at `~/clawd/projects/store-factory/MEMORY.md`
