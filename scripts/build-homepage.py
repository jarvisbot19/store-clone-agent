#!/usr/bin/env python3
"""
Build a templates/index.json for a clone store from extracted source sections.

Usage: python3 build-homepage.py <sections-dir> [--theme impact]
  
Takes the output of extract-sections.sh (directory with .html files + manifest)
and generates a templates/index.json compatible with the target theme.

Currently supports: Impact theme (custom-html sections).
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path


def load_manifest(sections_dir: str) -> list:
    manifest_path = os.path.join(sections_dir, "sections-manifest.json")
    if not os.path.exists(manifest_path):
        print(f"Error: No manifest found at {manifest_path}", file=sys.stderr)
        print("Run extract-sections.sh first.", file=sys.stderr)
        sys.exit(1)
    
    with open(manifest_path) as f:
        return json.load(f)


def load_section_html(sections_dir: str, filename: str) -> str:
    path = os.path.join(sections_dir, filename)
    if not os.path.exists(path):
        return ""
    with open(path) as f:
        return f.read()


def extract_inner_html(full_html: str) -> str:
    """Extract the inner content from a Shopify section wrapper."""
    # Try to find the main content div inside the section
    patterns = [
        r'<div[^>]*class="[^"]*section[^"]*"[^>]*>(.*)</div>\s*$',
        r'<section[^>]*>(.*)</section>\s*$',
        r'id="shopify-section-[^"]*"[^>]*>(.*)</div>\s*$',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, full_html, re.DOTALL)
        if match:
            return match.group(1).strip()
    
    # Fallback: strip the outer shopify-section wrapper
    stripped = re.sub(
        r'^<div[^>]*id="shopify-section-[^"]*"[^>]*>\s*',
        '',
        full_html.strip()
    )
    stripped = re.sub(r'\s*</div>\s*$', '', stripped)
    return stripped if stripped != full_html.strip() else full_html


def build_impact_index(manifest: list, sections_dir: str) -> dict:
    """Build a templates/index.json for Impact theme."""
    
    index = {
        "name": "Homepage",
        "sections": {},
        "order": []
    }
    
    # Skip header/footer/announcement — these go in section groups, not index.json
    skip_types = {"header", "footer", "announcement-bar"}
    
    section_counter = 0
    for entry in manifest:
        section_type = entry.get("type", "unknown")
        
        if section_type in skip_types:
            continue
        
        section_id = entry["id"]
        html = load_section_html(sections_dir, entry["file"])
        inner_html = extract_inner_html(html)
        
        # Generate a clean section key
        section_counter += 1
        section_key = f"section_{section_counter:02d}_{section_type.replace('-', '_')}"
        
        if section_type == "featured-product":
            # Use Impact's native featured-product section
            # The agent will need to manually configure product ID and blocks
            index["sections"][section_key] = {
                "type": "featured-product",
                "disabled": False,
                "settings": {},
                "blocks": {},
                "block_order": [],
                "_note": "Configure product ID and blocks manually — see source HTML for block structure"
            }
        else:
            # Everything else becomes a custom-html section
            index["sections"][section_key] = {
                "type": "custom-html",
                "disabled": False,
                "settings": {
                    "html": inner_html
                }
            }
        
        index["order"].append(section_key)
    
    return index


def main():
    parser = argparse.ArgumentParser(description="Build homepage template from extracted sections")
    parser.add_argument("sections_dir", help="Directory with extracted sections (from extract-sections.sh)")
    parser.add_argument("--theme", default="impact", choices=["impact"], help="Target theme (default: impact)")
    parser.add_argument("--output", "-o", help="Output file (default: stdout)")
    parser.add_argument("--pretty", action="store_true", default=True, help="Pretty-print JSON")
    
    args = parser.parse_args()
    
    manifest = load_manifest(args.sections_dir)
    
    print(f"📋 Loaded {len(manifest)} sections from manifest", file=sys.stderr)
    
    if args.theme == "impact":
        index = build_impact_index(manifest, args.sections_dir)
    else:
        print(f"Unsupported theme: {args.theme}", file=sys.stderr)
        sys.exit(1)
    
    result = json.dumps(index, indent=2 if args.pretty else None, ensure_ascii=False)
    
    if args.output:
        with open(args.output, 'w') as f:
            f.write(result)
        print(f"✅ Written to {args.output}", file=sys.stderr)
    else:
        print(result)
    
    print(f"\n📊 Generated {len(index['order'])} sections:", file=sys.stderr)
    for key in index["order"]:
        section = index["sections"][key]
        stype = section.get("type", "?")
        size = len(json.dumps(section))
        print(f"  {key}: {stype} ({size} bytes)", file=sys.stderr)


if __name__ == "__main__":
    main()
