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

## ⚠️ GOLDEN RULE: Configure Impact, Don't Rewrite It

The Impact theme is a highly configurable design system with dozens of native section types, each with rich schema settings and block support. Your job is to CONFIGURE it via JSON, not bypass it with custom HTML.

**For every section on the source store:**

1. First check if an Impact native section can reproduce it via JSON settings
1. Only fall back to custom code when no native section can achieve 85%+ match

**`build-homepage.py` currently wraps everything in `custom-html` — DO NOT rely on its output blindly.** You must override its decisions using the Tier 1/Tier 2 classification system described in Phase 6.

-----

## Parallelization Strategy

**Run Track A and Track B simultaneously from the start.** They have zero dependencies on each other.

|Track A (terminal — run immediately) |Track B (browser — run simultaneously) |
|-----------------------------------------------|------------------------------------------------|
|`bash scrape-store.sh https://source-store.com`|Open Shopify Partner Dashboard |
|Scrapes + price-checks + downloads assets |Create dev store (set correct country/currency!)|
|~5 min |Create custom app, copy token |
| |~5 min |

After both tracks complete, run:

```bash
bash clone-pipeline.sh {shop-domain} {token} {source-url}
```

Then complete Phases 6–9.5 (homepage, header config, visual diff).

**Time savings:** ~10–15 min vs sequential approach.

-----

## Scripts

|Script |Purpose |Notes |
|------------------------------------------------|-----------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
|`scripts/scrape-store.sh <url>` |Phases 0+1+2: scrape, price-check, download assets, create run log |Includes utility product filter |
|`scripts/clone-pipeline.sh <shop> <token> <url>`|Phases 4+5+6 partial: theme install, products+collections, color settings, currency patch|Colors are approximate — refine in Phase 6-pre |
|`scripts/extract-sections.sh <domain> [dir]` |Extract homepage section HTML via Section Rendering API |Use output for Tier 2 sections ONLY |
|`scripts/extract-settings.sh <domain>` |Extract colors, fonts, social links from source CSS/meta |⚠️ Use this output to refine settings_data.json |
|`scripts/extract-theme.sh <domain>` |Identify source theme name + version | |
|`scripts/download-assets.sh <domain> [dir]` |Download product images, branding, homepage media | |
|`scripts/build-homepage.py <sections-dir>` |Build templates/index.json from extracted sections |⚠️ Currently defaults to custom-html — override with Tier 1 classifications|
|`scripts/build-schema-index.py <theme-path>` |Parse Impact {% schema %} blocks → impact-schema-index.json |Run after theme install |
|`scripts/upload-theme-assets.sh` |Upload theme assets via Shopify Asset API |Supports –bulk mode |
|`scripts/visual-diff.sh <source> <clone>` |Phase 9.5: visual diff checklist |Outputs instructions, not automated screenshots |

-----

## Theme Policy

**Impact theme ALWAYS comes from `jarvisbot19/impact-theme` on GitHub.** Never download from Shopify theme store, never use zip upload.

**If source theme is available in our GitHub library** (`jarvisbot19/{theme}`): install it exactly using `shopify theme push` (CLI), NOT zip upload via API.
**If source theme is NOT available** (paid themes like Organic, Prestige, etc.): use **Impact + native section configuration** as the primary approach, with custom sections only where Impact has no equivalent.

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

### Error Recovery for Theme Push

If `shopify theme push` fails:

1. Read the error output — most failures are Liquid syntax errors in custom section files
1. Common causes: nested `{}` in inline CSS, unclosed tags, invalid Liquid syntax
1. Fix the offending file, then retry push
1. If push hangs or times out: check network, retry with `--nodelete` flag
1. After successful push, verify theme is active: `GET /admin/api/2024-01/themes.json` should show `role: "main"`

-----

## WORKFLOW

### Phase 0: Setup Run Log

```bash
DATE=$(date +%Y-%m-%d)
DOMAIN=$(echo "$SOURCE_URL" | sed 's|https\?://||;s|/.*||')
RUN_DIR=~/clawd/projects/store-factory/runs
RUN_FILE="$RUN_DIR/${DATE}-${DOMAIN%.myshopify.com}.md"
ASSET_DIR="$RUN_DIR/${DOMAIN%.myshopify.com}-assets"
mkdir -p "$ASSET_DIR"/{branding,product,homepage,gifs,video,bundles,sections}
```

Create the run file with template from `references/run-template.md`.

-----

### Phase 1: Scrape Source Store (~1 min)

Run `scripts/scrape-store.sh <url>` which handles all of 1a–1g automatically.

