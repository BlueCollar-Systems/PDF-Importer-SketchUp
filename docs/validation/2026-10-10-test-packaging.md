# Local test packaging — 2026-10-10

The user's local packaging request authorizes these dated test snapshots. No production publish, deployment, store release, or host installation was performed. The dated RBZ is usable through SketchUp's Extension Manager; the other tools have their own package instructions in the consolidated launch guide.

## SketchUp package

**Current local revision: r3.** Install `SketchUp-PDF-Importer-TEST_v3.7.162_2026-10-10-r3.rbz` from the dated SketchUp test-build folder. SHA-256 is `14cd828b84d8927eb36f3f777e90961c45bc57095f311234594a73fce6e9ee57`. The complete exact Ruby suite now passes 2,266 runs and 20,063 assertions with zero failures/errors and eight skips; every one of the 646 archive members matches source and all 90 Ruby files parse. See [the persistence follow-up](2026-10-10-sketchup-persistence.md) for the actual first native 2017 diagnostic, cancellation/image/persistence fixes and remaining host checks. Prior RBZs are preserved in `SketchUp\Superseded`; the first native diagnostic used the initial snapshot.

- Package: `C:\BlueCollar-Test-Builds\2026-10-10\SketchUp\SketchUp-PDF-Importer-TEST_v3.7.162_2026-10-10.rbz`
- SHA-256: `a6f07a0bcbc3a09aaf30be2f3c384c45ff58398b6f48720581ba186a675725da`
- 646 members. All 90 packaged Ruby files match current source after the release builder's newline normalization.
- Exact Ruby 2.2.4-p230 parsed every extracted Ruby file. The complete suite passed 176 test files: Minitest rollups contain 2,230 runs, 19,789 assertions, zero failures/errors, and eight skips. The test interpreter used isolated Minitest 5.15.0; that development dependency is not in the RBZ.
- Extracted Poppler helpers returned success on the neutral PDF fixture. Relocated Ghostscript passed with ROM-only search, explicit local DLL, strict production arguments, the expected 200×140 page, and both transparent and opaque pixels.
- The actual legacy suite exposed `Integer#finite?` calls unsupported by Ruby 2.2. The validators now retain their Numeric guard and check `to_f.finite?`. Integer RGB/page/crop coordinates stay valid; nonfinite/overflow values remain rejected. The regression covers affine/source-paint binding and invalid page boxes.

Native SketchUp Make 2017 opened its Welcome window. Window activation failed once and after one supported recovery, so input automation stopped. Native import/save/reopen acceptance remains pending; reaching Welcome and passing language/runtime tests do not establish visual model acceptance. A current SketchUp Pro host is also pending.

## LibreCAD package

- Package: `C:\BlueCollar-Test-Builds\2026-10-10\LibreCAD\LibreCAD-PDF-Importer-Windows-TEST_v1.0.104_2026-10-10.zip`
- SHA-256: `5b5363988878d3cb6e96cf2c0b953eb82288c39e0f58b62b9a2365ece95fbd1b`
- 266,099,490 bytes. Hash-locked wheels and actual CPython 3.12.10 build four frozen entry points; the included Qt5.15.2 x64 menu plugin was compiled with the installed MSVC toolchain.
- The release's portable/source ZIP smoke passed, requiring the real menu plugin. The converter works from extraction without user Python, pip, a developer checkout, or a network dependency.
- A frozen executable, launched outside the checkout, converted page 1 of a private 179,562,772-byte/259-page PDF. The source was unchanged. The report certifies page 1 with 339 Glyph spans, one native Text span, and zero degraded items. The DXF reopened with 12,867 entities and zero audit errors/fixes. The 436.98-second elapsed time was measured on this loaded computer, not a general performance estimate; the remaining 258 pages were not certified.
- The frozen GUI opened and rendered its controls. Activation failed once and after one recovery; no GUI conversion was started, and the owned smoke processes were closed. Its interactive controls and visual comparison inside LibreCAD remain pending.

## Consolidated handover

The local desktop shortcut `BlueCollar Test Tools - 2026-10-10` opens the numbered launch menu. `C:\BlueCollar-Test-Builds\2026-10-10\START_HERE.html` gives per-tool instructions; `VALIDATION.html` and `PACKAGE_SHA256.json` contain the final cross-project checks and package identities. Distribution archives exclude private PDFs, credentials, real shop data, and internal build staging. License/runtime notices travel with each tool.

Blender/FreeCAD, Steel Logic, and Tag QC/website packaging evidence is owned by their corresponding project validation records. Windows test packages do not establish all historical/future hosts, all operating systems/hardware, universal pixel equality, actual mobile camera/OS dispatch, iOS installation, or automatic 3D reconstruction from arbitrary drawings. Remaining checks must use the actual host/device and preserve reports for unsupported/degraded items.


## Final r4 follow-up — 2026-10-10

This later record supersedes earlier pending r3 statements for the listed neutral checks only. The r4 RBZ SHA-256 is `f372b69840f02c28fb7a7abf09a5cc2d276a2a74a1ae0e12a052cdc57c7edfa9` (27,623,794 bytes), with tree `fbf8e332fd1f9af8ddbe82979c48f175acce0ac6a86a55520a03192bc3264b9b`. Full exact Ruby 2.2.4-p230 suite on the owned frozen r4 source clone: **179 files, 2,345 tests, 21,027 assertions, zero failures/errors, 8 skips**; captured clone source/tests/tools remained unchanged. A prior mutable-repository suite had zero failures/errors but failed its unchanged-source gate because an unrelated actor added Extrude UI/menu code. That working-repository change is preserved and excluded from r4; the final suite is bound to the exact frozen package instead. Original native harness tools retain their native-proof byte bindings. All eleven actual Make 2017 native matrix rows and independent external checks passed, including three native cancellation cases. Fresh source/cache-unavailable scopes: **text page(s) 1, 2 Images; raster page(s) 1, 5 Images; raster page(s) 2, 1 Images**. Every scoped Image has physical TextureWriter pixel proof and all fixture files/preferences were restored. Native render PNGs support inspection; no rendered pixel equality is claimed.

Editable bounded source-width footprints, source-point lineweight groups/tags, protected original centerlines, honest approximation warnings and flat-color display are included. Requested text modes and finite item-scoped fallback contracts remain intact. The corrected fictional sample PDF SHA-256 is `3dcb8e4ab9e91bfc456e33157111bc1486fcba3f335bf061a14ab56b2defce7e`. Neutral original proof JSON, SKPs, available render PNGs and an original/copied-byte ledger are under `C:\BlueCollar-Test-Builds\2026-10-10\SketchUp\Validation-r4`. Earlier r3 records/trees remain historical evidence; the exact r3 installer is archived under Superseded. Other project validation stages are unchanged.

- Physical Escape-key presses and GUI button interaction are not certified by injected cancellation probes.
- Current SketchUp Pro, other SketchUp versions/platforms and broader PDF/hardware coverage remain pending.
- Requested Labels uses the certified item-bound source-outline 3D visual equivalent on Make 2017; it is not an editable screen annotation.
- Bounded editable source-width footprints cover proven solid opaque undashed eligible paths; unsupported cases retain editable approximate native centerlines and report review warnings.
- Curve footprints use explicitly bounded polygonal sampling; no analytic-curve or universal page fidelity claim is made.
- Native Image boundaries and viewport rendering can differ from the PDF. Genuine Images are preserved; no rendered pixel equality is claimed.
- Fresh source-unavailable proof covers only the listed neutral modes/pages, not every PDF or mode.
- This unsigned local test snapshot does not install itself, change production extensions, deploy a website or publish a store release.
