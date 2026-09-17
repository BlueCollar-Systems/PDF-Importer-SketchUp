require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_paint_binding'

class SvgPaintBindingTest < Minitest::Test
  Binding = BlueCollarSystems::PDFVectorImporter::SvgPaintBinding
  Geometry = BlueCollarSystems::PDFVectorImporter::PlanarWhiteKnockout
  def rectangle(x0, y0, x1, y1)
    [[x0,y0,0.0], [x1,y0,0.0], [x1,y1,0.0], [x0,y1,0.0]]
  end
  def native(loop, indices)
    result = Geometry.face_record([loop])
    result[:source_placement_indices] = indices
    result[:source_span_id] = 'span1'
    result
  end
  def source(loop, order, index = nil)
    { :loops => [loop], :paint_order => [0,order], :placement_index => index,
      :svg_document_offset => order, :fill_opacity => 1.0, :fill_rule => :nonzero }
  end
  def mask(order)
    { :group => Object.new, :transformation => Object.new, :fill_rgb => [1.0,1.0,1.0],
      :opacity => 1.0, :paint_order => [0,order] }
  end
  def prepare(masks, native_white, ink, inventory)
    Geometry.stub(:collect_text_faces, ink) do
      Geometry.stub(:snapshots, native_white) do
        Binding.prepare(masks, [], inventory)
      end
    end
  end

  def test_interleaved_masks_use_glyph_order_instead_of_one_merged_span_order
    white = rectangle(0,0,4,2)
    first = rectangle(0.2,0.2,1,1.8); second = rectangle(2.2,0.2,3,1.8)
    result = prepare([mask(900)], [native(white,[])], [native(first,[1]),native(second,[2])],
      { :white_paths => [source(white,20)], :glyphs => [source(first,10,1),source(second,30,2)] })
    assert_equal [0,20], result[:masks][0][:paint_order]
    assert_equal [[0,10],[0,30]], result[:ink_faces].map { |face| face[:paint_order] }
    refute Geometry.earlier_mask?(result[:masks][0], result[:ink_faces][0])
    assert Geometry.earlier_mask?(result[:masks][0], result[:ink_faces][1])
  end

  def test_duplicate_source_masks_are_bound_by_complete_occurrence_order
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    result=prepare([mask(200),mask(100)], [native(white,[])], [native(glyph,[1])],
      { :white_paths => [source(white,10),source(white,30)], :glyphs => [source(glyph,20,1)] })
    assert_equal [[0,30],[0,10]], result[:masks].map { |m| m[:paint_order] }
  end

  def test_missing_or_ambiguous_mask_occurrence_fails_when_it_overlaps_text
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
      prepare([mask(100)], [native(white,[])], [native(glyph,[1])],
        { :white_paths => [source(white,10),source(white,30)], :glyphs => [source(glyph,20,1)] })
    end
  end

  def test_exact_native_glyph_indices_prevent_neighbor_order_theft
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    result=prepare([mask(100)], [native(white,[])], [native(glyph,[2])],
      { :white_paths => [source(white,10)], :glyphs => [source(glyph,5,1),source(glyph,20,2)] })
    assert_equal [0,20], result[:ink_faces][0][:paint_order]
  end

  def test_binding_tolerance_never_moves_native_geometry
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    rounded=white.map { |point| [point[0]+0.00002,point[1],point[2]] }
    ink=native(glyph,[1]); before=Marshal.dump(ink[:loops])
    result=prepare([mask(100)], [native(white,[])], [ink],
      { :white_paths => [source(rounded,10)], :glyphs => [source(glyph,20,1)] })
    assert_equal before, Marshal.dump(result[:ink_faces][0][:loops])
  end

  def test_glyph_hole_is_not_mistaken_for_ink
    outer=rectangle(0,0,3,3); hole=rectangle(1,1,2,2).reverse
    glyph=Binding.geometry_record({ :loops => [outer,hole] })
    refute Binding.face_within_glyph?(native(rectangle(1.2,1.2,1.8,1.8),[]),glyph,0.0001)
    assert Binding.face_within_glyph?(native(rectangle(0.2,0.2,0.8,0.8),[]),glyph,0.0001)
  end

  def test_source_indices_are_required_even_when_an_unrelated_face_fits_a_glyph
    white=rectangle(0,0,3,3); glyph=rectangle(0.2,0.2,2.8,2.8)
    [[], ['1'], [nil], [-1]].each do |indices|
      assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
        prepare([mask(100)], [native(white,[])], [native(rectangle(1,1,2,2),indices)],
          { :white_paths => [source(white,10)], :glyphs => [source(glyph,20,1)] })
      end
    end
  end

  def test_every_identical_opaque_repaint_index_binds_to_its_effective_order
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    repaint=source(glyph,30,1).merge(:placement_indices => [1,7])
    result=prepare([mask(100)], [native(white,[])], [native(glyph,[7])],
      { :white_paths => [source(white,20)], :glyphs => [repaint] })
    assert_equal [0,30], result[:ink_faces].first[:paint_order]
  end

  def test_translucent_or_unknown_source_ink_cannot_knock_out_opaque_white
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    [0.3, nil].each do |alpha|
      painted=source(glyph,30,1).merge(:fill_opacity => alpha)
      assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
        prepare([mask(100)], [native(white,[])], [native(glyph,[1])],
          { :white_paths => [source(white,20)], :glyphs => [painted] })
      end
    end
  end

  def test_evenodd_hole_uses_parity_even_when_both_contours_have_same_winding
    outer=rectangle(0,0,3,3); hole=rectangle(1,1,2,2)
    glyph=Binding.geometry_record({ :loops => [outer,hole], :fill_rule => :evenodd })
    inside_hole=native(rectangle(1.2,1.2,1.8,1.8),[])
    refute Binding.face_within_glyph?(inside_hole,glyph,0.0001)
    glyph[:fill_rule]=:nonzero
    assert Binding.face_within_glyph?(inside_hole,glyph,0.0001)
  end

  def test_verified_final_crop_has_an_explicit_separate_identity_proof
    white=rectangle(0,0,2,2); crop=native(rectangle(0.2,0.2,1,1),[])
    crop[:final_page_crop]=true
    result=prepare([mask(100)], [native(white,[])], [crop],
      { :white_paths => [source(white,20)], :glyphs => [] })
    assert_equal [1,0], result[:ink_faces].first[:paint_order]
    assert_equal 'verified_same_page_final_crops', result[:masks].first[:order_proof]
  end

  def test_equal_pdf_mask_orders_do_not_guess_duplicate_occurrences
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
      prepare([mask(100),mask(100)], [native(white,[])], [native(glyph,[1])],
        { :white_paths => [source(white,10),source(white,30)], :glyphs => [source(glyph,20,1)] })
    end
  end
end
