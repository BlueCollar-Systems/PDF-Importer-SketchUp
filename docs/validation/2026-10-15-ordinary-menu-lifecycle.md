# SketchUp 2017 ordinary-menu lifecycle — 2026-10-15

The installed **3.7.169** candidate was exercised through ordinary **File >
Import PDF Vectors...**, the import dialog, **File > Save As**, **Edit > Undo**,
and a distinct SketchUp Make 2017 **17.2.2555 / Ruby 2.2.4** process using normal
**File > Open**. Small-drawing import/save/Undo/reopen completed. The foundation
drawing imported and saved, and a separate fresh process reopened and resaved it.
Its captured **single-Undo acceptance remains failed**. The updated **3.7.170**
candidate subsequently completed the small-drawing ordinary-menu import, save,
single Undo, distinct fresh-process Open and Save As checks described below.

These are guided desktop checks with a read-only startup observer. The observer
did not invoke the importer, save a model, issue Undo, or close SketchUp. Each
guided stage had a 1,800-second operator/tool budget; each observer capture
retained its separate hard 60-second diagnostic deadline. Original PDFs and user
models were preserved, and tests saved new copies.

| Candidate | Source commit | RBZ SHA-256 |
|---|---|---|
| 3.7.169 / r16, used for the lifecycle checks below | `518835cfc534a24cb9a6143dbd53cad11bda619f` | `ab367d43d5051822f0a6dcd1543a06dc6baee7d98ec7d6a3f0944f5e56183e77` |
| 3.7.170 / r17, report correction; Field Bolt menu/fresh checks complete | `a340c91c210403e81214490465598f1cc39a6676` | `34fb03b8ce72ea505372380beac581c4ce85b61b704942edb822aeba64539adf` |

The 650 installed r16 files matched the tested RBZ. The previous 649-file
3.7.166 installation was preserved outside the active Plugins directory, and
unrelated plugin files were unchanged. The captured application setting
`RubyManager_DisablePlugins=1` had disabled ordinary plugin loading. It was
deliberately changed to **0** and remains enabled so the installed importer
is available at normal startup. The original value is retained in the backup
record; restoring that old disabled value is not part of final cleanup.

**Field Bolt Summary.pdf** (SHA-256
`8e6c3bd4c95275f0e43286c48f8b5cd9cb5ede0c2bf8e79ab67df4a26dd9b0bb`):

- The ordinary import pipeline took **9.2 seconds** and retained one page with
  **61 source-outline 3D Text groups** and **7 item-image fallbacks**, accounting
  for all 68 recorded text items with no failed or unaccounted items. The 3D
  groups are editable geometry; the seven images are not editable text.
- The report retains three adjacent transitions for each affected source item:
  3D Text → Glyphs → Geometry → Raster. The available source association could
  not establish exact item ownership/coverage for those seven items. This is a
  current source-matching limitation, not proof that their PDF ink can never be
  represented as vectors. No whole-page raster substitution is claimed.
- Import/save ran in native PID **10588**. Saving retained the captured import
  inventory. One ordinary Undo restored the original top-level/direct-child
  inventory exactly, including its pre-existing drawing fixture.
- Native PID **10476** freshly opened the saved model, displayed the table,
  saved a new copy and closed normally. No repair prompt was observed. Both
  native processes exited with code zero and their owned exit was verified.
