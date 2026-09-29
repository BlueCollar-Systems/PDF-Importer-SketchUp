#!/usr/bin/env ruby
# test/inline_image_stitch_test.rb
#
# Runs of adjacent 1-px-tall inline images (BI/ID/EI) - e.g. the AG&E
# title-block logo on pages 5-6 of WINDOW SUPPORT DETAILS BOUND.pdf - are
# stitched into ONE picture placed at the exact source position/scale while
# the page's vectors and text stay editable. Anything that cannot be
# stitched stays an honest omission, and every ledger balances.

require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
require 'json'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
$LOAD_PATH.unshift(File.join(REPO_ROOT, 'extracted', 'sketchup_ext'))

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/embedded_image_extractor'
require 'bc_pdf_vector_importer/qa_report'
require 'bc_pdf_vector_importer/report_dialog'
require_relative '../tools/sketchup_host_evidence'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

class InlineImageStitchTest < Minitest::Test
  M = BlueCollarSystems::PDFVectorImporter
  C = M::InlineImageComposer
  QA = M::QAReport
  R = M::ReportDialog

  # Minimal PDF stand-in: one page, one content stream, real decoders.
  class OnePagePDF
    def initialize(stream)
      @stream = stream
      @decoder = M::PDFParser.allocate
    end

    def page_data(_page)
      { :content_streams => [@stream] }
    end

    def page_resources(_page)
      {}
    end

    def resolve_object(ref)
      ref
    end

    def get_stream_data(_num)
      nil
    end

    def apply_png_predictor(*args)
      @decoder.apply_png_predictor(*args)
    end

    def ascii_hex_decode(data)
      @decoder.ascii_hex_decode(data)
    end
  end

  def strip(seq, ctm, width, height, pixels, channels = 1)
    C::Strip.new(seq, ctm, width, height, channels, pixels.pack('C*'),
                 C.strip_bbox(ctm), { :clips => [], :unknown => [] })
  end

  # ---- header / decode ----------------------------------------------------

  def test_header_abbreviations_are_expanded
    dict = C.parse_header('/W 658 /H 1 /CS /G /BPC 8 /F /Fl /DP << /Predictor 15 /Columns 658 >> /L 150')
    assert_equal 658, dict['/Width'].to_i
    assert_equal 1, dict['/Height'].to_i
    assert_equal '/DeviceGray', C::COLOR_SPACE_ABBREVIATIONS[dict['/ColorSpace']] || dict['/ColorSpace']
    assert_equal 15, dict['/DecodeParms']['/Predictor'].to_i
  end

  def test_flate_png_predictor_row_decodes_like_the_source_logo
    row = [0, 10, 20, 250].pack('C*')
    # PNG "Sub" filter (1): each byte stores the delta from its left neighbour.
    filtered = [1, 0, 10, 10, 230].pack('C*')
    data = Zlib::Deflate.deflate(filtered)
    dict = C.parse_header("/W 4 /H 1 /CS /G /BPC 8 /F /Fl /DP << /Predictor 15 /Columns 4 >> /L #{data.bytesize}")
    width, height, channels, samples = C.decode(dict, data, OnePagePDF.new(''))
    assert_equal [4, 1, 1], [width, height, channels]
    assert_equal row, samples
  end

  def test_unsupported_encodings_are_reported_not_guessed
    dict = C.parse_header('/W 4 /H 1 /CS /G /BPC 1 /F /DCT')
    assert_raises(C::Unsupported) { C.decode(dict, 'xx', OnePagePDF.new('')) }
  end

  # ---- scanner ------------------------------------------------------------

  def test_scanner_yields_inline_image_header_and_data
    body = [7, 8, 9].pack('C*')
    stream = "q 1 0 0 1 0 0 cm BI /W 3 /H 1 /CS /G /BPC 8 ID #{body} EI Q 0 0 m 1 1 l S"
    seen = []
    M::ContentStreamParser.scan_operators(stream, 'BI' => true, 'BI_IMAGE' => true, 'S' => true) do |op, operands|
      seen << [op, operands]
    end
    ops = seen.map(&:first)
    assert_equal %w[BI BI_IMAGE S], ops
    header, data = seen[1][1]
    assert_match(%r{/W 3}, header)
    assert_equal body, data.byteslice(0, 3)
  end

  # ---- geometry / composition -------------------------------------------

  def test_mirrored_one_pixel_rows_stack_in_source_order
    # Three 1-px rows, d = -1 (mirrored), stacked upward like the logo.
    strips = [
      strip(1, [3.0, 0, 0, -1.0, 10.0, 21.0], 3, 1, [10, 11, 12]),
      strip(2, [3.0, 0, 0, -1.0, 10.0, 22.0], 3, 1, [20, 21, 22]),
      strip(3, [3.0, 0, 0, -1.0, 10.0, 23.0], 3, 1, [30, 31, 32])
    ]
    assert strips.all? { |s| C.axis_aligned?(s.ctm) }
    assert_equal 1, C.clusters(strips).length
    out = C.compose(strips)
    assert_equal [3, 3, 2], [out[:width], out[:height], out[:channels]]
    assert_equal [10.0, 20.0, 13.0, 23.0], out[:bbox]
    assert_equal [3.0, 0.0, 0.0, 3.0, 10.0, 20.0], out[:ctm]
    gray = out[:bytes].unpack('C*').each_slice(2).map(&:first)
    # PNG row 0 is the TOP of the picture = the highest strip (y 22..23).
    assert_equal [30, 31, 32, 20, 21, 22, 10, 11, 12], gray
    refute out[:fully_transparent]
  end

  def test_overlapping_pieces_paint_in_source_order_and_gaps_stay_transparent
    strips = [
      strip(1, [4.0, 0, 0, 1.0, 0.0, 0.0], 4, 1, [1, 1, 1, 1]),
      strip(2, [2.0, 0, 0, 1.0, 1.0, 0.0], 2, 1, [9, 9]),
      strip(3, [1.0, 0, 0, 1.0, 0.0, 2.0], 1, 1, [5])
    ]
    out = C.compose(strips)
    assert_equal [4, 3], [out[:width], out[:height]]
    px = out[:bytes].unpack('C*').each_slice(2).to_a
    assert_equal [5, 255], px[0]                 # top row: the lone piece
    assert_equal [0, 0], px[1]                   # uncovered gap is transparent
    assert_equal [0, 0], px[4]                   # empty middle row
    assert_equal [[1, 255], [9, 255], [9, 255], [1, 255]], px[8, 4]
  end

  def test_rounded_narrow_pieces_still_share_one_resolution
    # Writer rounded a 17-px piece to 2.04 pt at a 0.1138 pt/px pitch.
    wide = strip(1, [74.88, 0, 0, -0.12, 0.0, 0.12], 658, 1, [0] * 658)
    narrow = strip(2, [2.04, 0, 0, -0.12, 80.0, 0.12], 17, 1, [0] * 17)
    out = C.compose([wide, narrow])
    assert_operator out[:width], :>, 658
    assert_raises(C::Unsupported) do
      C.compose([wide, strip(3, [10.0, 0, 0, -0.12, 0.0, 0.24], 17, 1, [0] * 17)])
    end
  end

  def test_distant_pieces_form_separate_pictures
    a = strip(1, [1.0, 0, 0, 1.0, 0.0, 0.0], 1, 1, [1])
    b = strip(2, [1.0, 0, 0, 1.0, 1.0, 0.0], 1, 1, [2])
    far = strip(3, [1.0, 0, 0, 1.0, 500.0, 500.0], 1, 1, [3])
    groups = C.clusters([a, far, b])
    assert_equal [[1, 2], [3]], groups.map { |g| g.map(&:sequence).sort }.sort
  end

  def test_rotated_pieces_are_not_axis_aligned
    refute C.axis_aligned?([0.0, 1.0, -1.0, 0.0, 5.0, 5.0])
  end

  # ---- extractor end to end ---------------------------------------------

  def logo_stream
    rows = [[40, 50, 60, 70], [80, 90, 100, 110]]
    body = String.new('0 0 m 100 100 l S ')
    rows.each_with_index do |row, index|
      hex = row.map { |v| '%02X' % v }.join + '>'
      body << "q 4 0 0 -1 200 #{301 + index} cm BI /W 4 /H 1 /CS /G /BPC 8 /F /AHx ID #{hex} EI Q "
    end
    body << '300 300 m 400 400 l S'
    body
  end

  def test_extractor_places_one_stitched_picture_at_source_position
    Dir.mktmpdir do |dir|
      ex = M::EmbeddedImageExtractor.new(OnePagePDF.new(logo_stream), dir)
      assets = ex.extract_page(5, dir, true)
      assert_equal 2, ex.inline_image_count
      assert_equal 1, assets.length
      asset = assets.first
      assert_nil asset.obj_num
      assert_equal [4, 2], [asset.width, asset.height]
      assert_equal [200.0, 300.0, 204.0, 302.0], asset.bbox_pts
      assert_equal [[200.0, 300.0], [204.0, 300.0], [204.0, 302.0], [200.0, 302.0]], asset.corners_pts
      assert File.file?(asset.file_path)
      assert_equal '.png', File.extname(asset.file_path)
      assert M::EmbeddedImageExtractor.placeable_sketchup_image?(asset)
      assert_equal 'inline_image_composite', asset.original_clip_proof[:source_kind]
      meta = JSON.parse(File.read(asset.metadata_path))
      assert_equal 2, meta['inline_image_instance_count']
      assert_equal [{ :asset => asset, :strip_count => 2 }],
                   ex.inline_composites.map { |c| { :asset => c[:asset], :strip_count => c[:strip_count] } }
      assert_empty ex.inline_omissions
    end
  end

  def test_extractor_counts_without_writing_when_files_are_off
    ex = M::EmbeddedImageExtractor.new(OnePagePDF.new(logo_stream), nil)
    assert_empty ex.extract_page(5, nil, false)
    assert_equal 2, ex.inline_image_count
    assert_empty ex.inline_composites
  end

  def test_undecodable_pieces_become_an_omission_with_a_reason
    stream = 'q 4 0 0 1 0 0 cm BI /W 4 /H 1 /CS /G /BPC 8 /F /DCT ID xxxx EI Q'
    Dir.mktmpdir do |dir|
      ex = M::EmbeddedImageExtractor.new(OnePagePDF.new(stream), dir)
      assert_empty ex.extract_page(1, dir, true)
      assert_equal 1, ex.inline_omissions.length
      assert_equal 1, ex.inline_omissions.first[:count]
      assert_match(/DCT/, ex.inline_omissions.first[:reason])
    end
  end

  # ---- ledgers / reporting ----------------------------------------------

  def stitched(page = 5, count = 2175, images = 1)
    { :page => page, :inline_image_instance_count => count, :stitched_image_count => images,
      :vector_path_count => 15_012, :delivery => :inline_images_stitched, :stitched_images => [] }
  end

  def omission(page, count)
    { :page => page, :inline_image_instance_count => count, :vector_path_count => 10,
      :delivery => :inline_images_omitted, :reason => 'x' }
  end

  def test_qa_ledger_balances_stitched_pictures
    stats = { :inline_images_detected => 4350, :inline_image_page_raster_fallbacks => [],
              :inline_image_vector_retentions => [],
              :inline_image_stitched_deliveries => [stitched(5), stitched(6)] }
    assert QA.send(:fidelity_inline_image_ledger_valid?, stats)
    partial = stats.merge(:inline_images_detected => 4360,
                          :inline_image_vector_retentions => [omission(6, 10)])
    assert QA.send(:fidelity_inline_image_ledger_valid?, partial)
    refute QA.send(:fidelity_inline_image_ledger_valid?, stats.merge(:inline_images_detected => 4351))
    refute QA.send(:fidelity_inline_image_ledger_valid?,
                   stats.merge(:inline_image_stitched_deliveries => [stitched(5).merge(:delivery => :editable_geometry), stitched(6)]))
    refute QA.send(:fidelity_inline_image_ledger_valid?,
                   stats.merge(:inline_image_stitched_deliveries => [stitched(5), stitched(5)]))
  end

  def harness(detected, stitched_rows, retentions = [])
    {
      :inline_images_detected => detected, :inline_image_page_raster_fallbacks => [],
      :inline_image_vector_retentions => retentions,
      :inline_image_stitched_deliveries => stitched_rows
    }
  end

  def test_harness_ledger_counts_stitched_pictures
    assert SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                     harness(4350, [stitched(5), stitched(6)]))
    assert SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                     harness(2185, [stitched(5)], [omission(5, 10)]))
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!, harness(4350, [stitched(5)]))
    end
    assert_match(/stitched pictures/, error.message)
    assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                harness(2175, [stitched(5, 2175, 3000)]))
    end
  end

  def test_summary_reports_stitched_pictures_not_editable_geometry
    stats = { :pages => 6, :edges => 1, :text => 1,
              :inline_image_stitched_deliveries => [stitched(5), stitched(6)] }
    line = R.completion_status(stats)
    assert_includes line, 'Inline image pieces stitched into 2 picture(s) on pages 5-6 (vectors kept).'
    refute_includes line, 'not placed'
    summary = R.build_summary(stats)
    assert_includes summary, 'Page 5: 2175 inline image piece(s) stitched into 1 picture(s).'
    refute_includes summary, 'those inline images were not placed'
  end

  def test_main_and_batch_wire_the_stitched_ledger
    main = File.read(File.join(REPO_ROOT, 'extracted/sketchup_ext/bc_pdf_vector_importer/main.rb'))
    assert_includes main, ':delivery => :inline_images_stitched'
    assert_includes main, 'reconcile_stitched_inline_images!'
    assert_equal 2, main.scan(/inline_image_stitched_deliveries(:| =>) \[\]/).length
    batch = File.read(File.join(REPO_ROOT, 'tools/sketchup_batch_import.rb'))
    assert_includes batch, "'inline_image_stitched_deliveries' =>"
    qa = File.read(File.join(REPO_ROOT, 'extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb'))
    assert_includes qa, 'inline_image_stitched_deliveries:'
  end
end
