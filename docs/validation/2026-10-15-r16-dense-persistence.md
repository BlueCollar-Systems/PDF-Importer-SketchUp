# SketchUp 2017 r16 dense persistence — 2026-10-15

Version **3.7.169** passed the bounded native SDK import/save, first-load
healing/save, and distinct fresh-process reopen check in SketchUp Make 2017
**17.2.2555**. This covers one dense structural drawing, page 1, using the default
Auto/3D Text settings and the exact candidate below.

- Source commit: `518835cfc534a24cb9a6143dbd53cad11bda619f`
- Git tree: `7acec9e35456dc59ea1eb0a8d71d2a787d14a594`
- RBZ SHA-256: `ab367d43d5051822f0a6dcd1543a06dc6baee7d98ec7d6a3f0944f5e56183e77`
- Extracted host-tree SHA-256: `248caec978ab153a8bf9610935ba566a9fbb1d7553372f363b65daf8852dacad`

All **650 archive/extracted members** and the sealed inputs were rechecked.
The actual import pipeline took **171.136 seconds**; this excludes subsequent
physical readbacks and operator handling. The unchanged owner retained its
420-second cooperative import bound, hard import/heal/fresh bounds of
660/360/360 seconds, and 1,380-second total native bound. A separate guided UI
budget did not extend those deadlines.

All three native processes exited normally with code zero. Across import,
first load, and fresh reopen, the report joins retained **291 source spans**:
**286 positive-depth source-glyph 3D groups** and **5 typed native zero-ink ledger
records**, with no text step-downs, text failures or text raster deliveries.
Persistent IDs, geometry, transforms, styles, content, zero-ink ledgers and
parent/child structure remained exact; process-local entity IDs changed as
expected under the existing comparison contract.

The **16 qualified source fill contours** retained their boundaries, positive
area/winding, front/back materials, hidden contour edges and native visibility flags.
The actual import recorded zero `draw_face` warnings and zero fill failures.
The **one embedded image** retained its 401×251 native TextureWriter/decoded
pixel proof through fresh reopen. The private import source/cache dependencies
were unavailable during that last process and were restored afterward; original
user files were preserved. Preferences and owned leases were restored.

Evidence SHA-256 bindings:

| Record | SHA-256 |
|---|---|
| Exact request | `6f614a8dcf0d35256c419c759a3ff0081ada50280360423dab099ea6037f73e1` |
| Owned wrapper result | `464f6e9dffdcc1b36344379f0e4a91f25991f27f6305e5dcd41105651ba69081` |
| Import result | `a7012448db5565140622a483a0604921eab775d70a1f5d37d6da6a897e07d082` |
| First-load result | `8ed04967f03c111efd99ec20ab54a800d55782ce8403a07863efdd3e6f12d945` |
| Fresh result | `a1b5f9de2b5f69c3952198d31f7cf55a966da31e990be4967a25b2876442016f` |
| Bound import report | `217c19361366729d3cf4ff5cc9293ee2151c4960656037b9f8a656be621430fe` |
| Independent review | `80584512ddfe3091b8590ac6e8f4d69ce10410a5dc0e0fbc1bcc2b7696b18887` |

The immutable report matches its recorded hash. A later mutable cache copy has
different formatting but identical complete JSON values; both raw hashes remain
in the private review. Unrelated embedded-browser console warnings remain in the
native logs. An earlier same-contract attempt reached the fixed healing deadline
and remains failed; this retry did not change its outcome or the test limits.

This proves the scoped SDK persistence/readback behavior. Ordinary installed-menu
import, interactive SaveAs/Undo, other modes and host versions, source composition
coverage, and whole-viewport rendered pixel equality remain separate checks.
This document does not publish or promote a release.