- The strict saved-to-fresh inventory comparison remains **FALSE**. Read-only
  comparison found exactly **77 differences**, all in session-local `entity_id`
  fields. Persistent IDs and every other captured field matched. The strict
  fresh-to-resaved comparison was **TRUE**. The raw result was not normalized
  or changed to a pass. SketchUp documents `entityID` as session-dependent and
  `persistent_id` as persistent for supported entities, including groups and
  images in SketchUp 2017. See the official
  [Entity API documentation](https://ruby.sketchup.com/Sketchup/Entity.html#entityID-instance_method).

**Foundation drawing** (SHA-256
`563ed39b60518ffe34844cd142063678d51e8f675396f6b968d478e81483d6cd`):

- Native PID **31732** completed the ordinary-menu import in **214.3 seconds**,
  retaining the page with **41,412 edges**, **286 positive-depth source-outline
  3D Text groups** and **5 qualified zero-ink records**. The native drawing was
  visible and saved through ordinary Save As. Pipeline timing excludes later
  operator handling, saving and observation.
- A host **Check Validity** transaction followed the import transaction during
  the save workflow. The first visible Undo command was **Undo Check Validity**.
  Its captured result did not restore the original fixture inventory, so the
  existing single-Undo owner result remains **FAILED**.
- A separately observed second command, **Undo Import PDF Vectors**, removed
  the foundation sheet; Zoom Extents then showed the original fixture. This
  additional UI observation was outside the single-Undo capture and does not
  replace or waive that failure. The saved imported model was retained by
  declining to save the subsequent Undo changes. The process exited normally.
- A separate native PID **20776** opened the saved foundation model through
  ordinary File Open, displayed the sheet, saved a new copy and closed normally
  with code zero and verified owned exit. No repair prompt was observed.
- The strict saved-to-fresh inventory comparison remains **FALSE**: exactly
  **321 differences** were session-local `entity_id` fields. Persistent IDs,
  bounds, transforms, attributes, materials and every other captured field
  matched. The foundation group retained its **312 direct children** (311
  groups and one image), alongside the original fixture. The strict
  fresh-to-resaved comparison was **TRUE**; no raw result was normalized.
- This independently qualified fresh check does not replace or waive the
  failed combined single-Undo result. No foundation single-Undo lifecycle pass
  or full evaluated-geometry/image-pixel parity is asserted.

The small drawing exposed a separate **report messaging bug**: zero page-path
primitives were described as empty vector content despite the 61 native 3D
items, and compact fallback prose implied that the complete requested text mode
became raster. Version **3.7.170** corrects that summary from actual delivered
kinds and counts, uses a review classification for native text content, and
scopes raster prose to fallback items. It preserves primitive counters,
representation ladders, fallback JSON, delivery ledgers and readiness gates.
Aggregate item-image counts cannot classify a selected whole-page fallback as
a semantic text item; a two-page regression covers that ambiguity.

The exact r17 package contains **650 files** and **94 shipped Ruby files**;
archive/source/extracted-byte verification and Ruby 2.2.4/3.4.4 parsing passed.
Only the loader version, metadata version and report implementation differ from
r16's runtime payload. The package's five focused reporting regressions passed
on both Ruby **2.2.4** and **3.4.4**: **5 tests / 57 assertions**, no failures,
errors or skips in each run. These are reporting controls, not native geometry
or image-pixel certification.

The exact installed **3.7.170** package then completed a real ordinary-menu
Field Bolt import/save/Undo check in PID **25152**. Its native pipeline took
**10.3 seconds**, again delivering **61 source-outline 3D Text groups** and
**7 item-image fallbacks**, with all 68 items accounted for. The actual report
now gives that delivery breakdown, classifies content as **review**, and scopes
its raster recommendation to **7 fallback items**. The report no longer calls
the zero page-path-primitive count empty delivered content.

The captured imported/saved inventories matched exactly, and one visible
**Undo Import PDF Vectors** restored the original fixture inventory exactly.
The process closed normally with code zero and verified owned exit. Separate
native PID **8796** then opened the saved model through ordinary File Open,
displayed the Field Bolt table, saved a new copy and closed normally with code
zero and verified owned exit. No repair prompt was observed.

The r17 strict saved-to-fresh inventory comparison remains **FALSE**: exactly
**77 session-local `entity_id` fields** changed, while persistent IDs and every
other captured field matched. The strict fresh-to-resaved comparison was
**TRUE**. The saved/reopened copy is **1,675,526 bytes**, with SHA-256
`74019509ec38b38cf44167f598d5bc8339c7a07630bdeb09d394b7b10113c386`.
These scoped functional results preserve the raw comparison failure and do not
change the earlier foundation single-Undo failure or certify all PDFs/settings.
All owned native applications were closed and test leases released afterward;
ordinary plugin loading deliberately remains enabled as described above.

| Retained record | SHA-256 |
|---|---|
| Field Bolt ordinary-menu owner | `89686f86e603f62b0bdfdc61e299c4aa349f6993481d827d4233f22e94b2af92` |
| Field Bolt fresh-process owner | `e6b532d05fff2e07d647469585d5b60a6ed9429fa55155cc21a387aa35218d0e` |
| Field Bolt actual import report | `56af9eedac40e570af8cc151a070b001e273a8be15d2c280623dd6d1fdbeb81c` |
| Foundation single-Undo owner, failed | `8aac983427ff0d9c318916a563f7dfc3629cd13b952e9bb38499bf59e712889c` |
| Foundation actual import report | `525d90be81c88d6caba756881105b817aafaf27768f6d575a6d5f66c69d065b2` |
| Foundation independent fresh-process owner | `5832ebad2070a1c43ff83c59c0beeeaa83964ae3cb8c7657e05bf0abeeb900c3` |
| r17 package identity record | `c1f5f47bbda25adf20f3c574b6613b5064f2b5d5d1cfe93c34d151db70aab923` |
| r17 Field Bolt ordinary-menu owner | `35c14508eb0bfe846efc607d8f55a92ddb50b4f7d050b61b0966704261eb15bc` |
| r17 Field Bolt actual import report | `77efdbe40cf4444b85127c2b626d3e0b8b8fb7ac8169826687239d52915012d0` |
| r17 Field Bolt fresh-process owner | `8b12414f98e6ae7d8bb9e9553e3cfb52355ef624e95360bfa725d9d0a652be0a` |

This check covers ordinary UI operations and the recorded lightweight entity
inventory. It does not certify full evaluated meshes, saved/reopened raster
pixels through TextureWriter, complete source composition, or rendered pixel
equality. The earlier r16 dense SDK geometry/image-pixel persistence result is
[documented separately](2026-10-15-r16-dense-persistence.md) and remains unchanged.
Other text modes, settings and host versions require separate checks. Earlier
failed evidence remains retained. No release was published by these tests.
