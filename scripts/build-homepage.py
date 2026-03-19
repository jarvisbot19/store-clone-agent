#!/usr/bin/env python3
"""
Build a templates/index.json for a clone store from extracted source sections.

Usage:
    python3 build-homepage.py <sections-dir>
    python3 build-homepage.py <sections-dir> --schema-index impact-schema-index.json
    python3 build-homepage.py <sections-dir> --schema-index index.json --css-audit audit.json
    python3 build-homepage.py <sections-dir> --schema-index index.json \
        --css-audit audit.json --output templates/index.json --mapping-output section-mapping.json

Takes the output of extract-sections.sh (directory with .html files + manifest)
and generates a templates/index.json compatible with the Impact theme.

v2: When --schema-index is provided, classifies each section as:
  - Tier 1: native Impact section → skeleton JSON with placeholder settings
  - Tier 2: custom .liquid section → reference to a file the agent must create

The agent MUST review and complete all output:
  - Tier 1: fill in __FILL_FROM_SOURCE__ placeholders from css-audit + source content
  - Tier 2: create sections/clone-{key}.liquid + assets/clone-section-{key}.css

Fallback (no --schema-index): custom-html sections (old behavior, ⚠️ legacy)
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Section type detection signatures
# ---------------------------------------------------------------------------

SECTION_SIGNATURES = {
    'slideshow': {
        'html_patterns': [r'slideshow', r'slider', r'swiper', r'hero.*slide', r'slide.*hero'],
        'class_patterns': [r'slideshow', r'slider', r'hero'],
        'impact_section': 'slideshow',
    },
    'image-banner': {
        'html_patterns': [r'image-banner', r'image-with-text-overlay', r'content-over-media', r'image.*overlay'],
        'class_patterns': [r'image-banner', r'content-over-media'],
        'impact_section': 'image-with-text-overlay',
    },
    'featured-collection': {
        'html_patterns': [r'featured.*collection', r'collection.*grid', r'product-grid', r'product-card'],
        'class_patterns': [r'collection', r'product-grid'],
        'impact_section': 'featured-collection',
    },
    'collection-list': {
        'html_patterns': [r'collection-list', r'collections.*grid', r'collection.*card'],
        'class_patterns': [r'collection-list'],
        'impact_section': 'collection-list',
    },
    'featured-product': {
        'html_patterns': [r'featured.*product', r'product-form', r'add-to-cart', r'product-info'],
        'class_patterns': [r'featured-product', r'product-form'],
        'impact_section': 'featured-product',
    },
    'rich-text': {
        'html_patterns': [r'rich-text', r'text-section', r'text-block'],
        'class_patterns': [r'rich-text'],
        'impact_section': 'rich-text',
    },
    'image-with-text': {
        'html_patterns': [r'image-with-text', r'media-with-text', r'split.*content'],
        'class_patterns': [r'image-with-text', r'media-with-text'],
        'impact_section': 'image-with-text',
    },
    'multi-column': {
        'html_patterns': [r'multi-column', r'multicolumn', r'feature.*grid', r'icon.*grid', r'benefits'],
        'class_patterns': [r'multi-column', r'multicolumn'],
        'impact_section': 'multi-column',
    },
    'collapsible-content': {
        'html_patterns': [r'faq', r'accordion', r'collapsible', r'<details', r'expandable'],
        'class_patterns': [r'faq', r'accordion', r'collapsible'],
        'impact_section': 'accordion-content',  # Impact uses accordion-content, not collapsible-content
    },
    'testimonials': {
        'html_patterns': [r'testimonial', r'customer.*quote', r'social-proof'],
        'class_patterns': [r'testimonial', r'reviews'],
        'impact_section': 'testimonials',
    },
    'logo-list': {
        'html_patterns': [r'logo.*list', r'brand.*list', r'trust.*badge', r'as-seen', r'partner.*logo', r'scrolling.*logo', r'logo.*cloud'],
        'class_patterns': [r'logo-list', r'brand-list', r'logo.*cloud', r'ss_logo'],
        'impact_section': 'logo-list',
    },
    'newsletter': {
        'html_patterns': [r'newsletter', r'subscribe', r'email.*signup'],
        'class_patterns': [r'newsletter'],
        'impact_section': 'newsletter',
    },
    'video': {
        'html_patterns': [r'<video', r'video-section', r'youtube\.com', r'vimeo\.com'],
        'class_patterns': [r'video'],
        'impact_section': 'video',
    },
    'images-with-text-scrolling': {
        'html_patterns': [r'images-with-text-scrolling', r'images-scrolling', r'scrolling.*image', r'marquee'],
        'class_patterns': [r'scrolling', r'marquee', r'images-scrolling'],
        'impact_section': 'images-with-text-scrolling',
    },
    'before-after': {
        'html_patterns': [r'before.*after', r'comparison.*slider'],
        'class_patterns': [r'before-after'],
        'impact_section': 'before-after',
    },
}

SKIP_IDS = {'header', 'footer', 'announcement-bar', 'announcement_bar'}


# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

def detect_section_type(html: str, section_id: str) -> tuple:
    """Return (type_name, confidence) for the given section HTML and ID."""
    html_lower = html.lower()
    sid_lower = re.sub(r'template--\d+__', '', section_id.lower())

    best_type, best_score = 'unknown', 0.0

    for type_name, sig in SECTION_SIGNATURES.items():
        score = 0.0
        for pattern in sig['html_patterns']:
            if re.search(pattern, html_lower):
                score += 1.0
        for pattern in sig['class_patterns']:
            if re.search(pattern, html_lower):
                score += 0.5
        # Section ID is the most reliable signal
        for pattern in sig['class_patterns']:
            if re.search(pattern, sid_lower):
                score += 2.0
        if score > best_score:
            best_score = score
            best_type = type_name

    if best_score >= 1.0:
        return best_type, min(best_score / 4.0, 1.0)
    return 'unknown', 0.0


def is_skip_section(html: str, section_id: str) -> bool:
    """Return True if this section belongs in a section group (header/footer/announcement)."""
    sid_lower = section_id.lower()
    for skip in SKIP_IDS:
        if skip in sid_lower:
            return True
    html_lower = html.lower()
    if '<header' in html_lower and ('site-header' in html_lower or 'header-group' in html_lower):
        return True
    if '<footer' in html_lower and ('site-footer' in html_lower or 'footer-group' in html_lower):
        return True
    return False


def impact_section_exists(impact_section: str, schema_index: dict) -> bool:
    """Check if the Impact theme has this section type."""
    if not schema_index:
        return False
    sections = schema_index.get('sections', {})
    return impact_section in sections or impact_section.replace('-', '_') in sections


def get_impact_schema(impact_section: str, schema_index: dict) -> dict | None:
    """Get the schema entry for an Impact section."""
    if not schema_index:
        return None
    sections = schema_index.get('sections', {})
    return sections.get(impact_section) or sections.get(impact_section.replace('-', '_'))


# ---------------------------------------------------------------------------
# Section builders
# ---------------------------------------------------------------------------

def build_tier1_skeleton(impact_section: str, schema_index: dict, section_key: str) -> dict:
    """
    Build a Tier 1 section skeleton with placeholder settings.
    The agent MUST fill in actual values from css-audit + source content.
    Look for '__FILL_FROM_SOURCE__' markers.
    """
    schema = get_impact_schema(impact_section, schema_index)
    result = {
        'type': impact_section,
        'disabled': False,
        'settings': {},
        'blocks': {},
        'block_order': [],
        '_tier': 1,
        '_note': (
            f'TIER 1 — Fill settings from css-audit + source content. '
            f'DO NOT replace with custom-html.'
        ),
    }

    if schema:
        for setting in schema.get('settings', []):
            sid = setting.get('id', '')
            if not sid:
                continue
            if 'default' in setting:
                result['settings'][sid] = setting['default']
            else:
                result['settings'][sid] = f"__FILL_FROM_SOURCE__{setting.get('type', '')}"

        if schema.get('blocks'):
            result['_available_blocks'] = [
                {
                    'type': b['type'],
                    'name': b.get('name', ''),
                    'settings': [s.get('id', '') for s in b.get('settings', [])],
                }
                for b in schema['blocks']
            ]
            block_types = ', '.join(b['type'] for b in schema['blocks'])
            result['_note'] += f' | Available block types: {block_types}'
    else:
        result['_note'] += ' | ⚠️ Schema not found in index — verify section type exists'

    return result


def build_tier2_section(section_id: str, html: str, section_key: str) -> dict:
    """
    Build a Tier 2 custom section entry.
    The agent must create sections/clone-{key}.liquid + assets/clone-section-{key}.css
    """
    preview = re.sub(r'<[^>]+>', ' ', html)
    preview = re.sub(r'\s+', ' ', preview).strip()[:150]

    return {
        'type': f'clone-{section_key}',
        'disabled': False,
        'settings': {},
        '_tier': 2,
        '_note': (
            f'TIER 2 — Create sections/clone-{section_key}.liquid + '
            f'assets/clone-section-{section_key}.css'
        ),
        '_source_section_id': section_id,
        '_preview': preview,
        '_instructions': (
            '1. Create a custom .liquid section file (NOT custom-html)\n'
            '2. Move all CSS to an external asset file\n'
            '3. Include a {% schema %} block with at least a name\n'
            '4. Scope all CSS under a unique wrapper class\n'
            '5. Push via shopify theme push'
        ),
    }


def build_legacy_customhtml(section_id: str, html: str) -> dict:
    """
    Legacy fallback: custom-html section (no --schema-index provided).
    ⚠️ This approach has known issues with @media/@keyframes and Shopify's Liquid validator.
    Use Tier 2 custom .liquid sections for new work.
    """
    # Strip scripts and comments
    cleaned = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL)
    cleaned = re.sub(r'<!--.*?-->', '', cleaned, flags=re.DOTALL)
    # Strip @keyframes (triggers Liquid validator nested brace detection)
    cleaned = re.sub(r'@keyframes\s+\w+\s*\{(?:[^{}]*|\{[^{}]*\})*\}', '', cleaned, flags=re.DOTALL)
    # Strip @media rules from inline style blocks
    cleaned = re.sub(r'@media[^{]+\{(?:[^{}]*|\{[^{}]*\})*\}', '', cleaned, flags=re.DOTALL)
    # Strip outer shopify-section wrapper
    inner = re.sub(r'^<div[^>]*id="shopify-section-[^"]*"[^>]*>\s*', '', cleaned.strip())
    inner = re.sub(r'\s*</div>\s*$', '', inner)

    return {
        'type': 'custom-html',
        'disabled': False,
        'settings': {
            'html': inner if inner != cleaned.strip() else cleaned,
        },
        '_tier': 'legacy',
        '_note': (
            '⚠️ LEGACY custom-html fallback. '
            'Consider upgrading to a Tier 2 custom .liquid section.'
        ),
    }


# ---------------------------------------------------------------------------
# Manifest loader
# ---------------------------------------------------------------------------

def load_manifest(sections_dir: str) -> list:
    manifest_path = os.path.join(sections_dir, 'sections-manifest.json')
    if not os.path.exists(manifest_path):
        print(f"Error: No manifest found at {manifest_path}", file=sys.stderr)
        print("Run extract-sections.sh first.", file=sys.stderr)
        sys.exit(1)
    with open(manifest_path) as f:
        return json.load(f)


def load_section_html(sections_dir: str, filename: str) -> str:
    path = os.path.join(sections_dir, filename)
    if not os.path.exists(path):
        return ''
    with open(path) as f:
        return f.read()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Build homepage template from extracted sections (v2: Tier 1/Tier 2 support)'
    )
    parser.add_argument('sections_dir', help='Directory with extracted sections (from extract-sections.sh)')
    parser.add_argument('--schema-index', help='Path to impact-schema-index.json (enables Tier 1 classification)')
    parser.add_argument('--css-audit', help='Path to css-audit-homepage.json (visibility detection + layout hints)')
    parser.add_argument('--output', '-o', help='Output file (default: stdout)')
    parser.add_argument('--mapping-output', help='Output section-mapping.json decision log to this path')
    args = parser.parse_args()

    # Load inputs
    manifest = load_manifest(args.sections_dir)
    print(f"📋 Loaded {len(manifest)} sections from manifest", file=sys.stderr)

    schema_index = None
    if args.schema_index:
        with open(args.schema_index) as f:
            schema_index = json.load(f)
        count = schema_index.get('_meta', {}).get('sections_parsed', '?')
        print(f"📋 Loaded schema index ({count} Impact sections)", file=sys.stderr)

    css_audit = None
    if args.css_audit:
        with open(args.css_audit) as f:
            css_audit = json.load(f)
        print(f"📋 Loaded CSS audit ({len(css_audit)} sections)", file=sys.stderr)

    # Build index.json
    index = {'sections': {}, 'order': []}
    mapping_log = []
    section_counter = 0
    tier1_count = tier2_count = skipped_count = 0

    for entry in manifest:
        section_id = entry['id']
        html = load_section_html(args.sections_dir, entry['file'])

        # Skip header/footer/announcement — these go in section groups
        if is_skip_section(html, section_id):
            skipped_count += 1
            mapping_log.append({
                'source_id': section_id,
                'action': 'skipped',
                'reason': 'Header/footer/announcement — configure in section groups, not index.json',
            })
            continue

        section_counter += 1
        detected_type, confidence = detect_section_type(html, section_id)

        # Generate clean section key
        type_slug = detected_type.replace('-', '_')
        section_key = f"section_{section_counter:02d}_{type_slug}"

        # Check CSS audit visibility
        is_visible = True
        audit_height = None
        if css_audit:
            for audit_key, audit_data in css_audit.items():
                if section_id in audit_key:
                    is_visible = audit_data.get('visible', True)
                    audit_height = audit_data.get('height')
                    break

        if schema_index and detected_type != 'unknown':
            impact_section = SECTION_SIGNATURES.get(detected_type, {}).get('impact_section')

            if impact_section and impact_section_exists(impact_section, schema_index):
                # TIER 1: native Impact section
                section_entry = build_tier1_skeleton(impact_section, schema_index, section_key)
                if not is_visible:
                    section_entry['disabled'] = True
                    section_entry['_note'] += ' | Source section was hidden (height=0 in audit)'
                tier1_count += 1
                mapping_log.append({
                    'source_id': section_id,
                    'detected_type': detected_type,
                    'confidence': round(confidence, 2),
                    'tier': 1,
                    'impact_section': impact_section,
                    'section_key': section_key,
                    'visible': is_visible,
                    'source_height': audit_height,
                })
            else:
                # TIER 2: detected type but no Impact equivalent
                section_entry = build_tier2_section(section_id, html, section_key)
                tier2_count += 1
                mapping_log.append({
                    'source_id': section_id,
                    'detected_type': detected_type,
                    'confidence': round(confidence, 2),
                    'tier': 2,
                    'impact_section': None,
                    'reason': f"Impact has no '{impact_section}' section" if impact_section else 'Type unrecognized',
                    'section_key': section_key,
                    'visible': is_visible,
                })
        elif schema_index:
            # Unknown type, schema available — Tier 2
            section_entry = build_tier2_section(section_id, html, section_key)
            tier2_count += 1
            mapping_log.append({
                'source_id': section_id,
                'detected_type': 'unknown',
                'confidence': 0,
                'tier': 2,
                'impact_section': None,
                'reason': 'Could not identify section type from HTML patterns',
                'section_key': section_key,
                'visible': is_visible,
            })
        else:
            # No schema index — legacy custom-html
            section_entry = build_legacy_customhtml(section_id, html)
            tier2_count += 1
            mapping_log.append({
                'source_id': section_id,
                'detected_type': detected_type,
                'tier': 'legacy',
                'section_key': section_key,
            })

        index['sections'][section_key] = section_entry
        index['order'].append(section_key)

    # Outputs
    result = json.dumps(index, indent=2, ensure_ascii=False)

    if args.output:
        os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
        with open(args.output, 'w') as f:
            f.write(result)
        print(f"\n✅ Written to {args.output}", file=sys.stderr)
    else:
        print(result)

    if args.mapping_output:
        os.makedirs(os.path.dirname(args.mapping_output) or '.', exist_ok=True)
        with open(args.mapping_output, 'w') as f:
            json.dump(mapping_log, f, indent=2, ensure_ascii=False)
        print(f"📋 Mapping log written to {args.mapping_output}", file=sys.stderr)

    # Summary
    print(f"\n📊 Homepage build summary:", file=sys.stderr)
    print(f"   Total sections: {len(manifest)}", file=sys.stderr)
    print(f"   Skipped (header/footer): {skipped_count}", file=sys.stderr)
    print(f"   Tier 1 (native Impact): {tier1_count}", file=sys.stderr)
    print(f"   Tier 2 (custom section): {tier2_count}", file=sys.stderr)
    print(f"   Sections in index.json: {len(index['order'])}", file=sys.stderr)

    if tier1_count > 0:
        print(f"\n⚠️  Tier 1 sections have placeholder settings.", file=sys.stderr)
        print(f"   Fill in '__FILL_FROM_SOURCE__' values from css-audit + source content.", file=sys.stderr)
    if tier2_count > 0 and schema_index:
        print(f"\n⚠️  Tier 2 sections need custom .liquid files created.", file=sys.stderr)
        print(f"   See {args.mapping_output or 'section-mapping.json'} for details.", file=sys.stderr)


if __name__ == '__main__':
    main()
