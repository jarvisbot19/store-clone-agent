#!/usr/bin/env bash
# Extract theme settings (colors, fonts, header/footer config) from a Shopify store
# Usage: ./extract-settings.sh <store-domain>
# Example: ./extract-settings.sh getvision4k.com
#
# Output: JSON with extracted theme settings

set -euo pipefail

DOMAIN="${1:?Usage: extract-settings.sh <store-domain>}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

echo "🎨 Extracting theme settings from https://${DOMAIN}..." >&2

# Fetch full homepage HTML
HTML=$(curl -sL "https://${DOMAIN}")

python3 << 'PYEOF'
import re, json, sys

html = """HTMLPLACEHOLDER"""

result = {
    "domain": "DOMAINPLACEHOLDER",
    "colors": {},
    "fonts": {},
    "header": {},
    "footer": {},
    "announcement": {},
    "meta": {}
}

# ─── Colors from CSS variables ─────────────────────────────────────
css_vars = re.findall(r'--([\w-]+)\s*:\s*([^;]+)', html)
color_vars = {}
for name, value in css_vars:
    value = value.strip()
    if re.match(r'^#[0-9a-fA-F]{3,8}$', value) or value.startswith('rgb') or value.startswith('hsl'):
        color_vars[name] = value

# Common Shopify theme color variable patterns
color_mappings = {
    'primary': ['--primary', '--color-primary', '--color-accent', '--accent'],
    'secondary': ['--secondary', '--color-secondary'],
    'background': ['--background', '--color-background', '--bg', '--color-bg'],
    'text': ['--text', '--color-text', '--foreground', '--color-foreground'],
    'heading': ['--heading', '--color-heading'],
    'button': ['--button', '--color-button', '--color-button-bg', '--btn-bg'],
    'button_text': ['--button-text', '--color-button-text', '--btn-text'],
}

for key, patterns in color_mappings.items():
    for pattern in patterns:
        clean = pattern.lstrip('-')
        if clean in color_vars:
            result["colors"][key] = color_vars[clean]
            break

# Also grab any prominent hex colors from inline styles
inline_colors = re.findall(r'(?:background-color|color|border-color)\s*:\s*(#[0-9a-fA-F]{3,8})', html)
if inline_colors:
    from collections import Counter
    common = Counter(inline_colors).most_common(5)
    result["colors"]["prominent_inline"] = [{"color": c, "count": n} for c, n in common]

# ─── Fonts ──────────────────────────────────────────────────────────
# From CSS font-family declarations
font_families = re.findall(r'font-family\s*:\s*["\']?([^;"\']+)', html)
if font_families:
    from collections import Counter
    common_fonts = Counter(f.strip().split(',')[0].strip('"').strip("'") for f in font_families).most_common(3)
    result["fonts"]["detected"] = [{"font": f, "count": n} for f, n in common_fonts if f not in ('inherit', 'sans-serif', 'serif', 'monospace')]

# From Google Fonts links
gfonts = re.findall(r'fonts\.googleapis\.com/css2?\?family=([^&"]+)', html)
if gfonts:
    result["fonts"]["google_fonts"] = [f.replace('+', ' ').split(':')[0] for f in gfonts]

# From CSS variable
font_vars = {k: v for k, v in css_vars if 'font' in k.lower() and not re.match(r'^[\d.]+', v.strip())}
if font_vars:
    result["fonts"]["css_variables"] = {k: v.strip().strip('"').strip("'").split(',')[0] for k, v in font_vars.items()}

# ─── Meta ───────────────────────────────────────────────────────────
meta_title = re.search(r'<title>([^<]+)</title>', html)
if meta_title:
    result["meta"]["title"] = meta_title.group(1).strip()

meta_desc = re.search(r'<meta\s+name="description"\s+content="([^"]*)"', html)
if meta_desc:
    result["meta"]["description"] = meta_desc.group(1)

og_image = re.search(r'<meta\s+property="og:image"\s+content="([^"]*)"', html)
if og_image:
    result["meta"]["og_image"] = og_image.group(1)

# ─── Announcement bar ──────────────────────────────────────────────
announcement = re.search(r'class="[^"]*announcement[^"]*"[^>]*>(.*?)</div>', html, re.DOTALL | re.IGNORECASE)
if announcement:
    text = re.sub(r'<[^>]+>', ' ', announcement.group(1))
    text = re.sub(r'\s+', ' ', text).strip()
    if text:
        result["announcement"]["text"] = text[:500]

