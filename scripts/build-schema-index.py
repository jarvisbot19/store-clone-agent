#!/usr/bin/env python3
"""
build-schema-index.py — Parse Impact theme {% schema %} blocks into a lookup JSON.

Usage:
    python3 build-schema-index.py /path/to/impact-theme [--output index.json] [--pretty]

Output (stdout or --output file):
    {
      "slideshow": {
        "filename": "slideshow",
        "name": "Slideshow",
        "class": "shopify-section--slideshow",
        "tag": "section",
        "max_blocks": 5,
        "has_app_blocks": false,
        "settings": [
          { "id": "full_width", "type": "checkbox", "label": "Full width", "default": true, "options": null }
        ],
        "blocks": [
          { "type": "image", "name": "Image slide", "limit": null, "settings": [...] }
        ],
        "presets": ["Slideshow"],
        "disabled_on": { "groups": ["custom.overlay"] }
      },
      ...
      "_meta": {
        "total_sections": 64,
        "section_names": { "Slideshow": "slideshow", "Featured collection": "featured-collection", ... },
        "sections_with_app_blocks": ["apps", "featured-product", "main-product", ...],
        "sections_without_presets": ["cart-drawer", "search-drawer", ...],
        "generated_at": "2026-03-19T..."
      }
    }

Notes:
  - header-type settings are dividers, not configurable — they are excluded from settings[] but
    their label is preserved in setting_groups[] for context.
  - @app block types are included in blocks[] with has_app_blocks=true flagging the section.
  - Trailing-comma JSON errors in some files are handled with a lenient parser.
  - .json files (footer-group.json, header-group.json) are skipped — only .liquid files processed.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Lenient JSON parser: strips trailing commas before parsing
# ---------------------------------------------------------------------------

def _strip_trailing_commas(s: str) -> str:
    """Remove trailing commas before ] and } to fix common Shopify schema JSON issues."""
    # Remove trailing comma before }
    s = re.sub(r',\s*}', '}', s)
    # Remove trailing comma before ]
    s = re.sub(r',\s*]', ']', s)
    return s


def lenient_json_loads(s: str):
    """Parse JSON, retrying with trailing-comma strip on failure."""
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        try:
            return json.loads(_strip_trailing_commas(s))
        except json.JSONDecodeError as e:
            raise e


# ---------------------------------------------------------------------------
# Schema extraction
# ---------------------------------------------------------------------------

SCHEMA_RE = re.compile(
    r'\{%-?\s*schema\s*-?%\}(.*?)\{%-?\s*endschema\s*-?%\}',
    re.DOTALL
)


def extract_schema(liquid_content: str):
    """Return parsed schema dict from a .liquid file, or None if not found."""
    match = SCHEMA_RE.search(liquid_content)
    if not match:
        return None
    raw = match.group(1).strip()
    return lenient_json_loads(raw)


# ---------------------------------------------------------------------------
# Setting normalisation
# ---------------------------------------------------------------------------

REAL_SETTING_TYPES = {
    'text', 'textarea', 'image_picker', 'radio', 'select', 'checkbox',
    'number', 'range', 'color', 'color_background', 'font_picker',
    'collection', 'product', 'blog', 'page', 'link_list', 'url',
    'video', 'video_url', 'richtext', 'inline_richtext', 'html',
    'article', 'product_list', 'collection_list', 'metaobject',
    'metaobject_list', 'liquid',
}

DIVIDER_SETTING_TYPES = {'header', 'paragraph', 'paragraph_html'}


def normalise_setting(s: dict) -> dict | None:
    """Return a clean setting dict, or None if it is a layout divider."""
    setting_type = s.get('type', '')
    if setting_type in DIVIDER_SETTING_TYPES:
        return None  # visual divider, not a real setting
    return {
        'id': s.get('id'),
        'type': setting_type,
        'label': s.get('label', ''),
        'default': s.get('default'),
        'options': [
            {'value': o.get('value'), 'label': o.get('label')}
            for o in s.get('options', [])
        ] if s.get('options') else None,
        'info': s.get('info'),
    }


def normalise_block(b: dict) -> dict:
    """Return a clean block dict."""
    block_type = b.get('type', '')
    raw_settings = b.get('settings', [])
    settings = [ns for s in raw_settings if (ns := normalise_setting(s))]
    return {
        'type': block_type,
        'name': b.get('name', ''),
        'limit': b.get('limit'),
        'is_app_block': block_type == '@app',
        'settings': settings,
    }


# ---------------------------------------------------------------------------
# Main index builder
# ---------------------------------------------------------------------------

def build_index(theme_path: str) -> dict:
    sections_dir = os.path.join(theme_path, 'sections')
    if not os.path.isdir(sections_dir):
        raise FileNotFoundError(f"sections/ directory not found in {theme_path}")

    index = {}
    errors = []
    section_names_map = {}   # display name → filename key
    app_block_sections = []
    no_preset_sections = []

    liquid_files = sorted(
        f for f in os.listdir(sections_dir) if f.endswith('.liquid')
    )

    for fname in liquid_files:
        key = fname[:-len('.liquid')]  # strip .liquid
        filepath = os.path.join(sections_dir, fname)

        try:
            content = open(filepath, encoding='utf-8').read()
        except OSError as e:
            errors.append({'file': fname, 'error': str(e)})
            continue

        try:
            schema = extract_schema(content)
        except json.JSONDecodeError as e:
            errors.append({'file': fname, 'error': f'JSON parse error: {e}'})
            continue

        if schema is None:
            # No schema block (e.g. pure snippet sections) — skip
            continue

        name = schema.get('name', key)
        raw_settings = schema.get('settings', [])
        raw_blocks = schema.get('blocks', [])
        presets = [p.get('name', '') for p in schema.get('presets', [])]

        # Real settings only (filter out header/paragraph dividers)
        settings = [ns for s in raw_settings if (ns := normalise_setting(s))]

        # Setting group labels (from header-type dividers) for context
        setting_groups = [
            s.get('content', s.get('label', ''))
            for s in raw_settings
            if s.get('type') in DIVIDER_SETTING_TYPES
        ]

        # Blocks
        blocks = [normalise_block(b) for b in raw_blocks]
        has_app_blocks = any(b['is_app_block'] for b in blocks)

        # Build entry
        entry = {
            'filename': key,
            'name': name,
            'class': schema.get('class', ''),
            'tag': schema.get('tag', 'section'),
            'max_blocks': schema.get('max_blocks'),
            'has_app_blocks': has_app_blocks,
            'settings': settings,
            'setting_groups': setting_groups,
            'blocks': blocks,
            'presets': presets,
            'disabled_on': schema.get('disabled_on'),
        }

        index[key] = entry
        section_names_map[name] = key

        if has_app_blocks:
            app_block_sections.append(key)
        if not presets:
            no_preset_sections.append(key)

    # Meta
    index['_meta'] = {
        'total_sections': len(index) - 1,  # exclude _meta itself
        'section_names': section_names_map,
        'sections_with_app_blocks': app_block_sections,
        'sections_without_presets': no_preset_sections,
        'parse_errors': errors,
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'theme_path': os.path.abspath(theme_path),
    }

    return index


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Parse Impact theme {% schema %} blocks into a lookup JSON.'
    )
    parser.add_argument('theme_path', help='Path to the Impact theme directory')
    parser.add_argument(
        '--output', '-o',
        help='Output file path (default: stdout)',
        default=None
    )
    parser.add_argument(
        '--pretty', '-p',
        action='store_true',
        help='Pretty-print JSON output (default: compact)'
    )
    args = parser.parse_args()

    try:
        index = build_index(args.theme_path)
    except FileNotFoundError as e:
        print(f'Error: {e}', file=sys.stderr)
        sys.exit(1)

    indent = 2 if args.pretty else None
    output_json = json.dumps(index, indent=indent, ensure_ascii=False)

    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(output_json)
        meta = index['_meta']
        print(
            f"✅ Schema index written to {args.output}\n"
            f"   Sections indexed: {meta['total_sections']}\n"
            f"   Parse errors: {len(meta['parse_errors'])}\n"
            f"   Sections with @app blocks: {len(meta['sections_with_app_blocks'])}",
            file=sys.stderr
        )
        if meta['parse_errors']:
            for err in meta['parse_errors']:
                print(f"   ⚠️  {err['file']}: {err['error']}", file=sys.stderr)
    else:
        print(output_json)


if __name__ == '__main__':
    main()
