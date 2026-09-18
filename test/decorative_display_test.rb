require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/decorative_display'

class DecorativeDisplayTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::DecorativeDisplay
  Math3 = BlueCollarSystems::PDFVectorImporter::ItemRasterDisplay
  Error = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError

  def row(id, kind, bounds, children = [])
    { :persistent_id=>id, :entity_id=>id+100, :typename=>kind,
      :transformation=>Math3::IDENTITY.dup, :bounds=>bounds,
      :children=>children, :representation_evidence=>{} }
  end

  def setup
    @bounds = { :min=>[0,0,0], :max=>[1,1,0.02] }
    @late = row(3,'Group',@bounds.dup)
    @late[:representation_evidence] = { :source_span_id=>'text_span:1:2', :source_placement_indices=>[2,3] }
    @late[:geometry_evidence] = { :sha256=>'c'*64 }
    @late[:style_evidence] = { :sha256=>'d'*64 }
    @wrapper = row(4,'Group',@bounds.dup,[@late])
    @wrapper[:transformation] = Subject.translation(0.022)
    @wrapper[:decorative_text_wrapper] = true
    @wrapper[:native_child_count] = 1
    @wrapper[:style_evidence] = { :entity_visible=>true,:layer_visible=>true,:material=>nil,:back_material=>nil }
    @earlier = row(5,'Group',@bounds.dup)
    @earlier[:representation_evidence] = { :source_span_id=>'text_span:1:1' }
    @image = row(2,'Image',{:min=>[0,0,0.021],:max=>[1,1,0.021]})
    @image[:transformation] = Subject.translation(0.021)
    @image[:decorative_source_image] = true
    @image[:style_evidence] = { :entity_visible=>true,:layer_visible=>true }
    @image[:content_evidence] = { :display_width=>1.0,:display_height=>1.0,
      :host_texture_export_verified=>true,:host_visual_pixel_sha256=>'b'*64,
      :host_pixel_width=>2,:host_pixel_height=>2 }
    @page = row(1,'Group',@bounds.dup,[@earlier,@image,@wrapper])
    @root_proof = { :id=>'persistent_id:3',:source_span_id=>'text_span:1:2',
      :placement_indices=>[2,3],:source_paint_ranks=>[11,12] }
    @source = { :schema=>'bcs.source_image_paint_order/1.0',:source_svg_sha256=>'e'*64,
      :image_id=>'persistent_id:2',:image_paint_rank=>10,
      :clip_qualification=>{ :policy=>'svg_clip_covers_full_native_affine_footprint' },
      :source_image_event=>{ :kind=>:image,:paint_rank=>10,:alpha=>1.0,
        :corners=>[[0,0],[72,0],[72,72],[0,72]],
        :pixels=>{ :visual_pixel_sha256=>'b'*64,:pixel_width=>2,:pixel_height=>2,:all_opaque=>true } },
      :later_roots=>[@root_proof] }
    @text = { :root_id=>'persistent_id:3', :wrapper_id=>'persistent_id:4',
      :source_span_id=>'text_span:1:2',:placement_indices=>[2,3],
      :canonical_parent=>Math3::IDENTITY.dup,:canonical_transformation=>Math3::IDENTITY.dup,
      :canonical_bounds=>@bounds.dup,:expected_wrapper_transformation=>Subject.translation(0.022),
      :canonical_physical=>{ :physical_geometry_sha256=>'c'*64,:physical_style_sha256=>'d'*64 } }
    @placement = { :image_id=>'persistent_id:2',:corners_pdf=>[[0,0],[72,0],[72,72],[0,72]],
      :canonical_transformation=>Math3::IDENTITY.dup,:expected_display_transformation=>Subject.translation(0.021),
      :source_proof=>@source,:later_text=>[@text] }
    @proof = { :schema=>Subject::SCHEMA,:policy=>Subject::POLICY,:display_gap_inches=>0.001,
      :page_group_id=>'persistent_id:1',:page=>1,:source_pdf_sha256=>'a'*64,:source_svg_sha256=>'e'*64,
      :media_box=>[0,0,72,72],:scale=>1.0,:page_y_offset=>0.0,:page_rotation=>0,
      :svg_page_box=>[0,0,72,72],:svg_viewbox=>[0,0,72,72],
      :canonical_text_top=>0.02,:image_display_z=>0.021,:placements=>[@placement] }
    @stats = { :normalized_input_sha256=>'a'*64,:decorative_display_placements=>[@proof] }
  end

  def verify; Subject.verify_manifest!(@stats,[@page]); end
  def rejects; assert_raises(Error) { verify }; end

  def add_final_crop
    sid = 'text_span:1:9'
    @crop_artifact = { :source_span_id=>sid,:page_number=>1,:page_rotation=>0,
      :source_pdf_sha256=>'a'*64,:source_box=>[0,0,72,72],
      :visual_pixel_sha256=>'f'*64,:page_render_content_sha256=>'1'*64,
      :pixel_width=>10,:pixel_height=>10 }
    [:source_crop_binding_verified,:source_pdf_binding_verified,:page_binding_verified,
      :alpha_channel_verified,:transparent_background_verified,:visible_pixel_verified,
      :page_render_once_verified,:visual_pixel_binding_verified].each { |k| @crop_artifact[k] = true }
    @stats[:raster_delivery_records] = [{ :page=>1,:delivery_scope=>:item_raster,
      :source_span_ids=>[sid],:resulting_entity_ids=>['persistent_id:9'],:artifact_evidence=>@crop_artifact }]
    @crop = { :source_span_id=>sid,:resulting_entity_id=>'persistent_id:9',
      :source_box=>[0,0,72,72],:bounds_svg=>[0,0,72,72],:page_number=>1,
      :source_pdf_sha256=>'a'*64,:placement_index=>9,:paint_rank=>15,:glyph_bounds_svg=>[10,10,20,20] }
    @source[:later_final_page_crops] = [@crop]
    @crop_image = row(9,'Image',{:min=>[0,0,0.043],:max=>[1,1,0.043]})
    @crop_image[:transformation] = Subject.translation(0.043)
    @crop_image[:representation_evidence] = { :source_span_id=>sid }
    @crop_image[:style_evidence] = { :entity_visible=>true,:layer_visible=>true }
    @crop_image[:content_evidence] = { :raster_source_pdf_sha256=>'a'*64,:raster_page_number=>1,
      :host_texture_export_verified=>true,:host_visual_pixel_sha256=>'f'*64,
      :host_pixel_width=>10,:host_pixel_height=>10,:display_width=>1.0,:display_height=>1.0 }
    @page[:children] << @crop_image
  end

  def test_final_page_crop_witness_binds_saved_source_pixels_without_glyph_ownership
    add_final_crop
    assert verify
    assert Subject.verify_manifest!(JSON.parse(JSON.generate(@stats)),JSON.parse(JSON.generate([@page])))
    assert_nil @crop_image[:representation_evidence][:source_placement_indices]
  end

  def test_rejects_final_crop_coplanar_with_embedded_image
    add_final_crop
    @crop_image[:transformation][14] = 0.021
    rejects
  end

  def test_rejects_final_crop_wrong_source_or_saved_pixels
    add_final_crop
    @crop_artifact[:source_pdf_sha256] = '9'*64
    rejects
    @crop_artifact[:source_pdf_sha256] = 'a'*64
    @crop_image[:content_evidence][:host_visual_pixel_sha256] = '9'*64
    rejects
  end

  def test_rejects_unbound_or_partial_final_crop_coverage
    add_final_crop
    @crop[:glyph_bounds_svg][2] = 73
    rejects
    @crop[:glyph_bounds_svg][2] = 20
    @crop[:source_box] = [0,0,71,72]
    rejects
  end

  def test_rejects_final_crop_repeating_native_source_owner
    add_final_crop
    @crop[:placement_index] = 2
    rejects
  end

  def test_rejects_final_crop_shift_or_missing_physical_image
    add_final_crop
    @crop_image[:transformation][12] = 0.01
    rejects
    @page[:children].delete(@crop_image)
    rejects
  end

  def test_accepts_source_bound_image_and_later_original_text_after_json_roundtrip
    assert verify
    assert Subject.verify_manifest!(JSON.parse(JSON.generate(@stats)),JSON.parse(JSON.generate([@page])))
  end
  def test_rejects_native_image_xy_shift
    @image[:transformation][12] = 0.02
    rejects
  end
  def test_rejects_pixels_changed_despite_same_placement
    @image[:content_evidence][:host_visual_pixel_sha256] = 'f'*64
    rejects
  end
  def test_rejects_unexported_texture_claim
    @image[:content_evidence][:host_texture_export_verified] = false
    rejects
  end
  def test_rejects_source_image_without_opaque_pixel_proof
    @source[:source_image_event][:pixels][:all_opaque] = false
    rejects
  end
  def test_rejects_native_wrapper_tilt
    @wrapper[:transformation][2] = 0.01
    rejects
  end
  def test_rejects_native_wrapper_xy_shift_even_if_ledger_repeats_it
    @wrapper[:transformation][12] = @text[:expected_wrapper_transformation][12] = 0.01
    rejects
  end
  def test_rejects_native_wrapper_wrong_depth_even_if_ledger_repeats_it
    @wrapper[:transformation][14] = @text[:expected_wrapper_transformation][14] = 0.03
    rejects
  end
  def test_rejects_changed_canonical_child_geometry
    @late[:geometry_evidence][:sha256] = 'f'*64
    rejects
  end
  def test_rejects_changed_canonical_child_style
    @late[:style_evidence][:sha256] = 'f'*64
    rejects
  end
  def test_rejects_changed_actual_source_indices
    @late[:representation_evidence][:source_placement_indices] = [12,13]
    rejects
  end
  def test_rejects_hidden_wrapper
    @wrapper[:style_evidence][:entity_visible] = false
    rejects
  end
  def test_rejects_hidden_image_layer
    @image[:style_evidence][:layer_visible] = false
    rejects
  end
  def test_rejects_inherited_wrapper_material
    @wrapper[:style_evidence][:material] = { :color=>[1,0,0] }
    rejects
  end
  def test_rejects_source_image_xy_change_repeated_in_native_and_canonical_record
    @image[:transformation][12] = @placement[:canonical_transformation][12] =
      @placement[:expected_display_transformation][12] = 1
    @placement[:corners_pdf] = @placement[:corners_pdf].map { |p| [p[0]+72,p[1]] }
    rejects
  end
  def test_rejects_changed_canonical_child_transform
    @late[:transformation][0] = 1.1
    rejects
  end
  def test_rejects_unclaimed_native_child_hidden_by_compact_snapshot
    @wrapper[:native_child_count] = 2
    rejects
  end
  def test_rejects_source_root_straddling_image_order
    @root_proof[:source_paint_ranks] = [9,12]
    rejects
  end
  def test_rejects_duplicated_later_source_root
    @source[:later_roots] << @root_proof
    rejects
  end
  def test_rejects_negative_source_placement_index
    @root_proof[:placement_indices] = [-1,3]
    rejects
  end
  def test_rejects_missing_source_owner
    @placement[:later_text] = []
    rejects
  end
  def test_rejects_missing_display_ledger
    @stats.delete(:decorative_display_placements)
    rejects
  end
  def test_rejects_missing_page_proof
    @stats[:decorative_display_placements] = []
    rejects
  end
  def test_rejects_duplicate_page_proof
    @stats[:decorative_display_placements] << @proof
    rejects
  end
  def test_rejects_wrong_source_digest
    @stats[:normalized_input_sha256] = 'f'*64
    rejects
  end
  def test_rejects_narrow_renderer_clip_with_no_original_pdf_proof
    @source[:source_image_event][:clip_bounds] = [1,0,71,72]
    rejects
  end
  def test_original_pdf_clip_proof_survives_saved_json_and_binds_actual_asset
    @source[:source_image_event][:clip_bounds] = [1,0,71,72]
    @placement.merge!(:image_object_number=>7,:placement_index=>1,:ctm=>[72,0,0,72,0,0])
    @source[:clip_qualification] = { :policy=>'original_pdf_full_affine_clip_coverage',
      :cairo_clip_bounds=>[1,0,71,72], :original_clip_proof=>{
        :schema=>'bcs.original_image_clip/1',:status=>'FULL_FOOTPRINT',:parsed_pdf_sha256=>'a'*64,
        :page_number=>1,:image_object_number=>7,:placement_index=>1,:ctm=>[72,0,0,72,0,0],
        :corners_pts=>@placement[:corners_pdf].map(&:dup),:unproven_reasons=>[],
        :clip_polygons_pts=>['media_box','crop_box'].map { |k| { :kind=>k,:corners_pts=>[[0,0],[72,0],[72,72],[0,72]] } },
        :source_streams=>[{ :kind=>'page',:index=>0,:sha256=>'f'*64 }],:form_chain=>[] } }
    assert verify
    assert Subject.verify_manifest!(JSON.parse(JSON.generate(@stats)),JSON.parse(JSON.generate([@page])))
    @source[:clip_qualification][:original_clip_proof][:image_object_number] = 8
    rejects
  end
  def test_rejects_qualified_image_with_no_ledger_or_native_marker
    @stats[:embedded_image_paint_order] = [{ :page=>1,:qualified_count=>1 }]
    @stats[:decorative_display_placements] = []
    @image.delete(:decorative_source_image)
    @wrapper.delete(:decorative_text_wrapper)
    rejects
  end
  def test_reflected_sheared_original_image_keeps_full_affine
    corners = [[72,0],[0,0],[18,72],[90,72]]
    @placement[:corners_pdf] = corners
    @source[:source_image_event][:corners] = [3,2,1,0].map { |i| [corners[i][0],72-corners[i][1]] }
    canonical = BlueCollarSystems::PDFVectorImporter::EmbeddedImagePlacement.affine(corners,[0,0,72,72],1.0,0.0,0)[:matrix]
    @placement[:canonical_transformation] = canonical
    @placement[:expected_display_transformation] = Math3.multiply(Subject.translation(0.021),canonical)
    @image[:transformation] = @placement[:expected_display_transformation].dup
    @image[:content_evidence][:display_height] = Math.sqrt(1+0.25**2)
    assert verify
  end
  def test_image_before_all_later_marks_needs_no_text_wrapper
    @source[:later_roots] = []
    @placement[:later_text] = []
    @page[:children].delete(@wrapper)
    assert verify
  end
end
