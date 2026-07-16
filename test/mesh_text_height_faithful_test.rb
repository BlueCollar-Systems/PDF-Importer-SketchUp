#!/usr/bin/env ruby
# test/mesh_text_height_faithful_test.rb
#
# Owner field bug (2026-07-06): imported 3D text looked "super tiny."
# Root cause (fixed v3.7.82/83): the mesh-text height was derived from the
# pdftotext GLYPH BBOX, which for digit-only dimension text is ~0.7x the em
# and blew up on stacked/rotated text. The Round 13 contract requires text
# height to come from the NOMINAL font size (font_size_pts / 72 * scale),
# so the import reproduces the PDF faithfully at equal zoom.
#
# This guard fails if any session reintroduces bbox-derived height or a
# bbox-fit shrink into the mesh-text height path.
#
# RB-10 (2026-07-12 roadblock audit): the old method-body extraction anchored
# on a hard-coded 6-space "end" indentation; a re-indent/re-nest could make it
# silently truncate and hide forbidden tokens. Rebuilt so that:
#   * forbidden tokens that exist NOWHERE in geometry_builder.rb are asserted
#     with WHOLE-FILE scans (a whole-file refute cannot truncate);
#   * tokens that legitimately appear elsewhere in the file (bbox_* are valid
#     placement/provenance inputs) stay method-scoped, but extraction is
#     indentation-RELATIVE (the def's own indent) and fails LOUDLY when the
#     method cannot be isolated, instead of silently matching a fragment.
# The token list is unchanged — nothing was weakened. The Ruby 2.2 Docker
# VALUE suite remains the primary behavioral lock (R20-2).

require 'minitest/autorun'

class MeshTextHeightFaithfulTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  GB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                 'bc_pdf_vector_importer', 'geometry_builder.rb')

  def source
    @source ||= File.read(GB)
  end

  # Indentation-relative method extraction: capture the def line's own indent
  # and require the closing "end" at that same indent. In valid Ruby no inner
  # "end" can sit at the def's own column before the method's own end, so this
  # either isolates the FULL method or returns nil (which fails loudly below).
  def method_body(name)
    body = source[/^([ \t]*)def #{Regexp.escape(name)}\b.*?^\1end\b/m]
    refute_nil body, "could not isolate ##{name}"
    body
  end

  def test_mesh_text_vertical_metric_uses_nominal_em_and_selected_font_ratio
    em_body = method_body('mesh_text_pdf_em_height_inches')
    height_body = method_body('mesh_text_height_inches')
    profile_body = method_body('mesh_text_font_profile')

    assert_includes em_body, 'effective_font_size_pts',
                    'PDF em height must come from nominal font size'
    assert_includes em_body, 'PDF_POINT_TO_INCH',
                    'PDF em height must use the pt->inch factor'
    assert_includes height_body, 'mesh_text_pdf_em_height_inches',
                    'vertical size must begin with the canonical PDF em height'
    assert_includes height_body, 'letter_height_ratio',
                    'vertical size must use the selected SketchUp font metric'

    # Bboxes may be used by Task 4 for safe local-X fitting, but they must never
    # select PDF em height, vertical letter height, or the font metric ratio.
    %w[bbox_x0 bbox_x1 bbox_y0 bbox_y1].each do |forbidden|
      [em_body, height_body, profile_body].each do |body|
        refute_includes body, forbidden,
          "vertical-size and ratio selection must not use #{forbidden}"
      end
    end
  end

  def test_effective_font_size_is_the_nominal_value
    body = method_body('effective_font_size_pts')
    assert_includes body, 'item.font_size',
                    'effective_font_size_pts must return the nominal font_size'
    %w[bbox_x0 bbox_x1 bbox_y0 bbox_y1].each do |forbidden|
      refute_includes body, forbidden,
        "nominal size must not read #{forbidden} (bbox reconciliation is forbidden)"
    end
  end

  # Whole-file: render-time bbox reconciliation of the nominal size was
  # removed and must never return anywhere in the builder.
  def test_no_render_time_font_size_reconciliation_anywhere
    refute_includes source, 'reconcile_font_size_pts',
                    'nominal size must not be bbox-reconciled at render time'
  end

  # Owner field bug (2026-07-10, second report): v3.7.83..v3.7.85 shipped
  # correctly SIZED 3D text whose glyph FACES were erased right after
  # add_3d_text, so imports showed hairline outlines that read as
  # "microscopic dashes" at sheet zoom. Source-level lock: the 3D-text
  # placement path must keep and paint its faces, never erase them.
  def test_place_mesh_text_retains_glyph_faces
    body = method_body('place_mesh_text')
    assert_includes body, 'apply_text_face_material',
                    '3D-text faces must be painted, proving they are retained'
  end

  # Round 20 (R20-2): the v3.7.81–3.7.89 field bug — Numeric#clamp (Ruby 2.4+)
  # raised NoMethodError on the SketchUp Make 2017 host (Ruby 2.2.4), the
  # rescue swallowed it, and every 3D text item shipped at the 0.01" floor.
  # Whole-file: no .clamp call anywhere in the builder (RB22 checker enforces
  # the rest of the extension).
  def test_geometry_builder_has_no_clamp_calls
    refute_match(/\.\s*clamp\b/, source,
                 'Numeric#clamp does not exist on SketchUp Make 2017 Ruby 2.2 (R20-2)')
  end

  # Round 20 (R20-1 quality, panel-verified): live-host probes showed the old
  # fixed tolerance 0.6" only coarsened glyph curves. Tolerance 0.0 remains the
  # quality contract; Task 4 is allowed to apply a safe local-X-only transform.
  def test_no_legacy_tolerance_anywhere
    refute_match(/add_3d_text\([\s\S]*?,\s*0\.6\s*,/, source,
                 'must not hard-code add_3d_text tolerance 0.6 (R20-1)')
  end

  def test_place_mesh_text_records_height_samples
    body = method_body('place_mesh_text')
    assert_includes body, 'record_mesh_text_height_sample',
                    'faithful target heights must feed the report crosscheck'
  end
end
