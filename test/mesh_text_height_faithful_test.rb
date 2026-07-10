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

require 'minitest/autorun'

class MeshTextHeightFaithfulTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  GB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                 'bc_pdf_vector_importer', 'geometry_builder.rb')

  def source
    @source ||= File.read(GB)
  end

  def method_body(name)
    body = source[/def #{Regexp.escape(name)}\b.*?^      end/m]
    refute_nil body, "could not isolate ##{name}"
    body
  end

  def test_mesh_text_height_uses_nominal_font_size_only
    body = method_body('mesh_text_height_inches')
    # Must derive from the nominal font size and the fixed point->inch scale.
    assert_includes body, 'effective_font_size_pts',
                    'height must come from nominal font size'
    assert_includes body, 'PDF_POINT_TO_INCH', 'height must use the pt->inch factor'
    # Must NOT read bbox extents or apply a bbox-fit shrink in the height path.
    %w[bbox_x0 bbox_x1 bbox_y0 bbox_y1 mesh_text_fit_font_size_pts
       mesh_text_bbox_axes_pts calibrate_mesh_text].each do |forbidden|
      refute_includes body, forbidden,
        "mesh-text height must not use #{forbidden} (bbox-fit masking is forbidden)"
    end
  end

  def test_effective_font_size_is_the_nominal_value
    body = method_body('effective_font_size_pts')
    assert_includes body, 'item.font_size',
                    'effective_font_size_pts must return the nominal font_size'
    refute_includes body, 'reconcile_font_size_pts',
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
    refute_includes body, 'erase_entities',
                    '3D-text glyph faces must never be erased (v3.7.83 regression)'
    refute_includes body, 'faces_to_erase',
                    '3D-text glyph faces must never be erased (v3.7.83 regression)'
  end
end
