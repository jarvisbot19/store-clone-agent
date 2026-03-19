# Store Clone Agent

Agent-mode files for cloning live Shopify stores into development stores. Used by Jarvis (AI agent) to produce near-identical copies of any Shopify store.

## What it does

Takes a live Shopify store URL and produces a dev store with:
- All products, collections, pages, policies, navigation, markets
- Matching theme (Impact 6.4.1 from GitHub, or closest equivalent)
- Homepage sections ported as custom-html blocks
- All CDN assets re-hosted on the clone store

---

## Files

### `SKILL.md` — Master instruction file
The full workflow Jarvis follows for every clone. Covers all 9 phases, rules, known API gotchas, HTML extraction rules, and the mandatory visual diff gate. **This is the primary file.** If you want to change how cloning works, edit this file.

Key sections:
- **Phase 1g: CSS Design Audit** — browser JS to run on the source store before any theme work (extracts CSS vars, section heights, visibility)
- **HTML Extraction Rules** — how to safely port source section HTML without triggering Shopify's Liquid validator
- **Phase 9.5: Visual Diff** — mandatory screenshot comparison before declaring a clone done

---

### `scripts/` — Shell scripts and Python helpers

| Script | Phase | What it does |
|--------|-------|--------------|
| `scrape-store.sh` | 0+1+2 | HTTP scrape (products, collections, pages, policies), price verification, asset download, run log creation |
| `clone-pipeline.sh` | 4+5+6 | Theme install from GitHub, product/collection pipeline, color settings, currency patch |
| `extract-sections.sh` | 6a | Extracts all homepage section HTML via Shopify Section Rendering API |
| `extract-settings.sh` | 6d | Extracts colors, fonts, social links from source page CSS/meta |
| `extract-theme.sh` | 1d | Identifies exact source theme name + version from `Shopify.theme` |
| `download-assets.sh` | 2 | Downloads product images, branding, homepage media |
| `build-homepage.py` | 6c | Generates `templates/index.json` from extracted section HTML |
| `upload-theme-assets.sh` | 6c–6e | Uploads theme assets (templates, settings) via Shopify Asset API |
| `visual-diff.sh` | 9.5 | Side-by-side visual diff checklist between source and clone |

---

### `references/run-template.md` — Run log template
Template for the per-clone log file saved at `runs/YYYY-MM-DD-{domain}.md`. Documents scrape results, dev store credentials, steps completed, timing, and lessons learned.

---

## How a clone run works

```
SOURCE URL
    │
    ├── Track A (parallel): scrape-store.sh
    │     Scrapes products, collections, pages, assets
    │     Runs CSS Design Audit (Phase 1g) in browser
    │
    └── Track B (parallel): browser → Partner Dashboard
          Creates dev store + custom app → access token
    │
    └── clone-pipeline.sh {shop} {token} {source-url}
          Installs Impact from GitHub (jarvisbot19/impact-theme)
          Creates products, collections, pages, menus, markets
          Rebuilds homepage sections
    │
    └── Visual diff (Phase 9.5)
          Screenshots of both sites → image comparison
          Only "done" when hero + layout match
```

---

## Theme library

Impact and Shrine themes are stored on GitHub under `jarvisbot19/`:

| Repo | Theme | Version |
|------|-------|---------|
| `jarvisbot19/impact-theme` | Impact | 6.4.1 |
| `jarvisbot19/shrine_1-3-0_original` | Shrine | 1.3.0 |

**Always install via `shopify theme push` CLI** — never zip upload via API (causes "locked" role on dev stores).

---

## Known limitations

| Limitation | Reason |
|-----------|--------|
| `@media` CSS in section style blocks rejected by Shopify | Nested `{}` triggers false Liquid syntax detection |
| App-injected widgets (Loox reviews, Google badge) not cloned | Requires active app subscriptions |
| Dev store password can't be removed | Shopify platform restriction |
| `shopify://shop_images/` refs don't work in Asset API | Only works in theme editor UI — use direct CDN URLs |
| Products created at €0.00 by pipeline | Must verify ALL variants after pipeline run |

---

## Per-run output

Each clone produces:
- `runs/YYYY-MM-DD-{domain}.md` — full run log
- `runs/{domain}-assets/` — downloaded assets (branding, products, homepage, video)
- `runs/{domain}-assets/css-audit.json` — CSS design audit from source

These files live in `~/clawd/projects/store-factory/` on the agent machine.
