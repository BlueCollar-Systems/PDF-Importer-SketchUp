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

  def test_mesh_text_height_uses_nominal_font_size_only
    body = method_body('mesh_text_height_inches')
    # Must derive from the nominal font size and the fixed point->inch scale.
    assert_includes body, 'effective_font_size_pts',
                    'height must come from nominal font size'
    assert_includes body, 'PDF_POINT_TO_INCH', 'height must use the pt->inch factor'
    # Must NOT read bbox extents in the height path. bbox_* tokens are valid
    # elsewhere in the file (placement/provenance), so these stay
    # method-scoped over the robustly isolated body.
    %w[bbox_x0 bbox_x1 bbox_y0 bbox_y1].each do |forbidden|
      refute_includes body, forbidden,
        "mesh-text height must not use #{forbidden} (bbox-fit masking is forbidden)"
    end
  end

  # RB-10 whole-file scans: these bbox-fit/shim identifiers exist NOWHERE in
  # geometry_builder.rb, so scanning the whole file cannot truncate and any
  # reintroduction anywhere in the builder fails the lock.
  def test_no_bbox_fit_shims_anywhere_in_geometry_builder
    %w[mesh_text_fit_font_size_pts mesh_text_bbox_axes_pts
       calibrate_mesh_text].each do |forbidden|
      refute_includes source, forbidden,
        "#{forbidden} must not exist anywhere in geometry_builder.rb " \
        '(bbox-fit masking is forbidden, SIZE-1)'
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

  # Whole-file: the v3.7.83 face-erase regression identifiers exist nowhere
  # in the builder; any erase path anywhere fails the lock.
  def test_no_face_erase_anywhere_in_geometry_builder
    %w[erase_entities faces_to_erase].each do |forbidden|
      refute_includes source, forbidden,
        "#{forbidden} must not exist anywhere in geometry_builder.rb " \
        '(3D-text glyph faces must never be erased — v3.7.83 regression, FACE-1)'
    end
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
  # fixed tolerance 0.6" only coarsened glyph curves (same size, same faces);
  # tolerance 0.0 is kept for curve quality and the faithful height is passed
  # to add_3d_text directly — generate-then-scale was dropped as redundant.
  #
  # Escape hatch (not a forever freeze): if a future host/API change needs
  # generate-then-scale again, bring live-host measurements + update this
  # guard in the same change — do not "work around" the refute by renaming.
  # Whole-file: neither the 0.6 tolerance call shape nor any
  # Transformation.scaling rescale exists anywhere in the builder.
  def test_no_legacy_tolerance_or_post_scale_anywhere
    refute_match(/add_3d_text\([\s\S]*?,\s*0\.6\s*,/, source,
                 'must not hard-code add_3d_text tolerance 0.6 (R20-1)')
    refute_includes source, 'Transformation.scaling',
                    'no post-generation rescale of glyph geometry (R20-2 panel verdict; ' \
                    'update this guard with evidence if design changes)'
  end

  def test_place_mesh_text_records_height_samples
    body = method_body('place_mesh_text')
    assert_includes body, 'record_mesh_text_height_sample',
                    'faithful target heights must feed the report crosscheck'
  end
end
