# Item Raster pixel-grid correction: v3.7.171

The v3.7.170 ordinary-menu test found visible gaps in slanted Raster text before
saving and after a fresh reopen. The correction aligns crop placement with the
actual renderer's device pixels. Native v3.7.171 visual acceptance is **pending**.

## Correction and source checks

An item crop contains an integer rectangle from the shared RGBA page render.
Previously, its Image used the unrounded source rectangle, giving overlapping
crops different positions for the same page pixel. The new placement uses
`DPI / 72` pitch and the decoded canvas height for the inverted Y origin. It
does not fit the rounded canvas dimensions back to a fractional MediaBox.

The requested clamped source box, decoded page size and raster DPI remain in the
artifact evidence. Placement independently derives the bounded integer crop and
its source footprint, including all four intrinsic page rotations. Only that
derived fractional boundary pixel may cross the MediaBox. Legacy artifacts
without any grid fields retain their strict inside-MediaBox guard. Partial or
contradictory grid metadata is rejected. Text representation and display depth
are unchanged.

Actual packaged Ghostscript rendered a finite authored PDF with a nonzero,
fractional MediaBox at rotations 0/90/180/270. Measured ink centroids agreed with
the DPI/device-origin calculation within 0.032 device pixels. This renderer probe
does not establish native Image display fidelity.

Both Ruby 2.2.4 and 3.4 passed the affected checks: representation contracts
110 tests/1,131 assertions, item display 13/96, renderer 10/138, Poppler boundary
10/42, and the actual Ghostscript coordinate regression 1/73. Exact Ruby 2.2.4
also parsed all 94 shipped Ruby files. These checks do not replace a native
import/save/reopen/Undo test.

## Local r19 test candidate (historical preparation)

| Field | Bound value |
|---|---|
| Version / candidate | 3.7.171 / r19 |
| Product source commit | `6cdefa76c510db8b27a2e55e57c06232cc3bb864` |
| Source tree | `8a5b35cffee2d81abad13bcccba66b9f392e46d1` |
| RBZ | `SketchUp-PDF-Importer-TEST_v3.7.171_2026-10-16-r19.rbz` |
| RBZ SHA-256 | `848f18f95d4699da232f9c5578ba38312d3cec3e10007a377af9ea1095d15473` |
| Files / bytes | 650 / 27,692,213 |

All 650 archive and extracted files match that committed source. All 94 shipped
Ruby files parse under actual Ruby 2.2.4, and all 31 runtime binaries match r17.
Bundled Poppler and relocated transparent Ghostscript smokes passed. Independent
package verification repeated the file comparisons. The exact r19 installation
preserves the 650-file r18 backup and all 340 unrelated plugin files, without
changing preferences. The older v3.7.170 backup remains preserved separately.

The new request at `C:/TMP/su171-rm-mode-raster-20261016-r3/request.json`, SHA-256
`5486a76e377c9fae81426c016c2cb0ac66f6e46d3233f01c293699bfc2e5ea52`,
passed read-only preflight against the exact installed package. It has **not**
launched a native session. Windows' unrelated permission prompt still requires
manual handling. CAD programs remain closed and no native ownership lease is
held. The r19 guide and master package list explicitly retain pending acceptance;
all other-host sections of the master list remain byte-identical.

## Preserved r18 candidate, superseded before native testing

| Field | Bound value |
|---|---|
| Version / candidate | 3.7.171 / r18 |
| Product source commit | `c8226f949f776b6ec38500dc327213f3e56eb87b` |
| Source tree | `cc53780b35ce5c835003c0450f1776c4993592c4` |
| RBZ | `SketchUp-PDF-Importer-TEST_v3.7.171_2026-10-16-r18.rbz` |
| RBZ SHA-256 | `0d783ec40bd944c5c3e221a65d0c8ceed0e571e927e08529d9362b85a4be9eb5` |
| Files / bytes | 650 / 27,691,682 |

The local repository build ran the bundled Poppler and relocated transparent
Ghostscript smokes successfully. Every archive and extracted file was compared
with its exact committed Git blob, with the builder's Ruby newline convention.
All 31 runtime binaries match r17. Installation preserved the exact 650-file
v3.7.170 backup and all 340 unrelated plugin files; preferences were unchanged.