#### What the script does:

- **1a. Theme identification** — extracts `Shopify.theme` (schema_name + version)
- **1b. Currency detection** — from page source patterns + symbol detection
- **1c. Color palette** — top 8 hex colors from HTML (⚠️ approximate only — refine later with `extract-settings.sh`)
- **1d. Products + price verification** — paginated scrape, utility product filter, zero-price cross-check
- **1e. Collections** — with product-to-collection mapping
- **1f. Homepage section IDs** — extracts all section IDs + downloads their HTML
- **1g. Branding** — CDN image URLs, logo, favicon

#### Utility Product Filter (built into scraper)

The scraper automatically filters out app-injected utility products:

- **Vendor matches:** S:EDD, Route, Navidium, Corso, Upsell, Rebuy, Loyalty (case-insensitive)
- **Title matches:** Shipping Protection, Shipping Insurance, Shipping - Returns, Item Personalization, Bundle Test, Addons, Test

Verify the filter output manually before running the pipeline — check `$SCRAPE_DIR/skipped.json`.

#### 1h. Run extract-settings.sh (REQUIRED — scrape-store.sh doesn't do this)

```bash
bash scripts/extract-settings.sh $DOMAIN > $ASSET_DIR/extracted-settings.json
```

This extracts proper CSS variable colors, Google Fonts, font CSS variables, social links, and announcement bar text. **This output is more accurate than the color hex scrape in scrape-store.sh** and MUST be used when configuring `settings_data.json` in Phase 6-pre.

### Phase 1g-browser: Full Design Audit ⚠️ REQUIRED — manual browser step

**scrape-store.sh does NOT do this step.** You must run this JS in the browser console on the live source store.

Run on EACH of these pages:

1. **Homepage** — `https://{domain}/`
1. **A product page** — `https://{domain}/products/{top-product-handle}`
1. **A collection page** — `https://{domain}/collections/{main-collection-handle}`

```javascript
const sectionSpecs = {};
document.querySelectorAll('[id^="shopify-section"]').forEach(el => {
 const key = el.id;
 const computed = window.getComputedStyle(el);
 const rect = el.getBoundingClientRect();

 // Capture ALL CSS custom properties
 const cssVars = {};
 const allProps = [...computed];
 allProps.filter(p => p.startsWith('--')).forEach(v => {
 cssVars[v] = computed.getPropertyValue(v).trim();
 });

 // Child structure for layout mapping
 const children = [...el.children].map(child => ({
 tag: child.tagName,
 classes: [...child.classList],
 rect: {
 width: Math.round(child.getBoundingClientRect().width),
 height: Math.round(child.getBoundingClientRect().height)
 }
 }));

 // Typography snapshot
 const headings = [...el.querySelectorAll('h1,h2,h3,h4,h5,h6,p,.button,.btn')]
 .slice(0, 10).map(h => ({
 tag: h.tagName,
 classes: [...h.classList].join(' '),
 fontSize: window.getComputedStyle(h).fontSize,
 fontFamily: window.getComputedStyle(h).fontFamily,
 fontWeight: window.getComputedStyle(h).fontWeight,
 lineHeight: window.getComputedStyle(h).lineHeight,
 letterSpacing: window.getComputedStyle(h).letterSpacing,
 color: window.getComputedStyle(h).color,
 text: h.textContent.trim().substring(0, 50)
 }));

 // Background detection
 const bg = computed.backgroundImage !== 'none'
 ? computed.backgroundImage : computed.backgroundColor;

 // Image inventory with aspect ratios
 const images = [...el.querySelectorAll('img')].map(img => ({
 src: img.src,
 alt: img.alt,
 naturalWidth: img.naturalWidth,
 naturalHeight: img.naturalHeight,
 aspectRatio: img.naturalWidth && img.naturalHeight
 ? (img.naturalWidth / img.naturalHeight).toFixed(2) : null,
 displayWidth: Math.round(img.getBoundingClientRect().width),
 displayHeight: Math.round(img.getBoundingClientRect().height),
 srcset: img.srcset || null
 }));

 sectionSpecs[key] = {
 height: Math.round(rect.height),
 width: Math.round(rect.width),
 padding: computed.padding,
 margin: computed.margin,
 display: computed.display,
 gap: computed.gap,
 visible: rect.height > 0,
 background: bg,
 borderRadius: computed.borderRadius,
 overflow: computed.overflow,
 cssVars,
 childCount: children.length,
 children,
 headings,
 images,
 sectionType: el.dataset.sectionType || el.className
 };
});
console.log(JSON.stringify(sectionSpecs, null, 2));
```

