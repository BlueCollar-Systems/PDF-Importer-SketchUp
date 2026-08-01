# SketchUp Resilient Import, Release Completion, and Host Identity Design

**Status:** Approved for implementation

**Approved:** 2026-08-01

**Scope:** `C:\1PDF-Importer-SketchUp` and guarded private evidence under `C:\TMP`

## 1. Outcome

Long editable-text imports must tell the user how much work is ahead, publish
bounded progress, respond to Cancel, and resume only previously certified page
work. Release automation must converge safely when a tag or Release object
already exists. Real-host acceptance must prove the exact commit, tag, package,
loaded modules, host, and source bytes it claims.

The six requested representations and their item-specific fallback ladders do
not change. No performance or resume feature may weaken type, visual, source,
ownership, raster, or save/reopen evidence.

## 2. Non-negotiable constraints

1. Ruby `2.2.4-p230` and SketchUp Make 2017 remain supported.
2. Requested-mode fidelity and the finite closest fallback ladders in
   `AGENTS.md` remain authoritative.
3. Cancel never records a partial source item or partial page as delivered.
4. A resumable page is retained only after the existing import-contract and
   representation-fidelity gates certify it.
5. Resume requires the exact PDF SHA-256, selected pages, behavior-affecting
   options, importer identity, and package/source identity.
6. A mismatch stops explicitly. It never silently reuses prior entities.
7. Existing release assets are never overwritten or relabeled.
8. Private PDFs, generated models, and host evidence remain outside git and
   release packages.

## 3. Product import control

### 3.1 Complexity estimate

Add a focused `ImportRunControl` module. Before editable host construction it
receives observed page count, semantic span count, source-glyph placement or
edge estimates when available, and the requested representation. It returns a
deterministic `normal`, `large`, or `very_large` classification plus the exact
counts supporting that classification.

For `large` and `very_large` work, the interactive UI explains that editable
host objects may take time on older hardware and offers Continue or Cancel.
Counts are evidence, not promises; an ETA appears only after enough completed
items provide a measured rate.

### 3.2 Progress and cancellation

The controller translates existing pipeline events into a stable progress
snapshot containing stage, page, page total, item/path index, item/path total,
percentage, elapsed seconds, and measured ETA when available. The SketchUp
status bar says that Escape cancels and identifies the current page/item.

Cancellation is cooperative and bounded. A supplied predicate is checked:

- before each page;
- every bounded batch of vector paths;
- before and after external renderer stages;
- before each semantic text item and during large glyph-placement loops; and
- before page certification and commit.

Interactive Windows hosts additionally poll Escape through a small injectable
adapter. Tests inject cancellation deterministically. A dedicated
`ImportCancelled` exception is never swallowed by generic progress-callback
error handling.

### 3.3 Certified page transactions

The existing `run_pipeline` remains the authoritative single-operation renderer.
A resumable orchestrator calls it once per selected page with an internal guard
that prevents recursion. Each invocation therefore owns one SketchUp operation:
success commits one page, while Cancel or failure aborts only that page.

The resumable path requires `Group per page`. Other grouping requests retain the
current atomic single-run behavior and are described as non-resumable rather
than being silently changed.

After a single-page run reports both representation fidelity and import-contract
readiness, the orchestrator identifies the newly created page group and stamps a
checkpoint with:

- resume schema and run ID;
- source PDF SHA-256;
- canonical selected-page set and behavior-option SHA-256;
- importer version and critical-module identity SHA-256;
- package/source-root identity when available;
- source page number, page-session ID, and stable group identity; and
- a deterministic retained-entity signature.

The model stores an append/update journal keyed by the exact run fingerprint.
Completed pages, next page, arrangement offset, and checkpoint identities are
persisted in model attributes and survive a normal model save/reopen.

### 3.4 Honest resume and completion

On a later invocation with the same PDF and options, the orchestrator locates the
journal and independently revalidates every retained group: exact checkpoint
fields, liveness, stable identity, source page, and retained-entity signature.
Only revalidated pages are skipped. Any missing, edited, duplicated, or
mismatched page fails closed and tells the user why.

