# SketchUp 2017 report wording and foundation checks: v3.7.175

The v175 reporting correction leaves the impossibility reason nil for successful
same-mode Glyphs/Geometry delivery. Genuine mode step-downs retain their reasons
and transitions. The r24 QA correction also counts distinct literal page-step
rows as warnings and changes high/moderate vector-abundance tiers to `review`
when those limitations exist. Detailed rows, fallback accounting and geometry
remain unchanged. This is reporting consistency, not a paint or height repair.

## Exact r24 candidate

| Identity | Value |
|---|---|
| Built source | `68e1f4886095b5a8111347cdc2f60aebbc69e02b` |
| Tree | `4f2b247291b9c5e9cab93288ad8f21b1de3abdf2` |
| RBZ SHA256 | `f4b7eb39e442e49325b2ae3696882f87d9a7e78e1122a5f87fa64d9cbf8da2ce` |
| Bytes / members | 27,708,112 / 651 |

Both RBZ aliases and all installed members match the exact committed build.
Only `qa_report.rb` differs from r23; the other 650 members and all 31 bundled
runtime files match. All 95 Ruby files parsed with actual Ruby 2.2.4. The 651
prior owned plugin files were backed up, 313 unrelated files were preserved and
preferences stayed unchanged. The immutable build identity keeps its original
native-check PENDING entry; the dated native acceptance records completed work.

Six actual-repository suites passed on each of Ruby 2.2.4/official Minitest 5.4.3
and Ruby 3.4.4/default 5.25.4: smoke 101 checks, Ruby compatibility 3 tests/5
assertions, Import Health 5/15, text-mode invariant 3/23, source-paint pipeline
6/77 and full QA 53/349. Parent and nested Ruby/dependency selection were verified;
source/test hashes remained unchanged during all twelve runs.

## Completed r24 foundation Glyphs check

The exact candidate used the ordinary SketchUp 2017 Make import menu on
`00S-505_ FOUNDATION SECTION AND DETAILS Rev.0 markup.pdf`, followed by Save As,
one Undo, normal close, then Open/Save As in a fresh process.

| Observation | Result |
|---|---|
| Reported import time | 226.3 seconds on this PC |
| Text accounting | 286 direct Glyphs + 5 verified zero-ink spans; 291/291 accounted |
| Text-mode step-downs / lost spans | 0 / 0 |
| Direct-success wording | 286 nil-reason, nondegraded Glyphs rows |
| Actual report and ordinary Import Health | 2 warnings, content review `review` |
| First Save exposed graph | 72,872 entities; 0 added, removed or modified; 0 definition changes |
| First Undo | Import PDF Vectors; one Undo restored the literal empty baseline |
| Fresh Open/resave | No repair prompt; loaded/resaved inventory literally equal |
| Cross-process inventory | 28 literal session-entity-ID differences; other captured fields equal |
| Native processes | PIDs 26120/16660 exited naturally with code 0; retained handles closed |

Both raw page limitations, source-text accounting and fallback dictionary remain
identical to r23. White-mask source overlap was unproven, so original white shapes
were kept; final annotations were placed without a usable text-height result.
The page remains delivered with `fallback.used=true` and empty text transitions.
These warnings do not prove hidden text, but prevent a full-fidelity claim.
Unqualified source paint also keeps contour strokes visible.

The exposed Save graph and lightweight reopen inventory are bounded checks, not
complete internal host validity, recursive fresh-mesh or image-pixel proof.
Different imported/resaved SKP hashes and literal ID differences remain retained.
The 87.9-second root-observed Undo interval is not an internal timing benchmark.

## Separate r23 3D Text evidence and limits

Source `9a84ca0da79e6be9ff408074717ad0b05182cb5f`, r23 RBZ SHA256
`c02afb19a57f698f13c65f1ef850fa7bbd495c5255234b654ac20de0d7153373`,
passed its own foundation 3D Text pair: 177.3 seconds, 286 text items + 5 zero-ink
spans, no fallback/page steps, 111,825 exposed entities unchanged at first Save,
one Undo to empty, fresh Open/resave without repair and normal process closure.
Its 313 literal cross-process session-ID differences remain recorded. A corrected
homogeneous-transform census found all 286 source owners had caps, sidewalls,
1/64-inch depth and two Faces per Edge. The original private reader omitted the
homogeneous divisor; that failed reader/result is preserved as a reader failure.
These are r23 observations, not a new r24 3D test.

Earlier 172 Check Validity/Undo failure, 173/174 results, original reports,
failed attempts, PDFs/models and large native evidence stay unchanged. Other
PDFs/modes/hosts, full-page appearance, exact outlines, embedded-image pixels and
general text-string editing remain separate checks. No release was dispatched.

## Bound private receipts

- r24 pair: `C:/BlueCollar-Validation/2026-10-17/foundation175-r24-glyphs-r1/Evidence/offline-review-r1/PAIR-REVIEW.json`,
  SHA256 `29e3e11a52922c4f63f1d4d6f8c323816806ec2389ec4864aef74cfd490f1428`.
- Twelve-run matrix: `C:/BlueCollar-Validation/Checks/su175-actualrepo-QA-required-20261017-r1/RESULTS.json`,
  SHA256 `c1804cc2bf1b9b592e9a9289e19e1018a6086a70d3c23646b84c5771461e52a0`.
- Exact build/install: `C:/BlueCollar-Validation/Checks/su175-r24-independent-postbuild-20261017-r1/INDEPENDENT-POSTBUILD.json`,
  SHA256 `4ebc7e75efe182812739b8d309411c7c5296212f45a513ab9bf1165374c70f37`.
- r23 3D pair: `C:/BlueCollar-Validation/2026-10-17/foundation175-text3d-r1/Evidence/offline-review-r1/PAIR-REVIEW.json`,
  SHA256 `6fea2c7a98deee03dbbe09db1bb4cb75f58d937d74db72b44cfc571f09136da6`.
- Corrected r23 census: same directory, `EXPOSED-TEXT3D-CENSUS-r2.json`,
  SHA256 `47f8c7e04a44feabd935e789df1d4cc6dcd8d2d6a345b18cd5aac41ec04e8c5e`.

The local guide and `NATIVE_ACCEPTANCE_2026-10-17.json` provide the dated delivery
record without rewriting sealed build or earlier acceptance evidence.
