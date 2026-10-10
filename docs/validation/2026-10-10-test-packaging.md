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
