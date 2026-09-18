require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/source_image_paint_order'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class SourceImagePaintOrderTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Subject = Importer::SourceImagePaintOrder
  DIGEST = 'a' * 64
  PIXELS = { :pixel_width=>2, :pixel_height=>2, :visual_pixel_sha256=>DIGEST, :all_white_opaque=>false, :all_opaque=>true }.freeze
  IMAGE_DEF = '<image id="pic" width="2" height="2" xlink:href="data:image/png;base64,AA=="/>'.freeze
  GLYPH_DEF = '<g id="glyph-0-0"><path d="M 0 0 L 2 0 L 2 2 L 0 2 Z"/></g>'.freeze
  IMAGE_USE = '<use xlink:href="#pic" transform="matrix(5,0,0,5,10,10)"/>'.freeze
  CROSSING = '<path fill="none" stroke="black" stroke-width="1" d="M 5 15 L 25 15"/>'.freeze
  GLYPH = '<use xlink:href="#glyph-0-0" x="12" y="12"/>'.freeze

  def document(content, defs = IMAGE_DEF + GLYPH_DEF)
    '<svg width="100pt" height="100pt" viewBox="0 0 100 100"><defs>' + defs + '</defs>' + content + '</svg>'
  end

  def image
    PIXELS.merge(:id=>'image-1', :corners_svg=>[[10,10],[20,10],[20,20],[10,20]])
  end

  def inventory(svg)
    Subject::Inventory.new(svg, lambda { |_uri| PIXELS.dup })
  end

  def crop_image_binding
    image.merge(:page_number=>1, :parsed_pdf_sha256=>DIGEST,
      :svg_page_box=>[0,0,100,100], :svg_viewbox=>[0,0,100,100])
  end

  def final_crop(box = [12,86,14,88])
    { :source_span_id=>'text_span:1:4', :resulting_entity_id=>'persistent_id:45',
      :page_number=>1, :source_pdf_sha256=>DIGEST, :source_box=>box,
      :bounds_svg=>[box[0],100-box[3],box[2],100-box[1]] }
  end

  def test_later_glyph_can_use_complete_final_page_crop_without_native_wrapper_or_fake_indices
    crop = final_crop
    before = Marshal.dump(crop)
    plan = inventory(document(IMAGE_USE+GLYPH)).qualify(crop_image_binding,[],[crop])
    assert_empty plan[:later_roots]
    assert_equal 1, plan[:later_overlapping_paint_count]
    row = plan[:later_final_page_crops].fetch(0)
    assert_equal 'persistent_id:45', row[:resulting_entity_id]
    assert_equal 'text_span:1:4', row[:source_span_id]
    assert_equal [12,12,14,14], row[:glyph_bounds_svg]
    assert_equal 0, row[:placement_index]
    assert_operator row[:paint_rank], :>, plan[:image_paint_rank]
    refute row.key?(:placement_indices)
    assert_equal before, Marshal.dump(crop)
  end

  def test_partial_crop_or_wrong_source_binding_never_qualifies_later_ink
    subject = inventory(document(IMAGE_USE+GLYPH))
    [final_crop([12,86,13.999,88]), final_crop.merge(:page_number=>2),
      final_crop.merge(:source_pdf_sha256=>'b'*64), final_crop.merge(:resulting_entity_id=>'claimed'),
      final_crop.merge(:bounds_svg=>[0,0,100,100]), final_crop.merge(:source_box=>[12,86,Float::NAN,88])].each do |crop|
      assert_raises(Subject::Unproven) { subject.qualify(crop_image_binding,[],[crop]) }
    end
  end

  def test_curve_control_bounds_must_fit_and_vectors_cannot_borrow_raster_coverage
    curve = '<g id="glyph-0-0"><path d="M0 0 C10 0 10 2 0 2 Z"/></g>'
    assert_raises(Subject::Unproven) do
      inventory(document(IMAGE_USE+GLYPH,IMAGE_DEF+curve)).qualify(crop_image_binding,[],[final_crop])
    end
    assert_raises(Subject::Unproven) do
      inventory(document(IMAGE_USE+CROSSING)).qualify(crop_image_binding,[],[final_crop([0,0,100,100])])
    end
  end

  def test_native_root_takes_its_existing_path_and_straddling_is_not_hidden_by_crop
    svg = document(IMAGE_USE+GLYPH)
    root = {:id=>'native',:placement_indices=>[0]}
    plan = inventory(svg).qualify(crop_image_binding,[root],[final_crop])
    assert_empty plan[:later_final_page_crops]
    assert_equal ['native'], plan[:later_roots].map { |row| row[:id] }
    assert_raises(Subject::Unproven) do
      inventory(document(GLYPH+IMAGE_USE+GLYPH)).qualify(crop_image_binding,
        [{:id=>'straddled',:placement_indices=>[0,1]}],[final_crop])
    end
  end

  def test_multiple_containing_final_crops_use_deterministic_tightest_witness
    small = final_crop
    big = final_crop([11,85,15,89]).merge(:resulting_entity_id=>'persistent_id:44')
    subject = inventory(document(IMAGE_USE+GLYPH))
    [ [big,small], [small,big] ].each do |crops|
      assert_equal 'persistent_id:45', subject.qualify(crop_image_binding,[],crops)[:later_final_page_crops].first[:resulting_entity_id]
    end
  end

  def crop_native_fixture
    artifact = { :source_span_id=>'text_span:1:4', :page_number=>1, :source_pdf_sha256=>DIGEST,
      :source_box=>[22,106,24,108], :visual_pixel_sha256=>'b'*64, :page_render_content_sha256=>'c'*64 }
    [:source_crop_binding_verified,:source_pdf_binding_verified,:page_binding_verified,
      :alpha_channel_verified,:transparent_background_verified,:visible_pixel_verified,
      :page_render_once_verified,:visual_pixel_binding_verified].each { |key| artifact[key]=true }
    record = { :delivery_scope=>:item_raster, :page=>1, :source_span_ids=>['text_span:1:4'],
      :resulting_entity_ids=>['persistent_id:45'], :artifact_evidence=>artifact }
    attrs = { 'renderer'=>'ghostscript_transparent_page_crop', 'raster_source_pdf_sha256'=>DIGEST,
      'raster_page_number'=>1, 'raster_source_box'=>artifact[:source_box], 'raster_visual_pixel_sha256'=>'b'*64 }
    native = Object.new
    native.define_singleton_method(:typename) { 'Image' }
    native.define_singleton_method(:get_attribute) { |_dict,key,default| attrs.fetch(key,default) }
    roots = [{:id=>'persistent_id:45', :source_span_id=>'text_span:1:4', :entity=>native}]
    options = { :page_number=>1, :parsed_pdf_sha256=>DIGEST, :raster_delivery_records=>[record] }
    [roots,options,attrs]
  end

  def test_main_joins_real_raster_delivery_to_native_id_without_mutating_certificate
    roots, options, _attrs = crop_native_fixture
    before = Marshal.dump(options)
    rows = Importer.embedded_image_final_page_crops(roots,[10,20,110,120],[10,20,110,120],[3,7,100,100],options)
    assert_equal [15,19,17,21], rows.first[:bounds_svg]
    assert_equal [22,106,24,108], rows.first[:source_box]
    assert_equal 'persistent_id:45', rows.first[:resulting_entity_id]
    assert_equal before, Marshal.dump(options)
  end

  def test_main_rejects_missing_or_changed_native_crop_and_unproved_page_pixels
    [:missing,:duplicate,:native_hash,:native_box,:artifact_hash,:unverified_pixels].each do |fault|
      roots, options, attrs = crop_native_fixture
      roots.clear if fault == :missing
      roots << roots.first.dup if fault == :duplicate
      attrs['raster_source_pdf_sha256'] = 'b'*64 if fault == :native_hash
      attrs['raster_source_box'] = [22,106,25,108] if fault == :native_box
      artifact = options[:raster_delivery_records].first[:artifact_evidence]
      artifact[:source_pdf_sha256] = 'b'*64 if fault == :artifact_hash
      artifact[:visual_pixel_binding_verified] = false if fault == :unverified_pixels
      assert_raises(Importer::RepresentationFidelity::ContractError) do
        Importer.embedded_image_final_page_crops(roots,[10,20,110,120],[10,20,110,120],[0,0,100,100],options)
      end
    end
  end

  def test_earlier_vector_and_text_are_behind_image_without_changing_source_data
    svg = document(CROSSING + GLYPH + IMAGE_USE)
    source_hash = Digest::SHA256.hexdigest(svg)
    plan = inventory(svg).qualify(image,[{:id=>'text',:placement_indices=>[0]}])
    assert_empty plan[:later_roots]
    assert_equal 0, plan[:later_overlapping_paint_count]
    assert_equal source_hash, plan[:source_svg_sha256]
    assert_equal source_hash, Digest::SHA256.hexdigest(svg)
    assert_equal DIGEST, plan[:source_image_event][:pixels][:visual_pixel_sha256]
  end

  def test_later_text_retains_complete_same_representation_root_above_image
    svg = document(IMAGE_USE + GLYPH + '<use xlink:href="#glyph-0-0" x="50" y="50"/>')
    roots = [{:id=>'text-claim',:source_span_id=>'text_span:1:4',:placement_indices=>[0,1]}]
    plan = inventory(svg).qualify(image,roots)
    assert_equal ['text-claim'], plan[:later_roots].map { |r| r[:id] }
    assert_equal [0,1], plan[:later_roots].first[:placement_indices]
    assert_equal 2, plan[:later_roots].first[:source_paint_ranks].length
    assert_equal roots.first[:source_span_id], plan[:later_roots].first[:source_span_id]
  end

  def test_root_straddling_image_order_must_not_be_lifted
    svg = document(GLYPH + IMAGE_USE + GLYPH)
    error = assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[{:id=>'mixed',:placement_indices=>[0,1]}]) }
    assert_match(/straddles/,error.message)
  end

  def test_later_overlapping_vector_is_explicitly_unqualified
    error = assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE + CROSSING)).qualify(image,[]) }
    assert_match(/nontext/,error.message)
  end

  def test_later_disjoint_vector_is_preserved_and_does_not_block
    svg = document(IMAGE_USE + '<path fill="none" stroke="black" stroke-width="1" d="M 70 70 L 80 70"/>')
    assert_empty inventory(svg).qualify(image,[])[:later_roots]
  end

  def test_true_source_rgba_with_transparent_pixels_is_preserved_but_not_qualified
    Dir.mktmpdir('image-order-test-') do |dir|
      raw = File.join(dir,'source.rgba')
      png = File.join(dir,'source.png')
      rgba = [255,0,0,255, 0,0,0,0, 0,255,0,128, 255,255,255,255].pack('C*')
      File.binwrite(raw,rgba)
      Importer::PngCropper.raw_to_png!(raw,2,2,4,png)
      payload = 'data:image/png;base64,' + Base64.strict_encode64(File.binread(png))
      definition = '<image id="pic" width="2" height="2" xlink:href="'+payload+'"/>'
      original = File.binread(png)
      proof = Importer::PngCropper.inspect_pixels!(png,false)
      subject = Subject::Inventory.new(document(IMAGE_USE+GLYPH,definition+GLYPH_DEF))
      decoded = subject.read_png(payload)
      assert_equal proof[:visual_pixel_sha256], decoded[:visual_pixel_sha256]
      assert_equal true, decoded[:transparent_pixel_present]
      assert_equal false, decoded[:all_opaque]
      binding = crop_image_binding.merge(proof)
      [[],[final_crop]].each do |crops|
        error = assert_raises(Subject::Unproven) { subject.qualify(binding,[],crops) }
        assert_match(/not proven fully opaque/,error.message)
      end
      assert_equal original, File.binread(png)
    end
  end

  def test_true_colored_opaque_png_still_qualifies_with_final_page_crop
    Dir.mktmpdir('image-order-opaque-test-') do |dir|
      raw, png = File.join(dir,'source.rgba'), File.join(dir,'source.png')
      File.binwrite(raw,[255,0,0,255, 0,0,0,255, 0,255,0,255, 255,255,255,255].pack('C*'))
      Importer::PngCropper.raw_to_png!(raw,2,2,4,png)
      payload = 'data:image/png;base64,' + Base64.strict_encode64(File.binread(png))
      definition = '<image id="pic" width="2" height="2" xlink:href="'+payload+'"/>'
      subject = Subject::Inventory.new(document(IMAGE_USE+GLYPH,definition+GLYPH_DEF))
      proof = Importer::PngCropper.inspect_pixels!(png,false)
      plan = subject.qualify(crop_image_binding.merge(proof),[],[final_crop])
      assert_equal true, plan[:source_image_event][:pixels][:all_opaque]
      assert_equal false, plan[:source_image_event][:pixels][:all_white_opaque]
      assert_equal 1, plan[:later_final_page_crops].length
    end
  end

  def test_missing_or_nonboolean_opaque_proof_never_qualifies
    [nil,false,1,'true'].each do |invalid|
      reader = lambda { |_uri| PIXELS.merge(:all_opaque=>invalid) }
      subject = Subject::Inventory.new(document(IMAGE_USE+GLYPH),reader)
      assert_raises(Subject::Unproven) { subject.qualify(crop_image_binding,[],[final_crop]) }
    end
  end

  def test_reflection_and_shear_bind_ordered_affine_corners_without_bbox_fitting
    svg = document('<use xlink:href="#pic" transform="matrix(-5,1,2,5,20,10)"/>')
    corners = [[20,10],[10,12],[14,22],[24,20]]
    plan = inventory(svg).qualify(image.merge(:corners_svg=>corners),[])
    assert_equal corners, plan[:source_image_event][:corners]
    wrong = corners.reverse
    assert_raises(Subject::Unproven) { inventory(svg).qualify(image.merge(:corners_svg=>wrong),[]) }
  end

  def test_changed_pixels_dimensions_and_affine_cannot_supply_source_binding
    subject = inventory(document(IMAGE_USE))
    [{:visual_pixel_sha256=>'b'*64}, {:pixel_width=>3}, {:corners_svg=>[[11,10],[21,10],[21,20],[11,20]]}].each do |change|
      assert_raises(Subject::Unproven) { subject.qualify(image.merge(change),[]) }
    end
  end

  def test_duplicate_image_occurrences_are_not_arbitrarily_joined
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+IMAGE_USE)).qualify(image,[]) }
    assert_raises(Subject::Unproven) { inventory(document('',IMAGE_DEF+IMAGE_DEF)) }
  end

  def test_unknown_later_paint_and_missing_native_owner_fail_qualification
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+'<foreignObject/>')).qualify(image,[]) }
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+GLYPH)).qualify(image,[]) }
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+GLYPH)).qualify(image,[{:id=>'a',:placement_indices=>[0,9]}]) }
  end

  def test_empty_whitespace_definition_has_zero_ink_without_hiding_unknown_geometry
    empty = '<g id="glyph-0-0"><path d=""/></g>'
    plan = inventory(document(IMAGE_USE+GLYPH,IMAGE_DEF+empty)).qualify(image,[])
    assert_equal 0, plan[:later_overlapping_paint_count]
    bad = '<g id="glyph-0-0"><circle cx="2" cy="2" r="5"/></g>'
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+GLYPH,IMAGE_DEF+bad)).qualify(image,[]) }
  end

  def test_unreferenced_definition_does_not_count_as_live_image
    assert_raises(Subject::Unproven) { inventory(document('')).qualify(image,[]) }
  end

  def composite_defs(rect_x = 70)
    '<filter id="invert" x="0%" y="0%" width="100%" height="100%"><feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 -1 1"/></filter>' +
    '<g id="maskshape"><rect x="0" y="0" width="100" height="100" fill="black" fill-opacity="0"/><rect x="'+rect_x.to_s+'" y="10" width="10" height="10" fill="white"/></g>' +
    '<mask id="positive"><use xlink:href="#maskshape"/></mask>' +
    '<mask id="negative"><use xlink:href="#maskshape" filter="url(#invert)"/></mask>' +
    '<g id="destination" mask="url(#negative)">'+IMAGE_USE+'</g>' +
    '<g id="source" mask="url(#positive)"><path d="M 0 0 A 5 5 0 0 0 10 10"/></g>' +
    '<filter id="combine"><feImage xlink:href="#source" result="source" x="0" y="0" width="100" height="100"/>' +
    '<feImage xlink:href="#destination" result="destination" x="0" y="0" width="100" height="100"/>' +
    '<feComposite in="source" in2="destination" operator="arithmetic" k1="0" k2="1" k3="1" k4="0"/></filter>'
  end

  def test_cairo_reference_graph_prunes_only_proved_disjoint_mask_branch
    svg = document('<g filter="url(#combine)"><rect width="100" height="100"/></g>',IMAGE_DEF+composite_defs)
    plan = inventory(svg).qualify(image,[])
    assert_equal 'pic', plan[:source_image_event][:svg_image_id]
    crossing = document('<g filter="url(#combine)"><rect width="100" height="100"/></g>',IMAGE_DEF+composite_defs(15))
    assert_raises(Subject::Unproven) { inventory(crossing).qualify(image,[]) }
  end

  def test_mask_does_not_authorize_lifting_beyond_full_native_affine_footprint
    # Later paint falls only in the small native edge beyond the source clip.
    defs = IMAGE_DEF + '<clipPath id="c"><rect x="11" y="10" width="9" height="10"/></clipPath>'
    svg = document('<g clip-path="url(#c)">'+IMAGE_USE+'</g><rect x="10" y="12" width="0.5" height="3"/>',defs)
    assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
  end

  def test_source_reference_cycles_are_not_treated_as_absent_paint
    defs = IMAGE_DEF + '<g id="loop"><use xlink:href="#loop"/></g>'
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+'<use xlink:href="#loop"/>',defs)).qualify(image,[]) }
  end

  def gray_png(value)
    chunk = lambda { |kind,data| [data.bytesize].pack('N') + kind + data + [Zlib.crc32(kind+data)].pack('N') }
    Importer::PngCropper::SIGNATURE + chunk.call('IHDR',[2,2,8,0,0,0,0].pack('NNC5')) +
      chunk.call('IDAT',Zlib::Deflate.deflate([0,value,value,0,value,value].pack('C*'))) + chunk.call('IEND','')
  end

  def test_exact_gray_mask_pixels_crc_and_extent_are_required
    subject = inventory(document(IMAGE_USE))
    proof = subject.gray_mask_proof(gray_png(255))
    assert_equal true, proof[:all_white_opaque]
    assert_equal true, proof[:all_opaque]
    assert_equal Digest::SHA256.hexdigest(([255]*16).pack('C*')), proof[:visual_pixel_sha256]
    assert_equal false, subject.gray_mask_proof(gray_png(254))[:all_white_opaque]
    assert_equal true, subject.gray_mask_proof(gray_png(254))[:all_opaque]
    damaged = gray_png(255).dup
    damaged.setbyte(40,damaged.getbyte(40)^1)
    assert_raises(Subject::Unproven) { subject.gray_mask_proof(damaged) }
    assert_raises(Subject::Unproven) { subject.gray_mask_proof(gray_png(255)+'extra') }
  end

  def test_filter_inputs_and_mask_sample_program_cannot_be_guessed
    content = '<g filter="url(#combine)"><rect width="100" height="100"/></g>'
    altered = composite_defs.sub('in2="destination"','in2="source"')
    assert_raises(Subject::Unproven) { inventory(document(content,IMAGE_DEF+altered)).qualify(image,[]) }
    altered = composite_defs.sub('<feColorMatrix values=', '<feColorMatrix in="SourceAlpha" values=')
    assert_raises(Subject::Unproven) { inventory(document(content,IMAGE_DEF+altered)).qualify(image,[]) }
  end

  def test_gray_mask_must_be_exactly_coterminous_with_masked_image
    defs = IMAGE_DEF + '<image id="maskpic" width="2" height="2" xlink:href="white"/>' +
      '<mask id="m"><use xlink:href="#maskpic" transform="matrix(5,0,0,5,10,10)"/></mask>'
    svg = document('<g mask="url(#m)">'+IMAGE_USE+'</g>',defs)
    reader = lambda { |uri| PIXELS.merge(:all_white_opaque=>uri=='white') }
    assert_equal 0, Subject::Inventory.new(svg,reader).qualify(image,[])[:later_overlapping_paint_count]
    shifted = svg.sub('href="#maskpic" transform="matrix(5,0,0,5,10,10)"','href="#maskpic" transform="matrix(5,0,0,5,11,10)"')
    assert_raises(Subject::Unproven) { Subject::Inventory.new(shifted,reader).qualify(image,[]) }
  end

  def test_translucent_inverted_mask_cannot_prove_later_vector_absent
    defs = IMAGE_DEF + '<filter id="invert"><feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 -1 1"/></filter>' +
      '<g id="half"><rect x="10" y="10" width="10" height="10" fill="white" opacity="0.5"/></g>' +
      '<mask id="m"><use xlink:href="#half" filter="url(#invert)"/></mask>'
    svg = document(IMAGE_USE+'<g mask="url(#m)"><rect x="10" y="10" width="10" height="10" fill="red"/></g>',defs)
    assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
    assert_raises(Subject::Unproven) { inventory(svg.sub('opacity="0.5"','fill-opacity="0.5"')).qualify(image,[]) }
  end

  def test_rotated_mask_bbox_is_not_proof_of_actual_quad_coverage
    subject = inventory(document(IMAGE_USE))
    assert_equal false, Subject.quad_covers?([[0,10],[10,0],[20,10],[10,20]],[0,0,20,20])
    assert_equal true, Subject.quad_covers?([[0,10],[10,0],[20,10],[10,20]],[9,9,11,11])
    node = { :name=>'rect', :attrs=>{'x'=>'0','y'=>'0','width'=>'10','height'=>'10','fill'=>'white','transform'=>'matrix(1,1,-1,1,10,0)'}, :children=>[] }
    assert_equal :partial, subject.mask_relation(node,Subject::IDENTITY,[0,0,20,20])
  end

  def test_mask_coordinate_units_and_explicit_small_region_are_not_ignored
    defs = IMAGE_DEF + '<mask id="m" maskContentUnits="objectBoundingBox"><rect x="0" y="0" width="1" height="1" fill="white"/></mask>'
    svg = document('<g mask="url(#m)">'+IMAGE_USE+'</g>',defs)
    assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
    svg = svg.sub('maskContentUnits="objectBoundingBox"','x="0" y="0" width="1" height="1" maskUnits="userSpaceOnUse"')
    assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
  end

  def test_inverse_alpha_does_not_extend_beyond_actual_finite_filter_region
    content = '<g filter="url(#combine)"><rect width="100" height="100"/></g>'
    # Remove the transparent full-page background: the inversion is confined
    # to the small distant rectangle's bbox, not the whole page.
    defs = composite_defs.sub('<rect x="0" y="0" width="100" height="100" fill="black" fill-opacity="0"/>','')
    error = assert_raises(Subject::Unproven) { inventory(document(content,IMAGE_DEF+defs)).qualify(image,[]) }
    assert_match(/live source occurrence/,error.message)
  end

  def test_filtered_transparent_shape_and_stroked_mask_are_not_false_absence
    defs = IMAGE_DEF + '<filter id="inv" x="0%" y="0%" width="100%" height="100%"><feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 -1 1"/></filter>' +
      '<mask id="m"><rect x="10" y="10" width="10" height="10" fill="white" fill-opacity="0" filter="url(#inv)"/></mask>'
    svg = document(IMAGE_USE+'<g mask="url(#m)"><rect x="10" y="10" width="10" height="10" fill="red"/></g>',defs)
    error = assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
    assert_match(/nontext/,error.message)
    stroked = svg.sub('fill-opacity="0" filter="url(#inv)"','fill-opacity="0" stroke="white" stroke-width="8"')
    assert_raises(Subject::Unproven) { inventory(stroked).qualify(image,[]) }
    inherited = stroked.sub('<mask id="m">','<mask id="m"><g stroke="white">').sub('</mask>','</g></mask>').sub('stroke="white" stroke-width="8"','')
    assert_raises(Subject::Unproven) { inventory(inherited).qualify(image,[]) }
  end

  def test_nested_mask_primitive_region_and_rotated_filter_are_unqualified
    defs = composite_defs
    content = '<g filter="url(#combine)"><rect width="100" height="100"/></g>'
    [defs.sub('<feColorMatrix values=','<feColorMatrix x="0" width="0.1" values='),
     defs.sub('<g id="maskshape">','<g id="maskshape" mask="url(#positive)">'),
     defs.sub('href="#maskshape" filter=','href="#maskshape" transform="matrix(0,1,-1,0,100,0)" filter=')].each do |bad|
      assert_raises(Subject::Unproven) { inventory(document(content,IMAGE_DEF+bad)).qualify(image,[]) }
    end
  end

  def original_full_clip_binding
    quad = [[10.0,10.0],[20.0,10.0],[20.0,20.0],[10.0,20.0]]
    proof = { :schema=>'bcs.original_image_clip/1', :status=>'FULL_FOOTPRINT',
      :parsed_pdf_sha256=>'d'*64, :page_number=>1, :image_object_number=>6,
      :placement_index=>1, :ctm=>[10.0,0.0,0.0,10.0,10.0,10.0], :corners_pts=>quad,
      :clip_polygons_pts=>['media_box','crop_box'].map { |kind| { :kind=>kind,:corners_pts=>[[0,0],[100,0],[100,100],[0,100]] } },
      :source_streams=>[{:kind=>'page',:index=>0,:sha256=>'e'*64}], :form_chain=>[], :unproven_reasons=>[] }
    image.merge(proof.select { |key,_v| [:parsed_pdf_sha256,:page_number,:image_object_number,:placement_index,:ctm,:corners_pts].include?(key) }).merge(:original_clip_proof=>proof)
  end

  def test_narrow_cairo_clip_requires_independent_original_full_coverage
    defs = IMAGE_DEF + '<clipPath id="c"><rect x="11" y="10" width="9" height="10"/></clipPath>'
    svg = document('<path fill="none" stroke="black" d="M10 12 L10.5 15"/><g clip-path="url(#c)">'+IMAGE_USE+'</g>',defs)
    subject = inventory(svg)
    error = assert_raises(Subject::Unproven) { subject.qualify(image,[]) }
    assert_match(/original PDF clip proof/,error.message)
    plan = subject.qualify(original_full_clip_binding,[])
    assert_equal 'original_pdf_full_affine_clip_coverage',plan[:clip_qualification][:policy]
    assert_equal [11.0,10.0,20.0,20.0],plan[:clip_qualification][:cairo_clip_bounds]
    assert_equal DIGEST,plan[:source_image_event][:pixels][:visual_pixel_sha256]
  end

  def test_original_narrow_clip_does_not_authorize_full_native_image
    defs = IMAGE_DEF + '<clipPath id="c"><rect x="11" y="10" width="9" height="10"/></clipPath>'
    svg = document('<g clip-path="url(#c)">'+IMAGE_USE+'</g>',defs)
    bound = original_full_clip_binding
    bound[:original_clip_proof][:clip_polygons_pts][1][:corners_pts] = [[11,10],[20,10],[20,20],[11,20]]
    error = assert_raises(Subject::Unproven) { inventory(svg).qualify(bound,[]) }
    assert_match(/does not contain/,error.message)
  end

  def test_original_full_clip_does_not_authorize_later_fringe_vector_occlusion
    defs = IMAGE_DEF + '<clipPath id="c"><rect x="11" y="10" width="9" height="10"/></clipPath>'
    svg = document('<g clip-path="url(#c)">'+IMAGE_USE+'</g><rect x="10" y="12" width="0.5" height="3"/>',defs)
    error = assert_raises(Subject::Unproven) { inventory(svg).qualify(original_full_clip_binding,[]) }
    assert_match(/nontext/,error.message)
  end

  def test_rounded_repeated_or_canceling_clip_contours_are_not_rectangles
    bad = ['<rect x="10" y="10" width="10" height="10" rx="2"/>',
      '<path d="M10 10 L20 10 L20 20 L10 20 Z M10 10 L10 20 L20 20 L20 10 Z"/>',
      '<path clip-rule="evenodd" d="M10 10 L20 10 L20 20 L10 20 Z M10 10 L20 10 L20 20 L10 20 Z"/>',
      '<path d="M10 10 L20 20 L20 10 L10 20 Z"/>']
    bad.each do |shape|
      svg = document('<g clip-path="url(#c)">'+IMAGE_USE+'</g>',IMAGE_DEF+'<clipPath id="c">'+shape+'</clipPath>')
      assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
    end
  end

  def test_cairo_trailing_empty_moveto_and_clip_transform_are_exact
    defs = IMAGE_DEF+'<clipPath id="c" transform="translate(10,10)"><path d="M0 0 L10 0 L10 10 L0 10 Z M0 0"/></clipPath>'
    plan = inventory(document('<g clip-path="url(#c)">'+IMAGE_USE+'</g>',defs)).qualify(image,[])
    assert_equal [10.0,10.0,20.0,20.0],plan[:source_image_event][:clip_bounds]
    assert_equal 'svg_clip_covers_full_native_affine_footprint',plan[:clip_qualification][:policy]
  end
end