Further review found that the embedded-image display-plan caller did not forward
page rotation into the new guard. This would reject the combined Raster/source-
image path on intrinsically rotated pages. The runtime correction explicitly
forwards rotation, with a caller regression and a complete source-check rerun.
This required the separate r19 candidate above before native testing. The r18
package and its unexecuted request remain preserved as historical evidence.

Actual bundled `pdftocairo` output confirmed that its SVG already contains
intrinsic page rotation. The correction therefore maps source-image corners and
Raster coverage boxes around the selected SVG page box before the SVG Y flip.
Qualification and saved-image verification use the same mapping and reject a
crop/page rotation mismatch. Native image geometry is unchanged. Rotation zero
keeps the original floating-point evaluation order so existing fractional-page
ledgers retain their exact bounds. Final source-image tests passed 44 tests/179
assertions and decorative saved/JSON checks passed 40/62 on Ruby 2.2.4 and 3.4.

The full local union of the CI smoke rosters completed 106 separate test files
per Ruby version. Its original Ruby 2.2 run found an older Minitest exception-
matching incompatibility in the omission-ledger tests. Those tests now require
the actual `SketchupHostEvidence::EvidenceError`; the final 14 tests/51 assertions
pass on both versions. Nine affected suites and all three changed runtime-file
parses were rerun after the final source corrections and passed. GitHub CI must
rerun on the corrected commit; the earlier four failed smoke lanes stay recorded.

The r18 private ordinary-menu request was prepared and passed read-only preflight:
`C:/TMP/su171-rm-mode-raster-20261015-r2/request.json`, SHA-256
`b6ebd5900774ddc3b846d8489dc49fbcb80813307dfa806a38e197e631e5be38`.
No v3.7.171 native session has been launched for that request. Windows currently
has an unrelated permission prompt awaiting the user; security prompts require
manual handling. CAD programs remain closed and no native lease is held.

## Subsequent interrupted r19 test and evidence availability

After the permission prompt was dismissed, the exact r19 candidate completed an
ordinary-menu Raster import in SketchUp 2017 Make. Slanted-text white cutouts
remained visible. The user interrupted for a restart before Save As; that attempt
does not establish save, Undo, or fresh-reopen acceptance. Its earlier pending
statements above describe preparation at the time, rather than the later attempt.

On October 17 the former `C:/TMP` diagnostic directories were absent. The source,
test packages, and original user PDFs remained available. Historical hashes and
observations are retained here; the missing temporary files cannot presently be
independently inspected. New diagnostics use `C:/BlueCollar-Validation/` and are
separate evidence, without replacing or relabeling the interrupted attempt.

The subsequent source-renderer check reproduced the cutouts outside SketchUp:
extractor boxes omitted glyph ink even with the existing padding. See the
[source-owned crop correction](2026-10-17-raster-owned-ink.md).

## Required native acceptance

Use the ordinary File menu with Auto, Import Text enabled and Text Rendering
Raster. Inspect the horizontal, vertical and slanted text, save a new SKP, test
the first Undo once, and reopen/resave the saved import in a fresh process.
Preserve raw inventory differences and any failed outcome separately.

The prepared read-only diagnostic observes the actual verifier's PNG before
temporary cleanup, without replacing product methods or return values. Retain
the live embedded PNG and sidecar after import. Subsequent actual TextureWriter
exports must match decoded source pixels and dimensions for saved and reopened
Images, with placement and persistent ancestry checked independently. Guided
operator stages allow 1,800 seconds; each native diagnostic retains its hard
60-second deadline.

The earlier [v3.7.170 results](2026-10-15-foundation-and-text-modes.md) remain
unchanged: all six finite fixture modes completed lifecycle checks, Raster
visual acceptance failed, and the foundation first Undo stopped at Check
Validity. Its one embedded image passed a separately scoped physical pixel
check. That does not certify the whole drawing or resolve Undo.

No public release has been published. The corrected package is a test candidate;
native visual, remaining geometry and newer-host acceptance remain incomplete.
