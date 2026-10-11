# Text placement and scale workflow review - 2026-10-10

## Implemented changes

External text now matches nominal source font sizes and angles in original PDF
coordinates. Page rotation and crop offsets are applied before matching, which
prevents a nearby item in the displayed frame from supplying the wrong size.
Verified nominal sizes are preserved, including text smaller than one point.
Requested text representations and their fallback rules are unchanged.

Import dialogs reject malformed, zero, negative, non-finite and overflowing
scale inputs. Legacy units conversion is validated again so multiplying by feet
cannot create infinity or dividing by points create zero. HTML submissions
validate before saving preferences.

Selection Only scaling now handles native edges and faces through one
`Entities#transform_entities` operation, rather than calling a nonexistent
`transform!` method on raw geometry. Its anchor is converted through the current
editing transform, and reference edge measurement includes parent scaling.
Loose drawings can also be scaled when there are no groups. Host transform
errors abort the opened operation and explain the failure.

The active-context coordinate behavior follows the official
[Entities transformation documentation](https://ruby.sketchup.com/Sketchup/Entities.html#transform_entities-instance_method)
and the measurement behavior follows
[Edge length](https://ruby.sketchup.com/Sketchup/Edge.html#length-instance_method).

## Validation and limits

- The complete current-Ruby diagnostic sweep ran **172 test files**. Its
  Minitest portions contained 2,214 runs and 19,717 assertions, with eight skips.
  One resume test rejected source edits made during that test. Its settled-source
  rerun passed all **16 tests and 65 assertions**. Other files include independent
  smoke/tokenizer/placement assertions and optional private-corpus gates.
- Final changed-workflow cases passed: **37 dialog tests, 6 scale tests,
  3 nominal-frame tests, 5 fragmented-text tests, 8 rotation tests**, and the
  existing 27 angle-hint assertions.
- Both Ruby 2.2 compatibility scanners and whitespace checks passed.
- The exact standalone Ruby 2.2.4 executable is missing on this machine, so the
  normal exact-parser suite launcher could not run. Current diagnostic tests
  used Ruby 3.4. A separate SketchUp 2017 startup probe did not expose a usable
  window or produce evidence; its owned process and leases were cleaned up.
  No fresh native SketchUp 2017 or current-Pro acceptance is claimed.

These are source checkout changes. Existing installed extensions and released
RBZ files are unchanged. Broad legacy/future host compatibility, complete
side-by-side visual parity and automated 2D-to-3D reconstruction remain separate
acceptance work.