Cancel returns a structured result with `cancelled=true`, retained page numbers,
and next page. The UI explicitly says which certified pages were kept and that
the same PDF/options/package are required to Resume. Successful completion
produces one aggregate report over all newly completed and revalidated pages and
marks the journal complete.

## 4. Atomic and idempotent release completion

Add a Python release-completion helper with an injectable command runner and use
it from `auto-release.yml`.

For an exact tag/target and local asset manifest, the helper:

1. verifies an existing tag targets the expected commit and never rewrites it;
2. inspects an existing Release and its immutable state;
3. compares every existing expected asset by exact name, size, and SHA-256;
4. uploads only a genuinely absent asset when the Release is mutable, without
   `--clobber` or overwrite semantics;
5. fails on a wrong digest, duplicate expected name, unexpected target, or an
   immutable incomplete Release;
6. creates an absent Release from the existing exact tag and local assets;
7. handles a create race by re-inspecting instead of deleting/retrying blindly;
8. post-verifies the complete Release and emits machine-readable
   `completed`, `changed`, `immutable`, tag, target, URL, and asset digests.

Website dispatch runs only after a newly completed Release. A rerun over an
already complete immutable Release is a successful no-op.

GitHub exposes immutable state after publication; the workflow must verify that
state when available and must never claim completeness from Release-object
existence alone.

## 5. Exact host/package identity

Release-acceptance jobs opt into a strict schema. Required inputs are:

- repository root;
- exact 40-hex git commit and `vX.Y.Z` tag;
- exact RBZ path and SHA-256;
- exact source-tree SHA-256;
- expected SketchUp and Ruby identities;
- requested mode/pages; and
- source PDF SHA-256.

The launcher verifies the tag-to-commit relationship, package bytes, and source
tree before spawning. Release acceptance loads from an isolated source root
staged from the exact RBZ. After load, the batch host records every critical
engine module as `{path, sha256}`; paths must remain under that root and hashes
must equal the pre-spawn manifest. It records the package, commit/tag, host/Ruby,
source tree, and source PDF hashes before and after import.

The launcher and evidence verifier require exact equality across the job,
progress/result JSON, import report, entity manifest, and reopened model evidence.
Legacy developer jobs may omit release identity, but their output is explicitly
`release_acceptance=false` and cannot satisfy the release-acceptance verifier.

## 6. Remaining actionable audit

- The real-host launcher must require a valid Q&A global/SketchUp lease for
  strict release acceptance. Development fakes may inject a lease verifier.
- Existing synthetic fixtures are mapped against rotation, clipping, Type3,
  soft masks, zero ink, inline images, malformed input, and page-2+ behavior.
  Missing cases are generated in test temp directories; no private source file
  is copied into git.
- ACL-protected ignored temporary trees remain an administrator-only hygiene
  item. Product code must not weaken ACLs or attempt broad deletion.
- Inputs that are corrupt, encrypted without usable rights, malicious, or beyond
  available resources still fail truthfully; this is a physical bound, not an
  remaining code task.

## 7. Test-first acceptance

Every behavior change starts with a focused failing test and recorded expected
failure. Required test groups cover:

1. deterministic complexity classification and progress/ETA snapshots;
2. bounded cancel propagation without callback swallowing;
3. current-page rollback and retained certified pages;
4. save/reopen resume and every identity mismatch rejection;
5. aggregate completion without duplicated pages or altered placement;
6. existing-tag absent-release, partial mutable release, complete immutable
   no-op, wrong digest, immutable incomplete, and create-race states;
7. strict package/tag/module/host/source identity and legacy non-acceptance;
8. Ruby 2.2 parsing, six-mode routing/fidelity, deterministic double build,
   full Ruby tests, privacy/package guards, and exact-RBZ host evidence.

A product-byte change requires a new patch version, deterministic RBZ, exact
SketchUp 2017 host run, commit/tag push, green required workflows, immutable
GitHub Release, and independently downloaded digest verification.

## 8. Rejected approaches

- Parser/SVG cache-only restart is not page resume because host construction is
  repeated.
- An all-or-nothing rollback followed by a new import is not called Resume.
- A full timer-driven pipeline state machine is deferred because it rewrites the
  rendering core and adds disproportionate SketchUp 2017 risk.
- Relabeling, weakening, or skipping representation evidence to reduce work is
  prohibited.
