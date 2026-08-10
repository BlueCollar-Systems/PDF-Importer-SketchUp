# Design — surface the discarded per-stage import timings (SketchUp)

**Date:** 2026-08-10
**Status:** Approved by owner (design approved; owner said "build it", waiving the
spec-review gate).
**Closes:** open decision **D-23-4** from `QA-2026-06-23_perf-discussion-synthesis.md`
("Add per-stage timing to `import_report.json`").

## Problem

The owner asked for faster importers without compromising visual accuracy. The 2026-06-23
performance round already fixed the known SketchUp bottleneck (dense text now uses reusable
glyph component definitions: ~60,047 raw text-edge operations -> 0) and its own top regret
was recorded as **"measure, don't infer"**.

That regret is still live. A surviving report for `1011 (1 OF 2) - Rev 0 / text` shows:

    "performance": { "elapsed_ms": 96800.0, "peak_mb": 783.07,
                     "phases": { "total_ms": 96800.0 } }

96.8 seconds for one page with **no** breakdown. The cause is a single line:

    qa_report.rb:87   perf[:phases] = { total_ms: elapsed_ms } if elapsed_ms > 0

Meanwhile `stats[:pipeline_performance]` is already populated with 17 keys
(`main.rb:2997-3000` accumulator, plus the raster key map at `main.rb:3010`,
`text3d_render_ms` at `4298`, `explode_ms` in `geometry_builder`, parse/render timers in
`svg_3d_text_renderer`). **The measurements exist and are thrown away at report time.**

Optimising before fixing this means guessing. Earlier the same day a bbox-cache hypothesis
measured 2.8x in a synthetic test and delivered **zero** end-to-end gain — a direct
demonstration of why inference is not good enough here.

## Design

1. `qa_report.rb` stops hardcoding. `performance.phases` is built from the `*_ms` entries of
   `stats[:pipeline_performance]`, **plus** the existing `total_ms` key, which is retained
   verbatim so any current consumer keeps working.

2. **Suffix filtering is deliberate.** `pipeline_performance` also carries non-timings:
   `glyph_component_definition_count`, `raster_png_temp_bytes`,
   `raster_pixel_proof_temp_bytes`, `commit_includes_source_binding_verification`. Only
   `*_ms` may enter `phases`; the rest go to a sibling `performance.counters`, so a byte
   count can never be misread as milliseconds.

3. **`unaccounted_ms` = `total_ms - sum(stage_ms)`**, clamped at 0. This is the honesty
   mechanism: it states how much of the elapsed time the breakdown actually explains. A
   partial breakdown presented without it reads as a complete one — the same
   false-completeness failure as a returncode-only PASS.

4. **Gap-filling is deferred, not speculative.** Parse, primitive extraction and report
   serialisation (the report is 3.9 MB — itself a suspect) get timers only if
   `unaccounted_ms` proves large on real data.

## Accuracy and determinism

Measurement-only. No geometry, text, raster, placement, or cleanup path is touched. The
regression test asserts delivered `primitives`, `text_entities` and warning counts are
**identical** before and after, so "faster without compromising visual accuracy" becomes
verifiable rather than asserted. Stage keys are emitted in sorted order so two runs of the
same input produce byte-identical key ordering (determinism, priority 6).

## Non-goals

- No optimisation in this change.
- No threading (in tension with determinism and with the single-heavy-host lease on a
  15.75 GiB machine).
- No schema version bump: fields are additive.
- The other three hosts are out of scope until SketchUp's breakdown is read.

## Validation

Unit tests are host-free. The real payoff is one **leased** SU canary on `1011/text`
(input verified, 144081 bytes) to read the breakdown, which then selects the actual
optimisation target. Currently blocked only by RAM (0.56 GiB free; SketchUp peaks at
1.65 GiB), not by this change.

## Rejected alternatives

- **Optimise the suspects now** (report serialisation, verification scope, geometry
  batching). Faster to a number, but it repeats the bbox-cache mistake and the round's own
  "over-fixing" warning.
- **Attack the heavy-document tail first** (Attachment-C at the 1800s cap). Biggest felt
  pain, but the largest change and, without the breakdown, a guess about which stage
  explodes.
- **The third-party advice ordering** (parallel processing first). Three of its top tactics
  — glyph dedup, instancing, caching — are already shipped here (SketchUp glyph components,
  LibreCAD DXF BLOCK/INSERT `_glyph_block_cache`, FreeCAD `text3d_outline_cache`), and its
  "silently drop in a raster" contradicts the disclosure rule.
