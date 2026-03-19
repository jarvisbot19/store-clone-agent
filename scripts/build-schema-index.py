#!/usr/bin/env python3
"""
Build an Impact theme schema index from section .liquid files.

Usage:
    python3 build-schema-index.py <theme-path> [--output FILE] [--summary] [--mapping-guide]

Parses every .liquid file in <theme-path>/sections/, extracts the {% schema %}
JSON block, and produces a structured index of all available sections with their
settings, blocks, presets, and capabilities.

Output: JSON lookup table that tells the agent exactly what each Impact section
can do — which settings are available, what block types it supports, and what
presets exist. This is the critical input for Tier 1/Tier 2 classification.

Examples:
    python3 build-schema-index.py /tmp/impact-theme
    python3 build-schema-index.py /tmp/impact-theme --output runs/shop-assets/impact-schema-index.json
    python3 build-schema-index.py /tmp/impact-theme --summary        # grouped overview to stderr
    python3 build-schema-index.py /tmp/impact-theme --mapping-guide  # capability mapping guide
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# JSON extraction + lenient parsing
# ---------------------------------------------------------------------------

SCHEMA_RE = re.compile(
    r'\{%-?\s*schema\s*-?%\}(.*?)\{%-?\s*endschema\s*-?%\}',
    re.DOTALL
)


def extract_schema_json(liquid_content: str) -> dict | None:
    """Extract and parse the {% schema %} JSON block from a Liquid file."""
    match = SCHEMA_RE.search(liquid_content)
    if not match:
        return None
    schema_text = match.group(1).strip()
    try:
        return json.loads(schema_text)
    except json.JSONDecodeError:
        # Fix common issues: trailing commas, line comments
        cleaned = re.sub(r',\s*([}\]])', r'\1', schema_text)
        cleaned = re.sub(r'//[^\n]*', '', cleaned)
        try:
            return json.loads(cleaned)
        except json.JSONDecodeError:
            return None


# ---------------------------------------------------------------------------
# Label extraction (handles Shopify t: translation keys)
# ---------------------------------------------------------------------------

def _extract_label(label) -> str:
    """Extract a readable label from a Shopify translation reference or plain string."""
    if isinstance(label, str):
        if label.startswith('t:'):
            # e.g. "t:sections.slideshow.name" -> "Slideshow"
            parts = label.split('.')
            skip = {'t:', 'label', 'name', 'content', 'sections',
                    'blocks', 'settings', 'options', 'presets'}
            for candidate in reversed(parts):
                if candidate not in skip:
                    return candidate.replace('_', ' ').replace('-', ' ').title()
            return parts[-1]
        return label
    elif isinstance(label, dict):
        return label.get('en', str(label))
    return str(label)


# ---------------------------------------------------------------------------
# Setting + block normalisation
# ---------------------------------------------------------------------------

def summarize_setting(setting: dict) -> dict:
    """Return a clean setting dict, filtering out UI dividers."""
    result = {
        'id': setting.get('id', ''),
        'type': setting.get('type', ''),
        'label': _extract_label(setting.get('label', '')),
    }
    if 'default' in setting:
        result['default'] = setting['default']
    if setting.get('type') in ('select', 'radio') and 'options' in setting:
        result['options'] = [
            {'value': o.get('value', ''), 'label': _extract_label(o.get('label', ''))}
            for o in setting['options']
        ]
    if setting.get('type') == 'range':
        for k in ('min', 'max', 'step', 'unit'):
            if k in setting:
                result[k] = setting[k]
    if 'info' in setting:
        result['info'] = _extract_label(setting['info'])
    return result


def summarize_block(block: dict) -> dict:
    """Return a clean block dict."""
    block_type = block.get('type', '')
    result = {
        'type': block_type,
        'name': _extract_label(block.get('name', '')),
        'is_app_block': block_type == '@app',
    }
    if 'limit' in block:
        result['limit'] = block['limit']
    result['settings'] = [
        summarize_setting(s) for s in block.get('settings', [])
        if s.get('type') != 'header'
    ]
    return result


# ---------------------------------------------------------------------------
# Section category + capabilities
# ---------------------------------------------------------------------------

CATEGORY_KEYWORDS = {
    'hero':         ['hero', 'banner', 'slideshow', 'slider'],
    'text':         ['rich-text', 'rich_text', 'text', 'heading'],
    'media':        ['image', 'video', 'gallery', 'media'],
    'product':      ['product', 'featured-product'],
    'collection':   ['collection'],
    'testimonial':  ['testimonial', 'review', 'quote'],
    'faq':          ['faq', 'collapsible', 'accordion'],
    'newsletter':   ['newsletter', 'subscribe', 'email'],
    'logo':         ['logo', 'brand', 'trust'],
    'footer':       ['footer'],
    'header':       ['header', 'navigation', 'nav'],
    'announcement': ['announcement'],
    'custom':       ['custom', 'html', 'liquid'],
}


def detect_section_category(schema: dict, filename: str) -> str:
    """Guess the section category based on schema presets and filename."""
    # Check preset categories first
    for preset in schema.get('presets', []):
        cat = _extract_label(preset.get('category', '')).lower()
        if cat:
            return cat
    # Infer from filename
    name_lower = filename.replace('.liquid', '').lower()
    for category, keywords in CATEGORY_KEYWORDS.items():
        for kw in keywords:
            if kw in name_lower:
                return category
    return 'other'


def analyze_section_capabilities(schema: dict) -> list:
    """Return a list of capability tags based on settings and blocks."""
    caps = []
    settings = schema.get('settings', [])
    blocks = schema.get('blocks', [])
    setting_ids = {s.get('id', '') for s in settings}
    setting_types = {s.get('type', '') for s in settings}

    if any('color' in sid or 'scheme' in sid for sid in setting_ids):
        caps.append('color_scheme')
    if any('image' in sid for sid in setting_ids) or 'image_picker' in setting_types:
        caps.append('images')
    if any('video' in sid for sid in setting_ids) or 'video_url' in setting_types:
        caps.append('video')
    if any('heading' in sid or 'title' in sid for sid in setting_ids):
        caps.append('heading')
    if any('text' in sid or 'content' in sid or 'description' in sid for sid in setting_ids):
        caps.append('text_content')
    if any('button' in sid or 'cta' in sid or 'link' in sid for sid in setting_ids):
        caps.append('cta_button')
    if any('spacing' in sid or 'padding' in sid for sid in setting_ids):
        caps.append('spacing_control')
    if any('ratio' in sid for sid in setting_ids):
        caps.append('image_ratio')
    if any('columns' in sid or 'per_row' in sid or 'grid' in sid for sid in setting_ids):
        caps.append('grid_layout')
    if any('autoplay' in sid or 'speed' in sid for sid in setting_ids):
        caps.append('autoplay')
    if any('overlay' in sid or 'opacity' in sid for sid in setting_ids):
        caps.append('overlay')
    if blocks:
        caps.append('blocks')
    if len(blocks) > 1:
        caps.append('multi_block_types')
    return caps


# ---------------------------------------------------------------------------
# Main index builder
# ---------------------------------------------------------------------------

def build_index(theme_path: str) -> dict:
    sections_dir = os.path.join(theme_path, 'sections')
    if not os.path.isdir(sections_dir):
        raise FileNotFoundError(f"sections/ directory not found in {theme_path}")

    sections = {}
    errors = []

    for filepath in sorted(Path(sections_dir).glob('*.liquid')):
        filename = filepath.name
        key = filename[:-len('.liquid')]

        try:
            content = filepath.read_text(encoding='utf-8', errors='replace')
        except OSError as e:
            errors.append({'file': filename, 'error': str(e)})
            continue

        schema = extract_schema_json(content)
        if schema is None:
            continue  # No schema block — skip

        raw_settings = schema.get('settings', [])
        raw_blocks = schema.get('blocks', [])
        presets = schema.get('presets', [])

        # Real settings (filter header/paragraph dividers)
        real_settings = [s for s in raw_settings if s.get('type') not in ('header', 'paragraph')]
        # Divider group labels (for human reference)
        setting_groups = [
            _extract_label(s.get('content', s.get('label', '')))
            for s in raw_settings
            if s.get('type') in ('header', 'paragraph')
        ]

        blocks = [summarize_block(b) for b in raw_blocks]
        has_app_blocks = any(b['is_app_block'] for b in blocks)

        entry = {
            'file': filename,
            'name': _extract_label(schema.get('name', key)),
            'tag': schema.get('tag', 'section'),
            'class': schema.get('class', ''),
            'category': detect_section_category(schema, filename),
            'capabilities': analyze_section_capabilities(schema),
            'has_app_blocks': has_app_blocks,
            'settings': [summarize_setting(s) for s in real_settings],
            'settings_count': len(real_settings),
            'setting_groups': setting_groups,
            'blocks': blocks,
            'block_types': [b['type'] for b in blocks],
            'presets': [
                {
                    'name': _extract_label(p.get('name', '')),
                    'category': _extract_label(p.get('category', '')),
                }
                for p in presets
            ],
        }

        if 'max_blocks' in schema:
            entry['max_blocks'] = schema['max_blocks']
        if 'disabled_on' in schema:
            entry['disabled_on'] = schema['disabled_on']
        if 'enabled_on' in schema:
            entry['enabled_on'] = schema['enabled_on']
        if 'limit' in schema:
            entry['limit'] = schema['limit']

        sections[key] = entry

    # Build section_names reverse map
    section_names = {v['name']: k for k, v in sections.items()}
    app_block_sections = [k for k, v in sections.items() if v['has_app_blocks']]
    no_preset_sections = [k for k, v in sections.items() if not v['presets']]

    return {
        '_meta': {
            'theme_path': os.path.abspath(theme_path),
            'sections_parsed': len(sections),
            'errors': len(errors),
            'section_names': section_names,
            'sections_with_app_blocks': app_block_sections,
            'sections_without_presets': no_preset_sections,
            'parse_errors': errors,
            'generated_by': 'build-schema-index.py',
        },
        'sections': sections,
    }


# ---------------------------------------------------------------------------
# Summary + mapping guide
# ---------------------------------------------------------------------------

def print_summary(index: dict) -> None:
    sections = index['sections']
    meta = index['_meta']
    print(f"\n📋 Impact Theme Schema Index", file=sys.stderr)
    print(f"   Sections parsed: {meta['sections_parsed']}", file=sys.stderr)
    if meta['errors']:
        print(f"   Parse errors: {meta['errors']}", file=sys.stderr)
    print('', file=sys.stderr)

    by_category = {}
    for key, section in sections.items():
        cat = section.get('category', 'other')
        by_category.setdefault(cat, []).append((key, section))

    for category in sorted(by_category.keys()):
        items = by_category[category]
        print(f"  [{category.upper()}]", file=sys.stderr)
        for key, section in items:
            block_info = ''
            if section['blocks']:
                btypes = ', '.join(section['block_types'][:4])
                if len(section['block_types']) > 4:
                    btypes += f" +{len(section['block_types']) - 4} more"
                block_info = f" | blocks: [{btypes}]"
                if 'max_blocks' in section:
                    block_info += f" (max {section['max_blocks']})"
            caps = ', '.join(section.get('capabilities', [])[:5])
            print(f"    {key}: {section['name']} ({section['settings_count']} settings{block_info})", file=sys.stderr)
            if caps:
                print(f"      capabilities: {caps}", file=sys.stderr)
        print('', file=sys.stderr)


def print_mapping_guide(index: dict) -> None:
    sections = index['sections']
    print('\n📌 QUICK MAPPING REFERENCE', file=sys.stderr)
    print('   Use this to decide which Impact section to use for each source section:\n', file=sys.stderr)

    # Build capability → sections map
    cap_map: dict[str, list] = {}
    for key, section in sections.items():
        for cap in section.get('capabilities', []):
            cap_map.setdefault(cap, []).append(key)

    common_needs = [
        ('Need a hero/banner with image + text overlay?', ['images', 'overlay', 'heading', 'cta_button']),
        ('Need a product grid/collection?', ['grid_layout', 'blocks']),
        ('Need text content with heading?', ['heading', 'text_content']),
        ('Need image + text side by side?', ['images', 'text_content']),
        ('Need repeating items (testimonials, features, etc)?', ['blocks', 'grid_layout']),
        ('Need video?', ['video']),
        ('Need autoplay carousel?', ['autoplay', 'blocks']),
    ]

    for question, required_caps in common_needs:
        candidates = set(sections.keys())
        for cap in required_caps:
            candidates &= set(cap_map.get(cap, []))
        if candidates:
            print(f"   {question}", file=sys.stderr)
            for c in sorted(candidates)[:5]:
                s = sections[c]
                print(f"     -> {c} ({s['name']}, {s['settings_count']} settings, {len(s['blocks'])} block types)", file=sys.stderr)
            print('', file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Build Impact theme schema index from section .liquid files'
    )
    parser.add_argument('theme_path', help='Path to the Impact theme directory (must contain sections/)')
    parser.add_argument('--output', '-o', help='Output file path (default: stdout)')
    parser.add_argument('--summary', '-s', action='store_true', help='Print human-readable summary to stderr')
    parser.add_argument('--mapping-guide', '-m', action='store_true', help='Print capability-based mapping guide to stderr')
    parser.add_argument('--compact', action='store_true', help='Compact JSON output (default: pretty)')
    args = parser.parse_args()

    if not os.path.isdir(args.theme_path):
        print(f"Error: {args.theme_path} is not a directory", file=sys.stderr)
        sys.exit(1)

    try:
        index = build_index(args.theme_path)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.summary or args.mapping_guide:
        print_summary(index)
    if args.mapping_guide:
        print_mapping_guide(index)

    indent = None if args.compact else 2
    output_json = json.dumps(index, indent=indent, ensure_ascii=False)

    if args.output:
        os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(output_json)
        meta = index['_meta']
        print(f"\n✅ Schema index written to {args.output}", file=sys.stderr)
        print(f"   {meta['sections_parsed']} sections indexed", file=sys.stderr)
        if meta['errors']:
            print(f"   ⚠️  {meta['errors']} files had parse errors", file=sys.stderr)
            for err in meta['parse_errors']:
                print(f"     {err['file']}: {err['error']}", file=sys.stderr)
    else:
        print(output_json)

    if not args.summary:
        print(f"\n📋 Indexed {index['_meta']['sections_parsed']} sections from {args.theme_path}", file=sys.stderr)


if __name__ == '__main__':
    main()
