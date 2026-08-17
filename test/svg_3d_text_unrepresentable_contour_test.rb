#!/usr/bin/env ruby
# test/svg_3d_text_unrepresentable_contour_test.rb
#
# Second root cause on tracemonkey spans 10:80/10:82 (found by Cascade after the
# whitespace fix): safe_construction_scale raised 'source contour has coincident
# vertices that scaling cannot separate' -- the span's own glyph outline holds vertices
# closer than the host merge tolerance at every construction scale up to the max, so
# SketchUp physically cannot build the face. That is a deterministic, item-specific fact
# about the source geometry: an AFFIRMATIVE impossibility, text3d -> glyphs.
#
# Hardening on top of the original fix: the raise is now a typed
# UnrepresentableSourceContour and the render loop classifies on the CLASS, not a
# message substring. Matching message text is how host_3d_text_exception became a
# catch-all in the first place; a reworded raise would silently revert to a STOP.
require 'minitest/autorun'

# scaled_contour builds Geom::Point3d (SketchUp host class). A minimal stand-in lets
# the REAL safe_construction_scale raise path run outside the host, the way this
# repo's other host-free tests stub UI. Only defined if the host has not defined it.
unless defined?(Geom)
  module Geom
    class Point3d
      attr_reader :x, :y, :z
      def initialize(x = 0.0, y = 0.0, z = 0.0)
        @x = x.to_f; @y = y.to_f; @z = z.to_f
      end
    end
  end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer'

class Svg3DTextUnrepresentableContourTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  RF = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
  Item = Struct.new(:text, :source_span_id)

  def build_proof
    R.unrepresentable_as_3d_text_proof(
      'text_span:10:80', Item.new('x', 'text_span:10:80'), 0.015625,
      { renderer: 'poppler' }, 'source contour has coincident vertices that scaling cannot separate'
    )
  end

  def test_error_is_typed_and_a_runtime_error
    assert R::UnrepresentableSourceContour < RuntimeError
  end

  def test_reason_code_is_approved_affirmative_not_stop
    assert_includes RF::AFFIRMATIVE_REASON_CODES, :source_item_unrepresentable_as_3d_text
    refute_includes RF::STOP_REASON_CODES, :source_item_unrepresentable_as_3d_text
  end

  def test_proof_shape_is_affirmative_item_scoped_one_rung
    p = build_proof
    assert_equal true, p[:affirmative_impossibility]
    assert_equal false, p[:generic_failure]
    assert_equal :item, p[:scope]
    assert_equal :text3d, p[:from_mode]
    assert_equal :glyphs, p[:to_mode]
    assert_equal :source_item_unrepresentable_as_3d_text, p[:reason_code]
    assert_equal [], p[:created_entity_ids]
    assert_equal :not_required, p[:cleanup_outcome]
    assert_match(/coincident vertices/, p[:evidence][:host_error])
  end

  def test_fallback_controller_accepts_the_proof
    # The sole authority that may advance the ladder, with a strict validator.
    c = RF::FallbackController.new(:text3d, 'text_span:10:80')
    c.advance!(build_proof)
    assert_equal :glyphs, c.current_mode
  end

  def test_safe_construction_scale_raises_the_typed_error_on_inseparable_points
    # Two loops whose points coincide exactly: no scale can separate them.
    # Pass an explicit origin so the test does not need SketchUp's Geom::Point3d for
    # construction_origin_for; the scale loop itself only reads .x/.y.
    pt = Struct.new(:x, :y, :z)
    origin = pt.new(0.0, 0.0, 0.0)
    # normalized_contour merges ADJACENT duplicates, so the inseparable case is a
    # contour that revisits a vertex non-adjacently (a self-touching figure-eight):
    # (0,0) -> (1,0) -> (1,1) -> (0,0) -> (-1,0) -> (-1,-1). The two (0,0)s survive
    # normalization, have zero distance, and no finite scale can separate zero -- so
    # every scale up to the max fails and the typed error must fire.
    same = [pt.new(0.0, 0.0, 0.0), pt.new(1.0, 0.0, 0.0), pt.new(1.0, 1.0, 0.0),
            pt.new(0.0, 0.0, 0.0), pt.new(-1.0, 0.0, 0.0), pt.new(-1.0, -1.0, 0.0)]
    entries = [{ loops: [same] }]
    err = assert_raises(R::UnrepresentableSourceContour) do
      R.safe_construction_scale(entries, origin)
    end
    assert_match(/coincident vertices/, err.message)
  end

  def test_a_generic_runtime_error_is_still_a_hard_failure_not_a_transition
    # The classification must key on the CLASS. A plain RuntimeError with unrelated
    # text stays a STOP-class hard failure -- the ladder must not widen by accident.
    e = RuntimeError.new('some other host failure')
    refute e.is_a?(R::UnrepresentableSourceContour)
    assert_equal :host_3d_text_exception, R.classify_host_failure(e)
  end
end
