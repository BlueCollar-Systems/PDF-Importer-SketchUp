# Compatibility — PDF Vector Importer (SketchUp)

**Canonical path:** `C:\1PDF-Importer-SketchUp`  
Modes are extraction **strategy** (Auto / Vector / Raster / Hybrid), not quality tiers.

---

## Minimum host version

**SketchUp Make / Pro 2017** (Ruby 2.2.4).

## Oldest tested

| Host | Status |
|------|--------|
| SketchUp Make 2017 | ⚠️ Expected — Ruby 2.2 CI gate; **field retest required** (use **v3.7.67+**, latest **v3.7.68**) |
| SketchUp 2018–2023 | ⚠️ Expected |
| Current SketchUp Pro | ⚠️ Expected |

**Do not use v3.7.65 or earlier on SketchUp 2017** — extension may fail to load (Ruby syntax).

## Ruby / Python ABI

| Runtime | Notes |
|---------|-------|
| **Ruby 2.2.4** | SketchUp 2017 — hard syntax/API floor; see [Ruby 2.2 guide](#ruby-22-compatibility-guide) below |
| Ruby 2.5–3.2.x | SketchUp 2018 through current Pro |
| Python | **Not required** for core vector import |

## Bundled dependencies

| Dependency | Shipped in Windows RBZ? |
|------------|-------------------------|
| Poppler (`pdftocairo`, `pdftotext`, `pdffonts`) | ✅ Yes |
| MuPDF `mutool` | Optional helper if on PATH |
| Ghostscript | ❌ Not bundled — optional font repair |

Release build fails if bundled Poppler helpers are missing.

## Legacy hardware notes

- Prefer **Labels** over **Glyphs/Geometry** on PCs with **&lt; 8 GB RAM** or pre-2015 CPUs — glyph modes create many edges.
- Use **page ranges** for large shop sets on slow machines.
- Import report `human_summary` notes fallbacks; open **Import Health** after import.

## Offline install

Windows **RBZ** from GitHub Releases works without internet after download (Poppler bundled). Ghostscript remains an optional separate download.

## Enterprise / multi-user

Install RBZ **per Windows user** per SketchUp year. Avoid roaming only the Plugins folder across mismatched SketchUp versions. **Compatibility Report** logs the extension directory.

## Preflight command

| Audience | Command / action |
|----------|------------------|
| Shop user (GUI) | **Extensions → PDF Vector Importer → Compatibility Report** before first import |
| After import | **Extensions → PDF Vector Importer → Import Health…** |
| IT / scripting | Install RBZ → restart SketchUp → run Compatibility Report; CI: `ruby tools/ruby22_syntax_check.rb --include-tests` |

SketchUp Make 2017 is **not redistributed** from bluecollar-systems.com — obtain from Trimble independently.

---

## Host version matrix

| SketchUp | Ruby | Status |
|----------|------|--------|
| Current Pro | 3.2.x+ | ⚠️ Expected |
| 2024 | 3.2.2 | ⚠️ Expected |
| 2020–2023 | 2.7.x | ⚠️ Expected |
| 2018–2019 | 2.5.x | ⚠️ Expected |
| Make / Pro 2017 | 2.2.4 | ⚠️ Expected (CI syntax-checked) |
| 2014–2016 | 2.0.x | ⚠️ Expected only after dedicated host verification |
| 2013 and earlier | | ❌ Not supported |

See also [HOST_COMPATIBILITY.md](HOST_COMPATIBILITY.md) for helper policy and text-mode matrix.

## CI coverage

GitHub Actions: `ruby -c` under Ruby **2.2, 2.7, 3.2**; `ruby22_syntax_check.rb`; smoke tests under **2.2, 2.7, 3.0, 3.2** (Docker for 2.2).

---

## Ruby 2.2 Compatibility Guide

All Ruby code in this extension **must** run on Ruby 2.2.4, which ships with SketchUp Make 2017.

### Constructs to Avoid

| Construct | Introduced | Safe Alternative (Ruby 2.2) |
|---|---|---|
| Endless range `arr[n..]` | 2.6+ | Two-argument slice `arr[n, len]` |
| `Integer#positive?` | 2.3+ | `n > 0` |
| `Array#sum` | 2.4 | `array.inject(0, :+)` |
| `Hash#transform_keys` | 2.5 | `Hash[hash.map { \|k, v\| [new_key(k), v] }]` |
| `&.` (safe navigation) | 2.3 | `obj && obj.method` |
| `Enumerable#filter` | 2.6 | `Enumerable#select` |
| `String#match?` | 2.4 | `!!(string =~ regex)` |
| `Hash#dig` / `Array#dig` | 2.3 | Chain `[]` with nil checks |

### General Rules

1. CI runs `ruby22_syntax_check.rb` on every shipped `.rb` file.
2. Never use features listed above without a version guard.
3. When in doubt: `docker run --rm ruby:2.2 ruby -c yourfile.rb`.
