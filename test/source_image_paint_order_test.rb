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

  def crop_native_fixture(rotation = 0)
    artifact = { :source_span_id=>'text_span:1:4', :page_number=>1, :page_rotation=>rotation, :source_pdf_sha256=>DIGEST,
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
    options = { :page_number=>1, :page_rotation=>rotation, :parsed_pdf_sha256=>DIGEST, :raster_delivery_records=>[record] }
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

  def test_intrinsic_rotation_maps_raw_crop_and_image_points_into_the_selected_svg_box
    page_box = [10,20,210,120]
    [[0,[3,7,200,100],[15,19,17,21]],
     [90,[3,7,100,200],[89,19,91,21]],
     [180,[3,7,200,100],[189,93,191,95]],
     [270,[3,7,100,200],[15,193,17,195]]].each do |rotation,viewbox,expected|
      roots, options, _attrs = crop_native_fixture(rotation)
      before = Marshal.dump(options)
      rows = Importer.embedded_image_final_page_crops(roots,page_box,page_box,viewbox,options)
      assert_equal expected, rows.first[:bounds_svg]
      assert_equal rotation, rows.first[:page_rotation]
      assert_equal before, Marshal.dump(options)
      assert_equal expected, Subject.box([[22,106],[24,106],[24,108],[22,108]].map do |x,y|
        Subject.pdf_point_to_svg(x,y,page_box,viewbox,rotation)
      end)
      # A crop rendered through a nonzero CropBox rotates about that box,
      # even though its certified raw source box belongs to the MediaBox.
      crop_box = [20,100,70,120]
      cropped = Importer.embedded_image_final_page_crops(roots,page_box,crop_box,
        [3,7,*([90,270].include?(rotation) ? [20,50] : [50,20])],options)
      refute_equal expected, cropped.first[:bounds_svg]
    end
    assert_raises(Subject::Unproven) { Subject.pdf_point_to_svg(22,106,page_box,[0,0,200,100],45) }
  end

  def test_rotated_crop_coverage_rejects_unrotated_coordinates_and_mismatched_page_rotation
    # At Rotate90, raw PDF [86,12,88,14] becomes SVG [12,86,14,88].
    binding = crop_image_binding.merge(:page_rotation=>90)
    crop = final_crop([86,12,88,14]).merge(:page_rotation=>90,:bounds_svg=>[12,86,14,88])
    subject = inventory(document(IMAGE_USE+GLYPH))
    # The later glyph is at [12,12,14,14], so the rotated crop does not cover it.
    assert_raises(Subject::Unproven) { subject.qualify(binding,[],[crop]) }
    crop[:source_box] = [12,12,14,14]
    crop[:bounds_svg] = [12,12,14,14]
    assert_equal 1, subject.qualify(binding,[],[crop])[:later_final_page_crops].length
    assert_raises(Subject::Unproven) do
      subject.qualify(binding,[],[crop.merge(:page_rotation=>0)])
    end
    assert_raises(Subject::Unproven) do
      subject.qualify(binding,[],[crop.merge(:bounds_svg=>[12,86,14,88])])
    end
  end

  def test_unrotated_fractional_saved_ledger_keeps_original_exact_arithmetic
    page_box = [-20.25,-12.745349,180.35,70.207687]
    viewbox = [3.0,6.049475,200.6,82.953036]
    source_box = [22.123456,32.123456,24.123456,44.822594]
    expected = [source_box[0]-page_box[0]+viewbox[0],viewbox[3]+viewbox[1]+page_box[1]-source_box[3],
      source_box[2]-page_box[0]+viewbox[0],viewbox[3]+viewbox[1]+page_box[1]-source_box[1]]
    assert_equal expected, Subject.pdf_box_to_svg(source_box,page_box,viewbox,0)
    assert_equal expected, Subject.pdf_box_to_svg(JSON.parse(JSON.generate(source_box)),page_box,viewbox,0)
    # Reassociation looks equivalent but differs by one ULP for this source;
    # accepting the old exact ledger requires keeping its original order.
    refute_equal expected[1], viewbox[3]+viewbox[1]-(source_box[3]-page_box[1])
  end

  def test_main_rejects_missing_or_changed_native_crop_and_unproved_page_pixels
    [:missing,:duplicate,:native_hash,:native_box,:artifact_hash,:unverified_pixels,
     :missing_rotation,:wrong_rotation].each do |fault|
      roots, options, attrs = crop_native_fixture
      roots.clear if fault == :missing
      roots << roots.first.dup if fault == :duplicate
      attrs['raster_source_pdf_sha256'] = 'b'*64 if fault == :native_hash
      attrs['raster_source_box'] = [22,106,25,108] if fault == :native_box
      artifact = options[:raster_delivery_records].first[:artifact_evidence]
      artifact[:source_pdf_sha256] = 'b'*64 if fault == :artifact_hash
      artifact[:visual_pixel_binding_verified] = false if fault == :unverified_pixels
      artifact.delete(:page_rotation) if fault == :missing_rotation
      artifact[:page_rotation] = 90 if fault == :wrong_rotation
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

  # EmbeddedImageExtractor writes /DeviceGray images as 8-bit gray PNGs
  # (raw_to_png! channels 1/2). The page ownership proof decodes that exact
  # file; rejecting it aborted a whole Acrobat sheet import (A04-01).
  def test_gray_embedded_source_png_decodes_and_matches_svg_gray_image
    Dir.mktmpdir('image-order-gray-test-') do |dir|
      raw, png = File.join(dir,'source.gray'), File.join(dir,'source.png')
      File.binwrite(raw,[0,128,200,255].pack('C*'))
      Importer::PngCropper.raw_to_png!(raw,2,2,1,png)
      assert_equal 0, File.binread(png).getbyte(25)
      proof = Importer::PngCropper.inspect_pixels!(png,false,nil)
      assert_equal 2, proof[:pixel_width]
      assert_equal true, proof[:visible_pixel_present]
      assert_equal false, proof[:transparent_pixel_present]
      rgba_raw, rgba_png = File.join(dir,'same.rgba'), File.join(dir,'same.png')
      File.binwrite(rgba_raw,[0,0,0,255, 128,128,128,255, 200,200,200,255, 255,255,255,255].pack('C*'))
      Importer::PngCropper.raw_to_png!(rgba_raw,2,2,4,rgba_png)
      assert_equal Importer::PngCropper.inspect_pixels!(rgba_png,false,nil)[:visual_pixel_sha256], proof[:visual_pixel_sha256]
      payload = 'data:image/png;base64,' + Base64.strict_encode64(File.binread(png))
      definition = '<image id="pic" width="2" height="2" xlink:href="'+payload+'"/>'
      subject = Subject::Inventory.new(document(IMAGE_USE+GLYPH,definition+GLYPH_DEF))
      assert_equal proof[:visual_pixel_sha256], subject.read_png(payload)[:visual_pixel_sha256]
      assert_raises(Importer::RepresentationFidelity::ContractError) do
        Importer::PngCropper.inspect_pixels!(png,true,nil)
      end
    end
  end

  def test_gray_alpha_embedded_source_png_expands_to_rgba
    Dir.mktmpdir('image-order-gray-alpha-test-') do |dir|
      raw, png = File.join(dir,'source.ga'), File.join(dir,'source.png')
      File.binwrite(raw,[10,255, 20,0, 30,128, 40,255].pack('C*'))
      Importer::PngCropper.raw_to_png!(raw,2,2,2,png)
      proof = Importer::PngCropper.inspect_pixels!(png,false,nil)
      assert_equal true, proof[:transparent_pixel_present]
      rgba_raw, rgba_png = File.join(dir,'same.rgba'), File.join(dir,'same.png')
      File.binwrite(rgba_raw,[10,10,10,255, 20,20,20,0, 30,30,30,128, 40,40,40,255].pack('C*'))
      Importer::PngCropper.raw_to_png!(rgba_raw,2,2,4,rgba_png)
      assert_equal Importer::PngCropper.inspect_pixels!(rgba_png,false,nil)[:visual_pixel_sha256], proof[:visual_pixel_sha256]
    end
  end

  def test_missing_or_nonboolean_opaque_proof_never_qualifies
    [nil,false,1,'true'].each do |invalid|
      reader = lambda { |_uri| PIXELS.merge(:all_opaque=>invalid) }
      subject = Subject::Inventory.new(document(IMAGE_USE+GLYPH),reader)
      assert_raises(Subject::Unproven) { subject.qualify(crop_image_binding,[],[final_crop]) }
    end
  end

  def test_source_image_decode_uses_safe_temp_and_cleans_success_and_failure
    Dir.mktmpdir('image-order-cleanup-test-') do |parent|
      raw, png = File.join(parent,'source.rgba'), File.join(parent,'source.png')
      File.binwrite(raw,[20,40,60,255].pack('C*')*4)
      Importer::PngCropper.raw_to_png!(raw,2,2,4,png)
      payload = 'data:image/png;base64,' + Base64.strict_encode64(File.binread(png))
      subject = Subject::Inventory.new(document(IMAGE_USE))
      allocated = nil
      allocator = lambda do |prefix|
        assert_equal 'bc-image-order-', prefix
        allocated = Dir.mktmpdir(prefix,parent)
      end
      Importer::SafeTemp.stub(:mktmpdir,allocator) do
        assert_equal true, subject.read_png(payload)[:all_opaque]
        refute File.exist?(allocated)
        Importer::PngCropper.stub(:prepare_rgba!,lambda { |*_args| raise IOError, 'decode failed' }) do
          assert_raises(IOError) { subject.read_png(payload) }
        end
        refute File.exist?(allocated)
      end
      assert File.file?(png), 'cleanup must keep the original input'
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

  def clipped_branch(clip_shape, content, clip_attrs = '')
    [ '<g clip-path="url(#far)">'+content+'</g>',
      '<clipPath id="far" '+clip_attrs+'>'+clip_shape+'</clipPath>' ]
  end

  def test_unrelated_nonrectangular_clip_does_not_block_unclipped_picture
    branch,defs = clipped_branch('<path clip-rule="evenodd" d="M40 40 L60 40 L60 45 L55 45 L55 50 L60 50 L60 60 L40 60 Z M40 40"/>',
      '<path d="M40 40 L60 40 L60 60 L40 60 Z"/>')
    subject = inventory(document(branch+IMAGE_USE,IMAGE_DEF+defs))
    plan = subject.qualify(image,[])
    assert_equal 'pic',plan[:source_image_event][:svg_image_id]
    assert_nil plan[:source_image_event][:clip_bounds]
    assert_equal 'svg_clip_covers_full_native_affine_footprint',plan[:clip_qualification][:policy]
    assert_equal 0,plan[:later_overlapping_paint_count]
  end

  def test_compound_and_multichild_clip_hulls_only_exclude_strictly_distant_paint
    shapes = [
      '<path d="M40 40 L50 40 L50 50 L40 50 Z M60 60 L70 60 L70 70 Z"/>',
      '<path d="M40 40 L50 40 L50 50 Z"/><rect x="60" y="60" width="10" height="10"/>'
    ]
    shapes.each do |shape|
      branch,defs = clipped_branch(shape,'<rect width="100" height="100"/>')
      plan = inventory(document(IMAGE_USE+branch,IMAGE_DEF+defs)).qualify(image,[])
      assert_equal 0,plan[:later_overlapping_paint_count]
      assert_empty plan[:later_roots]
    end
    branch,defs = clipped_branch('<path d="M40 40 L50 40 L50 50 Z"/><rect x="12" y="12" width="2" height="2"/>',
      '<rect width="100" height="100"/>')
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+branch,IMAGE_DEF+defs)).qualify(image,[]) }
  end

  def test_proven_outer_clip_excludes_unknown_descendant_without_losing_shared_definitions
    defs = IMAGE_DEF+GLYPH_DEF+'<clipPath id="outer"><rect x="40" y="40" width="10" height="10"/></clipPath>'+
      '<clipPath id="inner"><circle cx="45" cy="45" r="4"/></clipPath>'
    branch = '<g clip-path="url(#outer)"><g clip-path="url(#inner)">'+
      '<use xlink:href="#glyph-0-0" x="42" y="42"/></g></g>'
    svg = document(branch+IMAGE_USE+GLYPH,defs)
    plan = inventory(svg).qualify(image,[{:id=>'live-root',:placement_indices=>[1]}])
    assert_equal ['live-root'],plan[:later_roots].map { |r| r[:id] }
    assert_equal [1],plan[:later_roots].first[:placement_indices]
    assert_operator plan[:later_roots].first[:source_paint_ranks].first,:>,plan[:image_paint_rank]
  end

  def test_touching_intersecting_and_transformed_clips_keep_the_strict_guard
    triangle = '<path d="M40 40 L50 40 L40 50 Z"/>'
    [ ['<path d="M20 12 L25 12 L20 18 Z"/>',''],
      ['<path d="M12 12 L15 12 L12 15 Z"/>',''],
      [triangle,'transform="translate(-30,-30)"'],
      ['<path transform="translate(-30,-30)" d="M40 40 L50 40 L40 50 Z"/>','']
    ].each do |shape,attrs|
      branch,defs = clipped_branch(shape,IMAGE_USE,attrs)
      assert_raises(Subject::Unproven) { inventory(document(branch,IMAGE_DEF+defs)).qualify(image,[]) }
    end
  end

  def test_curve_control_hull_is_conservative_and_unknown_clip_programs_never_disappear
    [ '<path d="M40 40 C-20 -20 -20 -20 50 50 L40 50 Z"/>',
      '<path d="M40 40 A10 10 0 0 0 50 50 Z"/>',
      '<use xlink:href="#glyph-0-0" x="40" y="40"/>',
      '<path d="M40 40 L50 40 L40 50 Z"/><circle cx="45" cy="45" r="1"/>',
      '<path class="unknown" d="M40 40 L50 40 L40 50 Z"/>'
    ].each do |shape|
      branch,defs = clipped_branch(shape,'<rect width="100" height="100"/>')
      assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+branch,IMAGE_DEF+GLYPH_DEF+defs)).qualify(image,[]) }
    end
    branch,defs = clipped_branch('<path d="M40 40 L50 40 L40 50 Z"/>',IMAGE_USE,'clipPathUnits="objectBoundingBox"')
    assert_raises(Subject::Unproven) { inventory(document(branch,IMAGE_DEF+defs)).qualify(image,[]) }
  end

  def test_clip_exclusion_honors_bounds_and_cannot_change_an_intersecting_image_clip
    branch,defs = clipped_branch('<path d="M40 40 L50 40 L40 50 Z"/>',IMAGE_USE,
      'transform="matrix(1e308,0,0,1e308,0,0)"')
    assert_raises(Subject::Unproven) { inventory(document(branch,IMAGE_DEF+defs)).qualify(image,[]) }
    oversized = '<path d="'+('M40 40 L50 40 L40 50 Z '*7000)+'"/>'
    branch,defs = clipped_branch(oversized,'<rect width="100" height="100"/>')
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+branch,IMAGE_DEF+defs)).qualify(image,[]) }
    far = '<clipPath id="far"><path d="M40 40 L50 40 L40 50 Z"/></clipPath>'
    actual = '<clipPath id="actual"><path d="M10 10 L20 10 L15 15 L20 20 L10 20 Z"/></clipPath>'
    svg = document('<g clip-path="url(#far)"><path d="M40 40 L50 40 L40 50 Z"/></g>'+
      '<g clip-path="url(#actual)">'+IMAGE_USE+'</g>',IMAGE_DEF+far+actual)
    assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
  end

  def test_exact_relative_coordinates_cannot_round_a_touch_into_a_disjoint_clip
    data = 'M10000000000000000 12 l3 0 l-9999999999999982 0 l0 2 Z'
    exact = Subject.path_points(data,true)
    assert_equal Rational(21,1),exact[2][0]
    assert_equal Rational(10000000000000003,1),exact[1][0]
    assert_equal 10000000000000004.0,Subject.path_points(data)[1][0]
    branch,defs = clipped_branch('<path d="'+data+'"/>','<rect width="100" height="100"/>')
    actual_image = '<use xlink:href="#pic" transform="matrix(5,0,0,5,11,12)"/>'
    native = image.merge(:corners_svg=>[[11,12],[21,12],[21,22],[11,22]])
    assert_raises(Subject::Unproven) { inventory(document(actual_image+branch,IMAGE_DEF+defs)).qualify(native,[]) }
  end

  def test_rounded_canceling_transform_frames_and_excess_decimal_work_are_not_proofs
    branch,defs = clipped_branch('<path d="M40 40 L50 40 L40 50 Z"/>','<rect width="100" height="100"/>')
    transformed = '<g transform="translate(10000000000000000,0)"><g transform="translate(-10000000000000000,0)">'+branch+'</g></g>'
    assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+transformed,IMAGE_DEF+defs)).qualify(image,[]) }
    assert_raises(Subject::Unproven) { Subject.path_points('M0e1000000000 0 L1 0 L0 1 Z',true) }
    assert_raises(Subject::Unproven) { Subject.path_points('M0.'+('0'*70)+'1 0 L1 0 L0 1 Z',true) }
  end

  def test_nested_svg_viewport_is_not_an_untransformed_query_frame
    branch,defs = clipped_branch('<path d="M40 40 L50 40 L40 50 Z"/>','<rect width="100" height="100"/>')
    [ '<svg x="-30" y="-30">'+branch+'</svg>',
      '<svg x="10" y="10" width="10" height="10" viewBox="40 40 10 10">'+branch+'</svg>'
    ].each do |nested|
      assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+nested,IMAGE_DEF+defs)).qualify(image,[]) }
    end
  end

  def test_disjoint_comparison_keeps_exact_decimal_gaps_and_strict_touching
    subject = inventory(document(IMAGE_USE))
    epsilon = Rational(1,10**30)
    edge = 10.0.to_r
    query = [0.0,0.0,10.0,20.0]
    assert subject.strictly_disjoint_bounds?([edge+epsilon,11.to_r,11.to_r,19.to_r],query)
    refute subject.strictly_disjoint_bounds?([edge,11.to_r,11.to_r,19.to_r],query)
    refute subject.strictly_disjoint_bounds?([edge-epsilon,11.to_r,11.to_r,19.to_r],query)
    assert subject.strictly_disjoint_bounds?([11.0,11.0,12.0,19.0],[0.to_r,0.to_r,11.to_r-epsilon,20.to_r])
    refute subject.strictly_disjoint_bounds?([11.0,11.0,12.0,19.0],[0.to_r,0.to_r,11.to_r+epsilon,20.to_r])
  end

  def round_line(data = 'M5 7 L25 7', extra = '')
    '<path fill="none" stroke="black" stroke-width="2" stroke-linecap="round" '+
      'stroke-linejoin="round" stroke-miterlimit="10" d="'+data+'" '+extra+'/>'
  end

  def vector_events(svg, query = [10,10,20,20])
    inventory(svg).events_for(query).select { |event| event[:kind] == :vector }
  end

  def test_live_use_translation_cannot_prune_its_own_nonrectangular_clip
    defs = IMAGE_DEF+'<g id="shape"><rect x="40" y="40" width="10" height="10"/></g>'+
      '<clipPath id="far"><path d="M40 40 L50 40 L40 50 Z"/></clipPath>'
    branch = '<use xlink:href="#shape" x="-30" y="-30" clip-path="url(#far)"/>'
    error = assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+branch,defs)).qualify(image,[]) }
    assert_match(/four-corner/,error.message)
  end

  def test_actual_two_round_line_sources_are_disjoint_without_changing_picture_order
    paths = '<path fill="none" stroke-width="27.6" stroke-linecap="round" stroke-linejoin="round" '+
      'stroke="rgb(0%, 0%, 0%)" stroke-opacity="1" stroke-miterlimit="10" '+
      'd="M 31326.015625 3800.390625 L 34207.1875 3800.390625 " transform="matrix(0.1, 0, 0, -0.1, 0, 2592)"/>'+
      '<path fill="none" stroke-width="14.4" stroke-linecap="round" stroke-linejoin="round" '+
      'stroke="rgb(0%, 0%, 0%)" stroke-opacity="1" stroke-miterlimit="10" '+
      'd="M 32766.015625 3844.804688 L 32766.015625 4573.203125 " transform="matrix(0.1, 0, 0, -0.1, 0, 2592)"/>'
    use = '<use xlink:href="#pic" transform="matrix(76.8,0,0,-48.12,3200.28,2313.36)"/>'
    corners = [[3200.28,2313.36],[3353.88,2313.36],[3353.88,2217.12],[3200.28,2217.12]]
    bound = image.merge(:corners_svg=>corners)
    svg = document(use+paths)
    events = vector_events(svg,Subject.box(corners))
    assert_equal 2,events.length
    assert events.all? { |event| event[:bounds_policy] == 'exact_axis_aligned_round_single_segment_disjoint' }
    assert_equal Rational('2213.3409375'),events[0][:bounds][3]
    assert_equal Rational('2208.2395312'),events[1][:bounds][3]
    assert events.all? { |event| event[:bounds].all? { |value| value.is_a?(Rational) } }
    plan = inventory(svg).qualify(bound,[])
    assert_equal 0,plan[:later_overlapping_paint_count]
    assert_empty plan[:later_roots]
    assert_equal 'pic',plan[:source_image_event][:svg_image_id]
  end

  def test_round_line_inherits_declared_cap_and_width_but_default_or_square_caps_do_not_qualify
    bare = '<path d="M5 7 L25 7"/>'
    group = '<g fill="none" stroke="black" stroke-width="2" stroke-linecap="round">'+bare+'</g>'
    events = vector_events(document(IMAGE_USE+group))
    assert_equal [4,6,26,8].map(&:to_r),events.first[:bounds]
    assert_equal 0,inventory(document(IMAGE_USE+group)).qualify(image,[])[:later_overlapping_paint_count]
    [group.sub('stroke-linecap="round"',''),group.sub('stroke-linecap="round"','stroke-linecap="square"')].each do |unsupported|
      assert_nil vector_events(document(IMAGE_USE+unsupported)).first[:bounds_policy]
      assert_raises(Subject::Unproven) { inventory(document(IMAGE_USE+unsupported)).qualify(image,[]) }
    end
  end

  def test_touching_or_intersecting_round_strokes_retain_the_broad_nontext_guard
    ['M5 9 L25 9','M5 9.5 L25 9.5','M15 0 L15 10'].each do |data|
      svg = document(IMAGE_USE+round_line(data))
      assert_nil vector_events(svg).first[:bounds_policy]
      error = assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
      assert_match(/nontext/,error.message)
    end
  end

  def test_exact_line_bounds_support_reflection_and_nonuniform_axis_scales
    svg = document(IMAGE_USE+round_line('M3 1 L8 1','transform="matrix(-2,0,0,3,30,0)"'))
    event = vector_events(svg).first
    assert_equal [12,0,26,6].map(&:to_r),event[:bounds]
    assert_equal 'exact_axis_aligned_round_single_segment_disjoint',event[:bounds_policy]
    assert_equal 0,inventory(svg).qualify(image,[])[:later_overlapping_paint_count]
  end

  def test_exact_line_decimal_translation_does_not_inherit_float_endpoint_rounding
    line = round_line('M10000000000000000 7 L10000000000000003 7',
      'transform="matrix(1,0,0,1,-9999999999999993,0)"')
    event = vector_events(document(IMAGE_USE+line)).first
    assert_equal [6,6,11,8].map(&:to_r),event[:bounds]
    assert_equal 'exact_axis_aligned_round_single_segment_disjoint',event[:bounds_policy]
    assert event[:conservative_bounds][3] > 10
  end

  def test_unknown_curve_multisegment_closed_relative_and_degenerate_lines_keep_broad_bounds
    ['M5 7 L15 7 L25 7','M5 7 L25 7 Z','M5 7 C10 7 20 7 25 7',
     'm5 7 l20 0','M5 7 L5 7'].each do |data|
      assert_nil vector_events(document(IMAGE_USE+round_line(data))).first[:bounds_policy]
    end
    zero = round_line.sub('stroke-width="2"','stroke-width="0"')
    assert_nil vector_events(document(IMAGE_USE+zero)).first[:bounds_policy]
  end

  def test_unknown_or_inherited_paint_semantics_cannot_enable_exact_line_exclusion
    [round_line('M5 7 L25 7','vector-effect="non-scaling-stroke"'),
     '<g marker-end="url(#mark)">'+round_line+'</g>',
     '<g stroke-dasharray="1 1">'+round_line+'</g>'].each do |line|
      svg = document(IMAGE_USE+line)
      assert_nil vector_events(svg).first[:bounds_policy]
      assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
    end
  end

  def test_transformed_referenced_or_nested_parent_frames_do_not_gain_exact_line_bounds
    [ '<g transform="translate(0,0)">'+round_line+'</g>',
      '<svg x="0" y="0">'+round_line+'</svg>',
      '<use xlink:href="#line"/>'
    ].each do |branch|
      defs = IMAGE_DEF+'<g id="line">'+round_line+'</g>'
      svg = document(IMAGE_USE+branch,defs)
      assert_nil vector_events(svg).first[:bounds_policy]
      assert_raises(Subject::Unproven) { inventory(svg).qualify(image,[]) }
    end
  end

  def test_skew_rotated_singular_and_composed_raw_line_matrices_keep_original_route
    ['matrix(1,1,0,1,0,0)','matrix(0,1,-1,0,20,0)',
     'matrix(0,0,0,1,0,0)','matrix(1,0,0,1,0,0) translate(0,0)'].each do |matrix|
      assert_nil vector_events(document(IMAGE_USE+round_line('M5 7 L25 7','transform="'+matrix+'"'))).first[:bounds_policy]
    end
  end

  def test_existing_generic_shape_box_is_not_narrowed_by_the_optional_disjoint_proof
    subject = inventory(document(IMAGE_USE))
    node = {:name=>'path',:attrs=>{'d'=>'M5 7 L25 7'},:children=>[]}
    ctx = {:matrix=>Subject::IDENTITY,'stroke'=>'black','stroke-width'=>'2','stroke-miterlimit'=>'10','stroke-linecap'=>'round'}
    broad = subject.shape_box(node,ctx)
    assert_operator broad[3],:>,20
    event = vector_events(document(IMAGE_USE+round_line)).first
    assert_equal broad,event[:conservative_bounds]
    assert_equal [4,6,26,8].map(&:to_r),event[:bounds]
  end
end
