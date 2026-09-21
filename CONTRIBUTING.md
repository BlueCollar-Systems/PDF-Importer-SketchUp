# Contributing — PDF Vector Importer for SketchUp

Import PDF vector drawings as **native SketchUp** geometry (`.skp`). SketchUp **2017** Make through current Pro is in scope; large sheets are **slow**. Accuracy over speed hacks; no dropped geometry. Do not drop this host or merge it into another importer runtime.

This repository is [BlueCollar-Systems/PDF-Importer-SketchUp](https://github.com/BlueCollar-Systems/PDF-Importer-SketchUp). Local folder: `C:\1PDF-Importer-SketchUp`. Orgs: **BlueCollar-Systems** (this repo) and **BlueCollarSys-0628** (private Tag QC, separate product).

Read **[AGENTS.md](AGENTS.md)** before any text-mode or fallback change.

## Full private pack (not in git)

`C:\Users\Rowdy Payton\Desktop\PDFTest Files\Q&A\` — `START_HERE.md`, `ONBOARDING.md`, `COMMUNICATION.md`.

Ask the owner for the hub and Desktop `PDFTest Files` (import outputs live there, e.g. `SU_<sheet>_Imports`). **Do not copy shop PDFs into git.** Private validation env, if granted: `BCS_PRIVATE_VALIDATION_ROOT` (never commit those PDFs). Communicate in the Q&A hub and with GitHub PRs/issues on this repo. No Slack/Discord.

## Standing rules

- Requested text mode is the deliverable. Wrong position/angle/size is an in-mode transform bug — do not switch representation to hide it. Finite closest ladders are in `AGENTS.md` / `.cursor/rules/text-mode-fidelity.mdc`.
- Website badges = **GitHub Releases**, not feature branches.
- Branding: **BlueCollar Systems**. Native CAD on the shop machine uses `C:\TMP\CAD-HOST-GLOBAL.lock`; do not kill another worker’s host.
- Default: no commit/push/release without owner **GO** in the Q&A hub.

```powershell
ruby test/smoke_test.rb
ruby test/ruby22_compat_test.rb
ruby test/import_health_test.rb
ruby test/textmode1_invariant_test.rb
```
