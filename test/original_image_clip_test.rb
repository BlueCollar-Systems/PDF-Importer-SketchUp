require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/embedded_image_extractor'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/source_image_paint_order'
require_relative 'support/synthetic_pdf_builder'

class OriginalImageClipTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Subject = Importer::SourceImagePaintOrder

  def with_asset(options = {})
    streams = options.fetch(:streams, ['/Fm Do'])
    page_media = options.fetch(:media, '[0 0 100 100]')
    crop = options[:crop] ? '/CropBox ' + options[:crop] : ''
    bbox = options.fetch(:bbox, '[0 0 100 100]')
    form_box = bbox ? '/BBox ' + bbox : ''
    matrix = options.fetch(:matrix, '[1 0 0 1 0 0]')
    program = options.fetch(:form_stream, 'q 10 0 0 10 10 10 cm /Im Do Q')
    page_refs = ([4] + (0...(streams.length-1)).map { |i| 8+i }).map { |v| "#{v} 0 R" }.join(' ')
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox #{page_media} >>",
      "<< /Type /Page /Parent 2 0 R #{crop} /Resources << /XObject << /Fm 5 0 R >> >> /Contents [#{page_refs}] >>",
      SyntheticPdfBuilder.stream_object('',streams.first),
      SyntheticPdfBuilder.stream_object("/Type /XObject /Subtype /Form #{form_box} /Matrix #{matrix} /Resources << /XObject << /Im 6 0 R /Child 7 0 R >> >>",program),
      SyntheticPdfBuilder.stream_object('/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB',[12,34,56].pack('C*')),
      SyntheticPdfBuilder.stream_object('/Type /XObject /Subtype /Form /BBox ' + options.fetch(:child_bbox,'[0 0 100 100]') + ' /Resources << /XObject << /Im 6 0 R >> >>','q 10 0 0 10 10 10 cm /Im Do Q')
    ]
    streams.drop(1).each { |stream| objects << SyntheticPdfBuilder.stream_object('',stream) }
    Dir.mktmpdir('original-image-clip-') do |dir|
      path = SyntheticPdfBuilder.write(File.join(dir,'fictional.pdf'),objects)
      parser = Importer::PDFParser.new(path)
      parser.parse
      extractor = Importer::EmbeddedImageExtractor.new(parser)
      assets = extractor.extract_page(1,nil,false)
      assert_equal 1, assets.length
      yield assets.first, path, extractor
    end
  end

  def binding(asset)
    p = asset.original_clip_proof
    { :original_clip_proof=>p, :parsed_pdf_sha256=>p[:parsed_pdf_sha256],
      :page_number=>asset.page_number, :image_object_number=>asset.obj_num,
      :placement_index=>asset.placement_index, :ctm=>asset.ctm, :corners_pts=>asset.corners_pts }
  end

  def test_real_parser_binds_exact_bytes_streams_and_inherited_page_form_boxes
    with_asset do |asset,path,_extractor|
      proof = asset.original_clip_proof
      assert_equal 'FULL_FOOTPRINT', proof[:status]
      assert_equal Digest::SHA256.file(path).hexdigest, proof[:parsed_pdf_sha256]
      assert_equal ['media_box','crop_box','form_bbox'], proof[:clip_polygons_pts].map { |c| c[:kind] }
      assert_equal ['page','form'], proof[:source_streams].map { |s| s[:kind] }
      assert_equal proof, Subject.original_clip_proof!(binding(asset))
    end
  end

  def test_original_bbox_or_crop_narrower_by_subpoint_is_not_rounded_away
    [{:bbox=>'[10.0001 10 20 20]'}, {:crop=>'[10.0001 10 20 20]'}, {:media=>'[10.0001 10 20 20]'}].each do |options|
      with_asset(options) do |asset,_path,_extractor|
        assert_equal 'UNPROVEN', asset.original_clip_proof[:status]
        assert_raises(Subject::Unproven) { Subject.original_clip_proof!(binding(asset)) }
      end
    end
  end

  def test_missing_malformed_or_degenerate_original_box_stays_unproved
    [{:bbox=>nil}, {:bbox=>'[0 0 bad 100]'}, {:bbox=>'[0 0 0 100]'}, {:matrix=>'[0 0 0 0 10 10]'}].each do |options|
      with_asset(options) { |asset,_path,_extractor| assert_equal 'UNPROVEN',asset.original_clip_proof[:status] }
    end
  end

  def test_nested_form_clip_cannot_be_skipped
    with_asset(:form_stream=>'/Child Do',:child_bbox=>'[10.01 10 20 20]') do |asset,_path,_extractor|
      assert_equal 'UNPROVEN',asset.original_clip_proof[:status]
      assert_equal [5,7],asset.original_clip_proof[:form_chain].map { |f| f[:obj_num] }
    end
  end

  def test_active_path_and_text_clips_are_unknown_and_q_restores_them
    ['W','W*','BT 7 Tr ET'].each do |clip|
      with_asset(:streams=>[clip+' n /Fm Do']) do |asset,_path,_extractor|
        assert_equal 'UNPROVEN',asset.original_clip_proof[:status]
      end
      with_asset(:streams=>['q '+clip+' n Q /Fm Do']) do |asset,_path,_extractor|
        assert_equal 'FULL_FOOTPRINT',asset.original_clip_proof[:status]
      end
    end
  end

  def test_pending_path_or_text_clip_is_not_erased_by_q_restore
    ['q W Q n /Fm Do','q W* Q n /Fm Do','BT q 7 Tr Q ET /Fm Do'].each do |program|
      with_asset(:streams=>[program]) { |asset,_path,_extractor| assert_equal 'UNPROVEN',asset.original_clip_proof[:status] }
    end
  end

  def test_contents_arrays_share_original_clip_and_matrix_state
    with_asset(:streams=>['q 2 0 0 2 3 4 cm','/Fm Do Q']) do |asset,_path,_extractor|
      assert_equal [23.0,24.0],asset.corners_pts.first
      assert_equal 'FULL_FOOTPRINT',asset.original_clip_proof[:status]
      assert_equal 2,asset.original_clip_proof[:source_streams].count { |s| s[:kind] == 'page' }
      assert_equal asset.original_clip_proof,Subject.original_clip_proof!(binding(asset))
    end
    with_asset(:streams=>['W','n /Fm Do']) { |asset,_path,_extractor| assert_equal 'UNPROVEN',asset.original_clip_proof[:status] }
  end

  def test_unknown_clip_inside_form_does_not_become_a_full_coverage_claim
    with_asset(:form_stream=>'W n q 10 0 0 10 10 10 cm /Im Do Q') do |asset,_path,_extractor|
      assert_equal 'UNPROVEN',asset.original_clip_proof[:status]
    end
  end

  def test_proof_revalidator_rejects_changed_occurrence_affine_and_source
    with_asset do |asset,_path,_extractor|
      original = binding(asset)
      [{:parsed_pdf_sha256=>'0'*64},{:image_object_number=>7},{:placement_index=>2},{:page_number=>2},
       {:ctm=>[10,0,0,10,11,10]},{:corners_pts=>[[11,10],[20,10],[20,20],[10,20]]}].each do |change|
        assert_raises(Subject::Unproven) { Subject.original_clip_proof!(original.merge(change)) }
      end
    end
  end

  def test_proof_revalidator_rejects_degenerate_or_unbound_form_polygon
    with_asset do |asset,_path,_extractor|
      [lambda { |p| p[:clip_polygons_pts][2][:corners_pts]=[[10,10]]*4 },
       lambda { |p| p[:clip_polygons_pts][2][:corners_pts]=[[0,0],[100,100],[0,100],[100,0]] },
       lambda { |p| p[:form_chain][0][:bbox]=[0,0,99,100] },
       lambda { |p| p[:source_streams].pop },
       lambda { |p| p[:source_streams][0][:sha256]='' }].each do |alter|
        copy = Marshal.load(Marshal.dump(binding(asset)))
        alter.call(copy[:original_clip_proof])
        assert_raises(Subject::Unproven) { Subject.original_clip_proof!(copy) }
      end
    end
  end
end
