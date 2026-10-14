These PDFs and embedded TrueType fonts are public fictional test assets.
They contain no user's drawing, extracted proprietary font, or CAD model data.
Regenerate them with `python tools/build_source_zero_ink_fixtures.py` (FontTools).
The deterministic PDF/program hashes and fictional Base64 PDF bytes are recorded
in `CONTROLS.json`. Ruby tests verify the hashes and materialize these controls
in their own temporary directory. Raw PDF output stays ignored under the corpus
containment policy; no FontTools runtime is needed to run the Ruby tests.

- `empty-space-over-neighboring-ink.pdf`: four empty original space glyphs overlap
  a red vector rectangle. A page crop contains red ink, but those pixels do not
  belong to the blank text. Preserve the text/layout ledger without an image.
- `visible-space-must-retain-ink.pdf`: the same decoded spaces/layout reference
  four original black rectangle glyphs. Preserve all four visible glyphs as
  source 3D text with positive depth. Whitespace alone cannot discard them.
- `blank-only-page.pdf`: four empty space glyphs and no visible page content.
  A hidden, nonpainting page carrier must retain the semantic ledger on save.
- `raw-code-09-space.pdf`: source code 09 decodes to a space while the original
  explicitly Symbolic (`Flags 4`) font's MacRoman format 6 and Windows Symbol
  format 4 cmaps agree on its empty GID.
  Looking up Unicode 20 in the font cmap cannot authenticate this source code.
- `nonsymbolic-conflicting-cmap.pdf`: direct Mac/symbol tables appear empty but
  the font is Nonsymbolic and a Unicode table has visible ink for that code.
  Direct symbolic mapping must be rejected for this font.
- `conflicting-font-flags.pdf` and `missing-font-flags.pdf`: ambiguous font
  classification cannot positively establish the glyph selection route.
- `winansi-visible-euro-tounicode-space.pdf`: source byte 80 selects a visible
  WinAnsi Euro glyph while ToUnicode reports a space and Unicode 0080 is empty.
  Looking up the raw byte as Unicode would discard the visible glyph.
- `encoding-differences-visible-A.pdf`: a Differences override maps byte 32 to
  the visible /A glyph, despite ToUnicode space and an empty base space glyph.
  The bounded zero-ink route must reject this encoding dictionary.
- `symbolic-named-winansi-visible-A.pdf`: the Symbolic flag overrides a named
  WinAnsi encoding. Actual symbol tables select visible /A while Unicode space
  is empty; the zero-ink route cannot certify the Unicode lookup.
- `ambiguous-symbol-prefixes.pdf`: a malformed symbol table mixes F0 and F1
  mappings with different ink. A guessed prefix cannot establish ownership.

Unit tests do not establish native SketchUp save/reopen or visual parity.