# ─── Social Links ──────────────────────────────────────────────────
social_patterns = {
    'facebook': r'facebook\.com/[^"\'>\s]+',
    'instagram': r'instagram\.com/[^"\'>\s]+',
    'twitter': r'(?:twitter|x)\.com/[^"\'>\s]+',
    'tiktok': r'tiktok\.com/@[^"\'>\s]+',
    'youtube': r'youtube\.com/[^"\'>\s]+',
    'pinterest': r'pinterest\.com/[^"\'>\s]+',
}
social = {}
for platform, pattern in social_patterns.items():
    match = re.search(pattern, html, re.IGNORECASE)
    if match:
        url = match.group(0)
        if not url.startswith('http'):
            url = 'https://' + url
        social[platform] = url
if social:
    result["meta"]["social_links"] = social

print(json.dumps(result, indent=2))
PYEOF
# The heredoc above contains placeholders — inject real values
python3 -c "
import json, re, sys
from collections import Counter

html = sys.stdin.read()
domain = '${DOMAIN}'

result = {
    'domain': domain,
    'colors': {},
    'fonts': {},
    'header': {},
    'footer': {},
    'announcement': {},
    'meta': {}
}

# Colors from CSS variables
css_vars = re.findall(r'--([\w-]+)\s*:\s*([^;]+)', html)
color_vars = {}
for name, value in css_vars:
    value = value.strip()
    if re.match(r'^#[0-9a-fA-F]{3,8}$', value) or value.startswith('rgb') or value.startswith('hsl'):
        color_vars[name] = value

if color_vars:
    result['colors']['css_variables'] = dict(list(color_vars.items())[:30])

# Prominent inline colors
inline_colors = re.findall(r'(?:background-color|color|border-color)\s*:\s*(#[0-9a-fA-F]{3,8})', html)
if inline_colors:
    common = Counter(inline_colors).most_common(10)
    result['colors']['prominent'] = [{'color': c, 'count': n} for c, n in common]

# Fonts
font_families = re.findall(r'font-family\s*:\s*[\"\\']?([^;\"\\']+)', html)
if font_families:
    common_fonts = Counter(f.strip().split(',')[0].strip('\"').strip(\"\\'\") for f in font_families).most_common(5)
    result['fonts']['detected'] = [{'font': f, 'count': n} for f, n in common_fonts if f not in ('inherit', 'sans-serif', 'serif', 'monospace', '')]

gfonts = re.findall(r'fonts\.googleapis\.com/css2?\?family=([^&\"]+)', html)
if gfonts:
    result['fonts']['google_fonts'] = [f.replace('+', ' ').split(':')[0] for f in gfonts]

font_css_vars = {k: v.strip().strip('\"').strip(\"\\'\").split(',')[0] for k, v in css_vars if 'font' in k.lower() and not re.match(r'^[\d.]', v.strip())}
if font_css_vars:
    result['fonts']['css_variables'] = font_css_vars

# Meta
meta_title = re.search(r'<title>([^<]+)</title>', html)
if meta_title:
    result['meta']['title'] = meta_title.group(1).strip()

meta_desc = re.search(r'<meta\s+name=\"description\"\s+content=\"([^\"]*)\"', html)
if meta_desc:
    result['meta']['description'] = meta_desc.group(1)

og_image = re.search(r'<meta\s+property=\"og:image\"\s+content=\"([^\"]*)\"', html)
if og_image:
    result['meta']['og_image'] = og_image.group(1)

# Social links
social_patterns = {
    'facebook': r'facebook\.com/[^\"\\'>\\s]+',
    'instagram': r'instagram\.com/[^\"\\'>\\s]+',
    'twitter': r'(?:twitter|x)\.com/[^\"\\'>\\s]+',
    'tiktok': r'tiktok\.com/@[^\"\\'>\\s]+',
    'youtube': r'youtube\.com/[^\"\\'>\\s]+',
    'pinterest': r'pinterest\.com/[^\"\\'>\\s]+',
}
social = {}
for platform, pattern in social_patterns.items():
    match = re.search(pattern, html, re.IGNORECASE)
    if match:
        url = match.group(0)
        if not url.startswith('http'):
            url = 'https://' + url
        social[platform] = url
if social:
    result['meta']['social_links'] = social

# Announcement bar text
ann = re.search(r'class=\"[^\"]*announcement[^\"]*\"[^>]*>(.*?)</(?:div|section)', html, re.DOTALL | re.IGNORECASE)
if ann:
    text = re.sub(r'<[^>]+>', ' ', ann.group(1))
    text = re.sub(r'\\s+', ' ', text).strip()
    if text:
        result['announcement']['text'] = text[:500]

print(json.dumps(result, indent=2))
" <<< "$HTML"