Also capture global theme settings (run once on homepage):

```javascript
const root = window.getComputedStyle(document.documentElement);
const globalVars = {};
[...root].filter(p => p.startsWith('--')).forEach(v => {
 globalVars[v] = root.getPropertyValue(v).trim();
});
console.log(JSON.stringify(globalVars, null, 2));
```

Save outputs:

- `runs/{domain}-assets/css-audit-homepage.json`
- `runs/{domain}-assets/css-audit-product.json`
- `runs/{domain}-assets/css-audit-collection.json`
- `runs/{domain}-assets/global-css-vars.json`

**Purpose:** This data drives ALL decisions in Phase 6 — section mapping, spacing, colors, typography, image ratios, visibility. Without it you're guessing.

-----

### Phase 2: Download Assets (~2 min)

Run `scripts/download-assets.sh <domain> <output-dir>` or let `scrape-store.sh` handle it.

- Downloads product images, branding (logo, favicon, OG image), homepage media (images, GIFs, videos)
- **NEVER substitute a different font or use a placeholder image**
- For SVG icons: preserve exact SVG code
- For fonts: check if Google Fonts (load via font_url) or custom (upload to assets/)

-----

### Phase 3: Create Dev Store (~5 min, browser)

1. Open Shopify Partner Dashboard via browser
1. Create development store:
- Store name: `{brand}-clone` or `{domain}-clone`
- Country/currency: **MUST match source store's primary market** (e.g. UK/GBP for feelhum.com)
- ⚠️ **Dev store password CANNOT be removed** — Shopify platform restriction
1. Create custom app "Store Factory" with ALL Admin API scopes
1. **Verify scope count before saving** (Shopify's checkbox UI is unreliable)
1. Install the app → copy the one-time access token immediately
1. Record store URL + token in run file

> **Currency note:** If you set the wrong currency/country at store creation, you must fix it manually in Admin → Settings → Markets. The API (`PUT /shop.json`) does not allow currency changes — it returns 406.

-----

### Phase 4: Install Theme + Run Pipeline

Run `scripts/clone-pipeline.sh {shop} {token} {source-url}`

This handles:

- **Phase 4a:** Clone `jarvisbot19/impact-theme` from GitHub
- **Phase 4b:** Create theme slot, push via CLI, publish
- **Phase 5a:** Create products (with price fixes applied)
- **Phase 5b:** Create collections + link products via collects
- **Phase 5c:** Apply approximate color settings
- **Phase 5d:** Patch currency display in `snippets/js-variables.liquid`

⚠️ **After clone-pipeline.sh finishes, the theme is installed but the homepage is NOT configured.** Continue to Phase 4.5.

### Phase 4.5: Build Impact Schema Index ⚠️ REQUIRED before Phase 6

Parse every section `.liquid` file in the Impact theme's `/sections/` directory. For each section, extract its `{% schema %}` JSON block.

Run:

```bash
python3 scripts/build-schema-index.py /tmp/impact-theme > $ASSET_DIR/impact-schema-index.json
```

This produces a lookup table:

```
section_filename → {
 name: "Section Display Name",
 settings: [ { id, type, default, options, label } ],
 blocks: [ { type, name, settings: [...], limit } ],
 presets: [ { name, category } ],
 max_blocks: N,
 class: "..."
}
```

**You MUST consult this index before deciding how to build each section in Phase 6.** If you skip this step, you will default to custom HTML and the clone will break.

### Phase 5: Verify Pipeline Output

Before touching the homepage, verify the pipeline ran correctly:

- `GET /products/count.json` — matches source count (after utility filter)
- `GET /products.json` — spot-check 3-5 product prices against source
- `GET /custom_collections/count.json` — matches source collection count
- All products published to Online Store (visit `/collections/all` in browser)

**Price verification is critical.** The pipeline often creates products at `0.00`. If prices are wrong, fix via `PUT /products/{id}.json` before proceeding.

-----

### Phase 6: Rebuild Homepage (~20-30 min)

This is the most critical phase and the biggest source of visual bugs. Follow this sequence exactly.

#### 6-pre. Configure Global Settings FIRST ⚠️ BEFORE any section work

Impact sections reference **numbered color schemes** (Scheme 1, Scheme 2, … Scheme 6) and **global typography settings**. If you build sections before configuring these, every section's `color_scheme` setting will reference the wrong palette.

**Step 1: Build color schemes from source data**

Load `extracted-settings.json` (from `extract-settings.sh`) and `global-css-vars.json` (from browser audit). These are more accurate than the hex scrape in `clone-pipeline.sh`.

Map source colors to Impact's scheme structure:

```json
{
 "current": {
 "colors_solid_button_labels": "#ffffff",
 "colors_accent_1": "{source accent color}",
 "colors_accent_2": "{source secondary accent}",
 "colors_text": "{source text color}",
 "colors_outline_button_labels": "{source text color}",
 "colors_background_1": "{source background}",
 "colors_background_2": "{source secondary bg}",
 "type_header_font_family": "{source heading font}",
 "type_body_font_family": "{source body font}",
 "type_header_font_size": "{source heading size scale}",
 "type_body_font_size": "{source body font size}",
 "header_background": "{source header bg}",
 "header_text_color": "{source header text}",
 "footer_background": "{source footer bg}",
 "footer_text_color": "{source footer text}",
 "primary_button_background": "{source CTA color}",
 "primary_button_text_color": "#ffffff"
 }
}
```

**Step 2: Upload settings_data.json**

```bash
bash scripts/upload-theme-assets.sh $SHOP $TOKEN $THEME_ID config/settings_data.json /tmp/settings_data.json
```

**Step 3: Verify** — open the storefront in browser. The header, footer, and any default sections should already show the correct color palette and fonts.

#### 6a. Load Audit Data

- Load `css-audit-homepage.json` → identify height=0 sections, CSS var values, section dimensions
- Load `impact-schema-index.json` → know what every Impact section can do
- Load `$SCRAPE_DIR/section-ids.txt` → source section order

#### 6b. Section Classification ⚠️ CRITICAL STEP — do NOT skip

For EVERY section on the source homepage, produce a `section-mapping.json` decision document BEFORE writing any code:

```json
[
 {
 "source_id": "shopify-section-template--12345__slideshow",
 "source_type_detected": "slideshow",
 "tier": 1,
 "impact_section": "slideshow",
 "confidence": "95%",
 "reason": "Impact slideshow supports multiple slides with overlay text, CTA buttons, and image settings",
 "blocks_needed": [
 { "type": "slide", "count": 3 }
 ],
 "settings_gap": "Overlay gradient angle not available in schema — needs 1 CSS override",
 "css_override_needed": true
 },
 {
 "source_id": "shopify-section-template--12345__custom_widget",
 "source_type_detected": "unknown",
 "tier": 2,
 "impact_section": null,
 "confidence": "N/A",
 "reason": "Custom animated countdown timer with no Impact equivalent",
 "blocks_needed": [],
 "settings_gap": "Entire section is custom",
 "css_override_needed": true
 }
]
```

Save as `runs/{domain}-assets/section-mapping.json`. Review this before proceeding.

**TIER 1 — Native Impact Section (ALWAYS prefer this)**

Map the source section to the closest Impact theme section and configure it via JSON settings. Common mappings:

|Source Section Type |Impact Section |Key Settings to Check |
|----------------------------------|----------------------------|-----------------------------------------------------|
|Hero / Slideshow |`slideshow` |Slide count, overlay opacity, text position, autoplay|
|Featured Collection / Product Grid|`featured-collection` |Columns, card style, image_ratio, show_vendor |
|Rich Text / Text Block |`rich-text` |max_width, alignment, content blocks |
|Image + Text Side-by-Side |`image-with-text` |Image position (left/right), image_ratio, layout |
|Logo List / Trust Badges |`logo-list` |item_max_size, items_per_row, logo images as blocks |
|Testimonials / Reviews |`testimonials` |Layout (carousel vs grid), items_per_row |
|Multi-Column / Features |`multi-column` |Column count, icon style, columns as blocks |
|FAQ / Collapsible Content |`collapsible-content` |Open/closed default, icon style |
|Newsletter Signup |`newsletter` |Layout, placeholder text, background |
|Video Section |`video` |Autoplay, cover image, video_url |
|Collection List |`collection-list` |Grid, image_ratio, collection blocks |
|Image Banner |`image-banner` |Height, text position, overlay opacity |
|Scrolling Images / Marquee |`images-with-text-scrolling`|Image count, speed, image ratio |
|Before/After |`before-after` |Images, initial position |

For each Tier 1 mapping:

1. Open the Impact section's .liquid file from `/tmp/impact-theme/sections/`
1. Read the full `{% schema %}` block (or look it up in `impact-schema-index.json`)
1. List every available setting with its type, id, default, and valid options
1. **List every available block type** with its settings and limits
1. Map source visual properties (from css-audit) to schema settings
1. Generate the JSON block with EXACT values
1. **Configure blocks** (slides, columns, items, etc.) — most Impact sections use blocks for their repeating content

**CRITICAL — Blocks:** Most Impact sections use **blocks** for repeating content items. A slideshow needs slide blocks. Multi-column needs column blocks. Logo-list needs logo blocks. **You must create the correct number of blocks with per-block settings, not just section-level settings.** Example:

```json
{
 "type": "slideshow",
 "settings": {
 "autoplay": true,
 "autoplay_speed": 5,
 "image_ratio": "adapt",
 "color_scheme": "scheme-1"
 },
 "blocks": {
 "slide_1": {
 "type": "slide",
 "settings": {
 "image": "shopify://shop_images/hero-1.jpg",
 "heading": "Source Heading Text",
 "subheading": "Source subheading",
 "button_text": "Shop Now",
 "button_url": "/collections/all",
 "text_position": "center"
 }
 },
 "slide_2": {
 "type": "slide",
 "settings": { ... }
 }
 },
 "block_order": ["slide_1", "slide_2"]
}
```

**Image Ratio Setting:** Impact has specific image ratio options in many sections: `"adapt"`, `"square"`, `"portrait"`, `"landscape"`, `"16-9"`, etc. Check the source image dimensions from `css-audit` and select the closest match. Wrong image ratios cause cropping/stretching — one of the most common visual mismatches.

**RULE: For Tier 1 sections, you are FORBIDDEN from writing custom HTML. Achieve the look exclusively through Impact's section schema settings + blocks. If the match is 85%+ through settings alone, it IS Tier 1. Add a scoped CSS snippet ONLY for the remaining visual gap.**

**TIER 2 — Custom Section (last resort only)**

Use ONLY when there is genuinely no Impact section that can achieve even 85% of the look. Examples: custom app widgets, highly bespoke animated layouts, unique interactive components.

**Tier 2 Implementation — use custom .liquid section files, NOT `custom-html`:**

Do NOT use the generic `custom-html` section type and inject raw HTML. Instead:

1. Create a **custom .liquid section file** (e.g., `sections/clone-{section-name}.liquid`)
1. Place ALL CSS (including @media queries and @keyframes) in a **separate asset file** (`assets/clone-section-{name}.css`)
1. Load the CSS in the section via: `{{ 'clone-section-{name}.css' | asset_url | stylesheet_tag }}`
1. Include a `{% schema %}` block with at least a name and basic settings so it can be edited in admin
1. Wrap all content in a scoped container with a unique class
1. Push the custom section files with `shopify theme push`
1. Reference the custom section in `templates/index.json` like any other section

This approach:

- Preserves ALL responsive CSS (@media queries work normally)
- Preserves ALL animations (@keyframes work normally)
- Avoids Shopify's Liquid validator false positives on nested `{}`
- Keeps styles isolated from Impact's own CSS

#### Tier 2 HTML Extraction Rules (for custom .liquid sections ONLY):

When extracting HTML from source to use in a Tier 2 custom section:

1. Strip `<script>` tags and `<!-- comments -->` only
1. Move ALL `<style>` content into the external CSS asset file — do NOT inline it
1. In the external CSS file, prefix every rule with the section's scoping class
1. DO NOT strip `srcset` — needed for responsive images
1. For sections with height=0 in audit: set `display:none` in the external CSS
1. For oversized sections: apply CSS grid/flex constraints based on audit values
1. DO NOT use `shopify://shop_images/` refs in custom sections — use direct CDN URLs after re-hosting (Phase 6.5)
1. Scan for nested braces that might trigger Liquid validator: `re.findall(r'\{[^}]{0,30}\{', html)`

#### 6c. Build index.json

Assemble `templates/index.json` with all sections in the correct order:

- Tier 1 sections: fully configured via their schema settings and blocks
- Tier 2 sections: reference the custom .liquid section files
- **Section order in the `"order"` array MUST match the source homepage section order exactly** — verify against `$SCRAPE_DIR/section-ids.txt`

You can use `build-homepage.py` as a starting point for the JSON structure, but **you must replace its `custom-html` entries** with proper Tier 1 configurations for every section you classified as Tier 1.

Upload:

```bash
bash scripts/upload-theme-assets.sh $SHOP $TOKEN $THEME_ID templates/index.json /tmp/index.json
```

#### 6d. Configure Header & Footer Groups

Map header/footer from source to Impact's group sections:

**Header (`sections/header-group.json`):**

- Logo: use `shopify://shop_images/{filename}` format — NOT a GID, NOT a CDN URL
- Logo width (check source rendering size from css-audit)
- Announcement bar: text, background color, text color, scrolling behavior
 - Impact supports multi-message announcement bars via blocks — configure if source has multiple messages
- Nav items: configured separately via menus (Phase 8), but header layout settings matter
- Sticky header: check if source header is sticky

**Footer (`sections/footer-group.json`):**

- Footer columns and links
- Newsletter signup
- Social links (from `extract-settings.sh` output)
- Copyright text

Upload both:

```bash
bash scripts/upload-theme-assets.sh $SHOP $TOKEN $THEME_ID sections/header-group.json /tmp/header-group.json
bash scripts/upload-theme-assets.sh $SHOP $TOKEN $THEME_ID sections/footer-group.json /tmp/footer-group.json
```

### Phase 6.5: Re-host All Source CDN Assets (CRITICAL)

After rebuilding the homepage, ALL references to the source store's CDN must be replaced. If skipped, the clone breaks if the source changes or deletes assets.

#### 6.5a. Upload all assets to clone's Files API

```graphql
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

Find ALL source store references (three formats):

1. `https://source-store.com/cdn/shop/files/...`
1. `https://cdn.shopify.com/s/files/1/{SOURCE_STORE_ID}/files/...`
1. `//source-store.com/cdn/...` (protocol-relative)

#### 6.5c. Replace in ALL theme assets

Templates to check: `templates/index.json`, `templates/product.json`, `config/settings_data.json`, `sections/header-group.json`, `sections/footer-group.json`, plus any Tier 2 custom section files and their CSS assets.

**Important:** URLs in theme JSON are escaped with `\\/` — replacements must match this exact format.

Also replace source store email addresses in footer/contact content.

#### 6.5d. Verify zero source refs remaining

```bash
for template in templates/index.json templates/product.json config/settings_data.json sections/header-group.json sections/footer-group.json; do
 curl -s "https://$SHOP/admin/api/2024-01/themes/$THEME_ID/assets.json?asset%5Bkey%5D=$template" \
 -H "X-Shopify-Access-Token: $TOKEN" | grep -c "source-domain\|SOURCE_STORE_ID"
done
```

### Phase 6.5b: Scoped CSS Overrides (Tier 1 polish)

For Tier 1 sections where JSON settings got you 85-95% there, write targeted CSS fixes:

1. Create `assets/clone-overrides.css`
1. **Load it in the theme:** Add `{{ 'clone-overrides.css' | asset_url | stylesheet_tag }}` to `layout/theme.liquid` just before `</head>`, or add it as a custom snippet
1. Every rule MUST be scoped using the section's ID: `#shopify-section-{id} .specific-element { ... }`
1. Use EXACT values from css-audit: hex colors, px/rem spacing, font stacks
1. **NEVER approximate** — if the source has `padding: 48px`, write `48px`, not `50px` or `3rem`
1. **NEVER write global CSS** that could bleed into other sections

Upload:

```bash
bash scripts/upload-theme-assets.sh $SHOP $TOKEN $THEME_ID assets/clone-overrides.css /tmp/clone-overrides.css
```

Then inject the stylesheet tag into theme.liquid:

```bash
# Fetch current theme.liquid
curl -s "https://$SHOP/admin/api/2024-01/themes/$THEME_ID/assets.json?asset%5Bkey%5D=layout/theme.liquid" \
 -H "X-Shopify-Access-Token: $TOKEN" | jq -r '.asset.value' > /tmp/theme.liquid

# Add stylesheet before </head>
sed -i 's|</head>|{{ "clone-overrides.css" | asset_url | stylesheet_tag }}\n</head>|' /tmp/theme.liquid

# Upload modified theme.liquid
bash scripts/upload-theme-assets.sh $SHOP $TOKEN $THEME_ID layout/theme.liquid /tmp/theme.liquid
```

-----

### Phase 7: Product Page Template (~10 min)

Apply the same Tier 1/Tier 2 approach to the product page:

1. Check `css-audit-product.json` for the source product page layout
1. Consult `impact-schema-index.json` for Impact's product section schema
1. Configure `templates/product.json` using Impact's native product blocks (description, add-to-cart, reviews, specs, trust badges, collapsible tabs, etc.)
1. Only create custom blocks for elements Impact can't handle natively
1. Upload via Asset API

-----

### Phase 8: Menus & Navigation (~5 min)

Verify pipeline-created menus match source. Fix via Admin API if needed:

- Main menu items + URLs (must resolve to existing pages/collections on the clone)
- Footer menu items + URLs
- All links resolve correctly
- Mega menu / dropdown structure matches source depth

Use `menuUpdate` GraphQL mutation to fix discrepancies.

-----

### Phase 9: Verify & Log (~5 min)

⛔ **HARD GATE — do NOT declare done until this checklist is fully green.**
Verify via actual storefront URL, not admin. Open the store in a browser before sending any "done" message.

- [ ] Products visible on storefront `/collections/all` (not just admin — visit the URL!)
- [ ] Product counts match source store (`GET /products/count.json` vs source)
- [ ] Product prices correct (not £0.00 for paid items) — check ALL variants, not just variant 1
- [ ] Product handles match source
- [ ] Homepage sections render in correct order
- [ ] Header: logo, navigation, announcement bar all match source
- [ ] Footer: columns, links, newsletter, social links match source
- [ ] Navigation links work (click through main menu + footer)
- [ ] Footer pages accessible (privacy, terms, shipping, refund)
- [ ] Markets created and enabled (if source has UK/EU markets)
- [ ] Mobile layout works (resize browser to 375px, check each section)
- [ ] Cart drawer works (add a product, verify drawer opens)
- [ ] Currency symbol displays correctly throughout
- [ ] No source store CDN references remaining (Phase 6.5d check)

Update run file with final status and any remaining TODOs.

-----

### Phase 9.5: Side-by-Side Screenshot Comparison ⛔ REQUIRED EXIT GATE

Take full-page screenshots of BOTH source and clone at **three breakpoints: 1440px, 768px, and 375px**.

Use the visual-diff checklist (`scripts/visual-diff.sh`) as a starting point, then compare screenshots with an image model prompt:

```
Compare these two Shopify store homepages side by side in detail.
Left = original. Right = clone.
For each section top-to-bottom, list every visual difference:
header/logo, nav items, announcement bar, hero section, each content section,
colors, fonts, spacing, images, footer. Be specific about what's different.
```

**Fail criteria (any one = fail):**

- **Color**: any visible color difference (wrong hex, wrong opacity, wrong gradient)
- **Spacing**: any padding/margin difference >8px
- **Typography**: wrong font family, wrong weight, or size difference >2px
- **Layout**: elements in wrong position, wrong column count, wrong alignment
- **Images**: missing image, wrong aspect ratio, wrong crop, placeholder showing
- **Visibility**: section visible when it should be hidden, or vice versa
- **Content**: missing text, wrong text, missing CTA buttons

For each failure:

1. Log: section name, breakpoint, what's wrong, expected vs actual value
1. Fix using the appropriate method:
- Color/font issues → update `config/settings_data.json`
- Section layout → update section settings in `templates/index.json`
- Minor spacing/style → add rule to `assets/clone-overrides.css`
- Logo → update `sections/header-group.json` with `shopify://shop_images/{filename}`
- Nav → `menuUpdate` GraphQL mutation
- Announcement bar → update `sections/header-group.json`
1. After fixing, push changes: `shopify theme push --store $SHOP --password $TOKEN --theme $THEME_ID --path /tmp/impact-theme --allow-live`
1. Wait for CDN cache (up to 5 min) or verify via `server-timing` header
1. Re-screenshot and re-compare that section

**DO NOT send "done" until every section passes at all three breakpoints.**

-----

## Known Issues & Workarounds

|Issue |Workaround |
|-------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`@media` CSS in `<style>` blocks → Shopify Liquid validator rejects|Use Tier 2 approach: external CSS asset file, not inline styles |
|`@keyframes` CSS → Liquid validator false positive on nested `{}` |Move to external CSS asset file |
|App-injected widgets (Loox reviews, Google badge, etc.) |Cannot be cloned — requires active app subscriptions. Document in run log which widgets are missing. |
|Shopify CDN cache (stale HTML after push) |Push via CLI with `--allow-live` to force recompile. Verify via `server-timing` header. |
|Dev store storefront password |CANNOT be removed — Shopify enforces it. Only option: upgrade to paid plan. |
|`shopify://shop_images/` refs don't work in custom-html sections |Use direct CDN URLs after re-hosting (Phase 6.5) |
|Source uses a non-Impact section with no equivalent |Create a Tier 2 custom .liquid section — never force-fit into a wrong Impact section |
|Impact section settings don't cover a specific visual property |Add a scoped CSS override in clone-overrides.css — don't switch to Tier 2 for minor gaps |
|`stagedUploadsCreate` denied for SHOP_IMAGE |Upload branding manually in admin |
|Shipping/tax-inclusive pricing not in API |Configure manually in admin |
|`shopUpdate` mutation removed |Use REST `PUT /shop.json` (406 on some fields — unavoidable) |
|Theme zip upload → "locked" role |Use `shopify theme push` CLI instead — always |
|GitHub archive zips nest files in folder |Repackage flat before upload |
|Store currency (USD→GBP) via API |`PUT /shop.json` returns 406. Workaround: patch `snippets/js-variables.liquid` to hardcode `moneyFormat` (clone-pipeline.sh does this automatically). Delete extra markets to minimize header currency selector.|
|Logo in Impact header-group.json |Use `shopify://shop_images/{filename}` format — NOT a GID, NOT a CDN URL |
|`brandingUpdate` mutation |Does not exist on custom apps. Set logo via `shopify://shop_images/` in header-group.json instead. |
|`marketSetPrimary` mutation |Does not exist. Change primary market via Shopify Admin UI |
|Metafields on source products |Product metafields are not scraped by default. If source uses metafields for product data (specs, custom badges, dynamic section content), these must be recreated manually via `metafieldsSet` mutation. |
|`build-homepage.py` wraps everything in custom-html |Override its output — replace custom-html entries with Tier 1 native section configs based on your section-mapping.json |
|`clone-pipeline.sh` color extraction is approximate |Refine using `extract-settings.sh` output in Phase 6-pre |

-----

## Priority Hierarchy for Visual Matching

When cloning, match properties in this order of importance:

1. **Layout structure** — correct grid, correct section order, correct column count
1. **Typography** — exact font family, size, weight, line-height, letter-spacing
1. **Colors** — exact hex codes, gradients, overlays, background colors
1. **Spacing** — exact padding, margin, gap values
1. **Images** — correct images, correct aspect ratios, no placeholders
1. **Borders, shadows, decorative elements** — border-radius, box-shadow, dividers
1. **Animations and hover states** — transitions, transforms, @keyframes
1. **Responsive behavior** — verify all three breakpoints independently

-----

## Anti-Patterns — DO NOT Do These

- **DO NOT** default to `custom-html` sections. Always check Impact native sections first via `impact-schema-index.json`.
- **DO NOT** run `build-homepage.py` and accept its output without overriding custom-html entries with Tier 1 configurations.
- **DO NOT** configure section JSON before setting up global `settings_data.json` — color schemes must exist before sections reference them.
- **DO NOT** forget blocks. Most Impact sections need blocks (slides, columns, logos, etc.) not just section-level settings.
- **DO NOT** use placeholder text or images. Use exact content from the source store.
- **DO NOT** hardcode section content in Liquid templates. Use schema settings so the store owner can edit via Shopify admin.
- **DO NOT** ignore mobile layout. Many sections render completely differently at 375px.
- **DO NOT** remove or rename Impact theme sections/snippets you're not modifying.
- **DO NOT** approximate values. If the source has `padding: 48px`, use `48px`, not `50px` or `3rem`.
- **DO NOT** write global CSS that could bleed into other sections.
- **DO NOT** skip the Impact Schema Index step — without it you'll miss available settings and blocks.
- **DO NOT** inline complex CSS into custom-html sections — use external asset files via custom .liquid sections.
- **DO NOT** skip any breakpoint during QA — desktop-only testing hides 50% of bugs.
- **DO NOT** forget to load `clone-overrides.css` in `theme.liquid` — the file does nothing if it's not linked.
- **DO NOT** skip `extract-settings.sh` — its output is more accurate than the hex scrape in `clone-pipeline.sh`.

-----

## Timing Targets

|Phase |Target |Notes |
|--------------------------|--------------|-----------------------------------------------------|
|Scrape + audit |5 min |scrape-store.sh + browser audit + extract-settings.sh|
|Assets |2 min |Automated |
|Dev store + app |5 min |Browser |
|Theme install + pipeline |7 min |clone-pipeline.sh |
|Schema index |1 min |build-schema-index.py |
|Global settings (6-pre) |5 min |settings_data.json from extracted data |
|Section classification |5 min |section-mapping.json |
|Homepage sections (Tier 1)|15-20 min |Biggest variable — depends on section count |
|Homepage sections (Tier 2)|10-15 min |Per custom section |
|Header/footer groups |5 min | |
|CDN re-hosting |5 min | |
|CSS overrides |5 min | |
|Product page |10 min |If customized |
|Menus/nav |5 min |Verify + fix |
|Verify + visual diff |10 min |Three breakpoints |
|**Total** |**~75-90 min**|With native sections approach |

## Run Log Location

`~/clawd/projects/store-factory/runs/YYYY-MM-DD-{domain}.md`

## References

- `references/run-template.md` — Template for run log files
- Playbooks at `~/clawd/projects/store-factory/playbooks/`
- Project memory at `~/clawd/projects/store-factory/MEMORY.md`
