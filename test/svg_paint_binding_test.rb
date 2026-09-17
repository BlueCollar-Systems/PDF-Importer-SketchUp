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

  def test_adjacent_svg_rectangles_bind_one_merged_native_stepped_region
    base=rectangle(0,0,10,6); top=rectangle(2,6,8,7)
    merged=[[0,0,0],[10,0,0],[10,6,0],[8,6,0],[8,7,0],[2,7,0],[2,6,0],[0,6,0]]
    glyph=rectangle(3,2,4,4)
    white=source(base,20).merge(:loops=>[base,top])
    native_white=native(merged,[]); before=Marshal.dump(native_white[:loops])
    result=prepare([mask(100)], [native_white], [native(glyph,[1])],
      {:white_paths=>[white], :glyphs=>[source(glyph,30,1)]})
    assert_equal [0,20], result[:masks].first[:paint_order]
    assert_equal before, Marshal.dump(native_white[:loops])
    assert_equal 1, result[:binding][:matched_masks]
  end

  def test_triangulated_native_white_region_has_the_same_filled_boundary
    white=rectangle(0,0,2,2); glyph=rectangle(0.2,0.2,1,1)
    triangles=[native([[0,0,0],[2,0,0],[2,2,0]],[]),native([[0,0,0],[2,2,0],[0,2,0]],[])]
    result=prepare([mask(100)], triangles, [native(glyph,[1])],
      {:white_paths=>[source(white,20)], :glyphs=>[source(glyph,30,1)]})
    assert_equal [0,20], result[:masks].first[:paint_order]
  end

  def test_native_hole_cannot_match_nonzero_source_with_redundant_inner_contour
    outer=rectangle(0,0,4,4); hole=rectangle(1,1,3,3); glyph=rectangle(0.1,0.1,0.8,0.8)
    native_white=Geometry.face_record([outer,hole])
    white=source(outer,20).merge(:loops=>[outer,hole],:fill_rule=>:nonzero)
    assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
      prepare([mask(100)], [native_white], [native(glyph,[1])],
        {:white_paths=>[white], :glyphs=>[source(glyph,30,1)]})
    end
    white[:fill_rule]=:evenodd
    result=prepare([mask(100)], [native_white], [native(glyph,[1])],
      {:white_paths=>[white], :glyphs=>[source(glyph,30,1)]})
    assert_equal [0,20], result[:masks].first[:paint_order]
  end

  def test_small_counter_is_not_erased_by_binding_tolerance
    outer=rectangle(0,0,4,4); hole=rectangle(1,1,1.00001,1.00001); glyph=rectangle(2,2,3,3)
    white=source(outer,20).merge(:loops=>[outer,hole],:fill_rule=>:evenodd)
    assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
      prepare([mask(100)], [native(outer,[])], [native(glyph,[1])],
        {:white_paths=>[white], :glyphs=>[source(glyph,30,1)]})
    end
  end

  def test_oriented_boundary_comparison_rejects_hole_sign_changes
    square=rectangle(0,0,2,2)
    assert Binding.same_region_boundaries?([square],[square],0.0001)
    refute Binding.same_region_boundaries?([square],[square.reverse],0.0001)
  end

  def test_single_retraced_evenodd_contour_does_not_certify_a_filled_face
    square=rectangle(0,0,4,4); glyph=rectangle(1,1,2,2)
    doubled=square + [square.first] + square.drop(1) + [square.first]
    white=source(doubled,20).merge(:fill_rule=>:evenodd)
    assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
      prepare([mask(100)], [native(square,[])], [native(glyph,[1])],
        {:white_paths=>[white], :glyphs=>[source(glyph,30,1)]})
    end
  end
end
