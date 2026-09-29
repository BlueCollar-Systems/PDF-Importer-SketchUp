#!/usr/bin/env ruby
# Inline images (BI/ID/EI) are composited into native image assets: the
# strips of one picture become ONE PNG placed with the region's exact
# affine, JPEG inline images become files, and everything that cannot be
# composited safely is an omission with its reason. This pins the
# dictionary parser, the decoders, the clustering, the canvas geometry
# (including rotated placements), the RGBA gap handling, the budget, and
# the extractor's records that main.rb accounts after placement.

require 'minitest/autorun'
require 'tmpdir'
require 'zlib'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/embedded_image_extractor'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/png_cropper'
require_relative 'support/synthetic_pdf_builder'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

class InlineCompositeFakePDF
  def initialize(stream, resources = {}, objects = {}, streams = {})
    @stream = stream
    @resources = resources
    @objects = objects
    @streams = streams
  end

  def page_data(_page_num)
    { content_streams: [@stream] }
  end

  def page_resources(_page_num)
    @resources
  end

  def resolve_object(ref)
    @objects[ref] || ref
  end

  def get_stream_data(obj_num)
    @streams[obj_num]
  end

  def to_dict(obj)
    obj.is_a?(Hash) ? obj : nil
  end
end

class InlineImageCompositeTest < Minitest::Test
  Composite = BlueCollarSystems::PDFVectorImporter::InlineImageComposite
  Extractor = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
  PngCropper = BlueCollarSystems::PDFVectorImporter::PngCropper

  def bin(text)
    value = text.dup
    value.force_encoding(Encoding::BINARY)
    value
  end

  def strip(ctm, dict, data)
    bin("q #{ctm.map { |v| v.to_s }.join(' ')} cm BI #{dict} ID ") + bin(data) + bin(" EI Q\n")
  end

  def gray(values)
    values.pack('C*')
  end

  def extract(stream, resources = {}, objects = {})
    Dir.mktmpdir('su_inline_composite_') do |dir|
      extractor = Extractor.new(InlineCompositeFakePDF.new(stream, resources, objects), dir)
      assets = extractor.extract_page(1)
      yield extractor, assets, dir
    end
  end

  def rgba(asset, dir)
    raw = File.join(dir, "decoded_#{asset.placement_index}.rgba")
    PngCropper.prepare_rgba!(asset.file_path, raw, false)
    File.binread(raw).bytes
  end

  def assert_points(expected, actual)
    assert_equal expected.length, actual.length
    expected.zip(actual).each do |e, a|
      assert_in_delta e[0], a[0], 1.0e-9
      assert_in_delta e[1], a[1], 1.0e-9
    end
  end

  # ---- module -------------------------------------------------------

  def test_pixel_budget_matches_the_extractor
    assert_equal Extractor::MAX_IMAGE_PIXELS, Composite::MAX_PIXELS
  end

  def test_parses_and_expands_the_abbreviated_dictionary
    dict = Composite.normalize_dictionary(Composite.parse_dictionary(
      ' /W 658 /H 1 /BPC 8 /CS /G /F /Fl /DP <</Predictor 15 /Columns 658>> /D [1 0] /IM false'
    ))
    assert_equal 658, dict['/Width']
    assert_equal 1, dict['/Height']
    assert_equal 8, dict['/BitsPerComponent']
    assert_equal '/DeviceGray', dict['/ColorSpace']
    assert_equal ['/FlateDecode'], dict['/Filter']
    assert_equal({ '/Predictor' => 15, '/Columns' => 658 }, dict['/DecodeParms'])
    assert_equal [1, 0], dict['/Decode']
    assert_equal false, dict['/ImageMask']
    indexed = Composite.normalize_dictionary(Composite.parse_dictionary('/CS [/I /RGB 1 <ff0000 00ff00>] /F [/AHx /Fl]'))
    assert_equal ['/Indexed', '/DeviceRGB', 1, '<ff0000 00ff00>'], indexed['/ColorSpace']
    assert_equal ['/ASCIIHexDecode', '/FlateDecode'], indexed['/Filter']
  end

  def test_cluster_joins_touching_boxes_only
    boxes = [[0, 0, 4, 1], [0, 1, 4, 2], [0, 50, 4, 51], [0, 2.2, 4, 3]]
    regions = Composite.cluster(boxes, 0.5)
    assert_equal [[0, 1, 3], [2]], regions.map { |r| r[:members] }.sort
    assert_equal [0, 0, 4, 3], regions.find { |r| r[:members].include?(0) }[:box]
  end

  def test_canvas_plan_downsamples_above_the_budget_and_says_so
    plan = Composite.plan_canvas([0, 0, 20, 20], 1.0, 1.0, 100)
    assert plan[:downsampled]
    assert_operator plan[:width] * plan[:height], :<=, 100
    plan = Composite.plan_canvas([0, 0, 20, 20], 1.0, 1.0)
    refute plan[:downsampled]
    assert_equal [20, 20], [plan[:width], plan[:height]]
  end

  def test_unpacks_four_bit_gray_and_keeps_indexed_indices
    dict = Composite.normalize_dictionary(Composite.parse_dictionary('/W 2 /H 1 /BPC 4 /CS /G'))
    spec = Composite.describe(dict)
    assert_equal [0, 255], Composite.decode_samples(dict, bin("\x0F"), spec, 1, false).bytes
    assert_equal [0, 15], Composite.decode_samples(dict, bin("\x0F"), spec, 1, true).bytes
  end

  def test_decode_array_inversion_and_refusal
    dict = Composite.normalize_dictionary(Composite.parse_dictionary('/W 2 /H 1 /BPC 8 /CS /G /D [1 0]'))
    spec = Composite.describe(dict)
    assert_equal [255, 0], Composite.decode_samples(dict, bin("\x00\xFF"), spec, 1, false).bytes
    odd = Composite.normalize_dictionary(Composite.parse_dictionary('/W 2 /H 1 /BPC 8 /CS /G /D [0 0.5]'))
    assert_raises(Composite::Unsupported) { Composite.decode_samples(odd, bin("\x00\xFF"), Composite.describe(odd), 1, false) }
  end

  # ---- extractor ------------------------------------------------------

  def test_three_gray_rows_become_one_opaque_composite_in_source_order
    stream = strip([4, 0, 0, -1, 10, 3], '/W 4 /H 1 /BPC 8 /CS /G', gray([10, 20, 30, 40])) +
             strip([4, 0, 0, -1, 10, 2], '/W 4 /H 1 /BPC 8 /CS /G', gray([50, 60, 70, 80])) +
             strip([4, 0, 0, -1, 10, 1], '/W 4 /H 1 /BPC 8 /CS /G', gray([90, 100, 110, 120]))
    extract(stream) do |extractor, assets, dir|
      assert_equal 3, extractor.inline_image_count
      assert_empty extractor.inline_image_omissions
      assert_equal 1, assets.length
      asset = assets.first
      assert Extractor.placeable_sketchup_image?(asset)
      assert_nil asset.obj_num
      assert_equal [4, 3], [asset.width, asset.height]
      assert_equal [4.0, 0.0, 0.0, 3.0, 10.0, 0.0], asset.ctm
      assert_points [[10, 0], [14, 0], [14, 3], [10, 3]], asset.corners_pts
      assert_equal [10.0, 0.0, 14.0, 3.0], asset.bbox_pts
      info = asset.inline_composite
      assert_equal 'composite', info[:kind]
      assert_equal 3, info[:instance_count]
      assert_equal [1, 3], info[:member_sequences]
      assert_equal 3, info[:channels]
      assert_in_delta 1.0, info[:coverage], 1.0e-12
      refute info[:downsampled]
      assert_equal 2, File.binread(asset.file_path).getbyte(25), 'opaque composite is an RGB PNG'
      expected = []
      [[10, 20, 30, 40], [50, 60, 70, 80], [90, 100, 110, 120]].each do |row|
        row.each { |g| expected.concat([g, g, g, 255]) }
      end
      assert_equal expected, rgba(asset, dir)
      record = extractor.inline_image_composites.first
      assert_same asset, record[:asset]
      assert_equal 3, record[:instance_count]
      assert_equal info[:file_sha256], record[:sha256]
      assert File.file?(asset.metadata_path)
    end
  end

  def test_flate_png_predictor_rgb_strip_decodes_exactly
    row = [1, 255, 0, 0, 1, 255, 0].pack('C*') # Sub filter: (255,0,0) then (0,255,0)
    stream = strip([2, 0, 0, 1, 0, 0],
                   '/W 2 /H 1 /BPC 8 /CS /RGB /F /Fl /DP <</Predictor 15 /Columns 2 /Colors 3>>',
                   Zlib::Deflate.deflate(row))
    extract(stream) do |extractor, assets, dir|
      assert_equal 1, assets.length
      assert_empty extractor.inline_image_omissions
      assert_equal [255, 0, 0, 255, 0, 255, 0, 255], rgba(assets.first, dir)
    end
  end

  def test_gaps_between_nearby_strips_stay_transparent
    stream = strip([4, 0, 0, -1, 0, 1], '/W 4 /H 1 /BPC 8 /CS /G', gray([0, 0, 0, 0])) +
             strip([4, 0, 0, -1, 0, 7], '/W 4 /H 1 /BPC 8 /CS /G', gray([255, 255, 255, 255]))
    extract(stream) do |extractor, assets, dir|
      assert_equal 1, assets.length, 'strips 5 pt apart merge into one region'
      asset = assets.first
      assert_equal [4, 7], [asset.width, asset.height]
      assert_equal 4, asset.inline_composite[:channels]
      assert_in_delta 2.0 / 7.0, asset.inline_composite[:coverage], 1.0e-9
      assert_equal 6, File.binread(asset.file_path).getbyte(25), 'gapped composite is an RGBA PNG'
      pixels = rgba(asset, dir)
      assert_equal [255, 255, 255, 255], pixels[0, 4], 'top row is the higher strip'
      assert_equal 0, pixels[3 * 4 * 4 + 3], 'gap row is transparent'
      assert_equal [0, 0, 0, 255], pixels[6 * 4 * 4, 4], 'bottom row is the lower strip'
      assert_equal 2, extractor.inline_image_composites.first[:instance_count]
    end
  end

  def test_far_apart_pictures_become_separate_composites
    stream = strip([4, 0, 0, -1, 0, 1], '/W 4 /H 1 /BPC 8 /CS /G', gray([1, 2, 3, 4])) +
             strip([4, 0, 0, -1, 0, 101], '/W 4 /H 1 /BPC 8 /CS /G', gray([5, 6, 7, 8]))
    extract(stream) do |extractor, assets, _dir|
      assert_equal 2, assets.length
      assert_equal [[0.0, 0.0, 4.0, 1.0], [0.0, 100.0, 4.0, 101.0]], assets.map(&:bbox_pts).sort
      assert_equal 2, extractor.inline_image_composites.length
    end
  end

  def test_rotated_strips_keep_their_orientation_and_order
    # u along +y (rows run upward), v along -x: an Attachment-C style sheet.
    stream = strip([0, 4, -1, 0, 10, 0], '/W 4 /H 1 /BPC 8 /CS /G', gray([1, 2, 3, 4])) +
             strip([0, 4, -1, 0, 9, 0], '/W 4 /H 1 /BPC 8 /CS /G', gray([5, 6, 7, 8]))
    extract(stream) do |extractor, assets, dir|
      assert_equal 1, assets.length
      asset = assets.first
      assert_equal [4, 2], [asset.width, asset.height]
      [0.0, 4.0, -2.0, 0.0, 10.0, 0.0].zip(asset.ctm).each { |e, a| assert_in_delta e, a, 1.0e-9 }
      assert_points [[10, 0], [10, 4], [8, 4], [8, 0]], asset.corners_pts
      assert_in_delta 90.0, asset.inline_composite[:orientation_deg], 1.0e-9
      pixels = rgba(asset, dir)
      row0 = pixels[0, 16].each_slice(4).map(&:first)
      row1 = pixels[16, 16].each_slice(4).map(&:first)
      assert_equal [5, 6, 7, 8], row0, 'image top row is the strip at the v=1 side (x = 8..9)'
      assert_equal [1, 2, 3, 4], row1
      assert_empty extractor.inline_image_omissions
    end
  end

  def test_unsupported_variants_are_omissions_with_reasons_and_still_counted
    stream = strip([8, 0, 0, 1, 0, 0], '/W 8 /H 1 /IM true', bin("\xFF")) +
             strip([8, 0, 0, 1, 0, 20], '/W 8 /H 1 /BPC 1 /F /CCF', bin("\x00")) +
             strip([1, 0, 0, 1, 0, 40], '/W 1 /H 1 /BPC 8 /CS /G /F /LZW', bin("\x80")) +
             strip([1, 0, 0, 1, 0, 60], '/W 1 /H 1 /BPC 8 /CS /G /D [0 0.5]', bin("x")) +
             strip([4, 1, 0, -1, 0, 80], '/W 1 /H 1 /BPC 8 /CS /G', bin("x")) +
             strip([1, 0, 0, 1, 0, 100], '/W 1 /H 1 /BPC 8 /CS /CS9', bin("x")) +
             strip([2, 0, 0, 1, 0, 120], '/W 4 /H 1 /BPC 8 /CS /G', bin("ab")) +
             strip([1, 0, 0, 1, 0, 140], '/W 1 /H 1 /BPC 8 /CS /G', bin("y"))
    extract(stream) do |extractor, assets, _dir|
      assert_equal 8, extractor.inline_image_count
      assert_equal 1, assets.length, 'only the last strip is compositable'
      reasons = extractor.inline_image_omissions.map { |row| row[:reason] }
      assert_equal 7, extractor.inline_image_omissions.inject(0) { |sum, row| sum + row[:count] }
      assert reasons.any? { |r| r =~ /stencil mask/ }, reasons.inspect
      assert reasons.any? { |r| r =~ /CCITTFax/ }, reasons.inspect
      assert reasons.any? { |r| r =~ /LZW/ }, reasons.inspect
      assert reasons.any? { |r| r =~ /Decode array/ }, reasons.inspect
      assert reasons.any? { |r| r =~ /sheared/ }, reasons.inspect
      assert reasons.any? { |r| r =~ /not defined in the page resources/ }, reasons.inspect
      assert reasons.any? { |r| r =~ /data is short/ }, reasons.inspect
    end
  end

  def test_jpeg_inline_image_is_delivered_as_its_own_file
    jpeg = bin("\xFF\xD8\xFF\xD9")
    stream = strip([30, 0, 0, 20, 5, 5], '/W 1 /H 1 /BPC 8 /CS /RGB /F /DCT', jpeg)
    extract(stream) do |extractor, assets, _dir|
      assert_equal 1, assets.length
      asset = assets.first
      assert_equal '.jpg', File.extname(asset.file_path)
      assert asset.encoded
      assert_equal jpeg, File.binread(asset.file_path)
      assert_equal 'jpeg', asset.inline_composite[:kind]
      assert_points [[5, 5], [35, 5], [35, 25], [5, 25]], asset.corners_pts
      assert_equal 'jpeg', extractor.inline_image_composites.first[:kind]
      assert_empty extractor.inline_image_omissions
    end
  end

  def test_indexed_inline_lookup_and_named_resource_colour_space
    stream = strip([2, 0, 0, 1, 0, 0], '/W 2 /H 1 /BPC 8 /CS [/I /RGB 1 <ff000000ff00>]', bin("\x00\x01")) +
             strip([1, 0, 0, 1, 0, 50], '/W 1 /H 1 /BPC 8 /CS /CS0', bin("\x00\x00\xFF"))
    resources = { '/ColorSpace' => { '/CS0' => '/DeviceRGB' } }
    extract(stream, resources) do |extractor, assets, dir|
      assert_equal 2, assets.length
      by_y = assets.sort_by { |asset| asset.bbox_pts[1] }
      assert_equal [255, 0, 0, 255, 0, 255, 0, 255], rgba(by_y[0], dir)
      assert_equal [0, 0, 255, 255], rgba(by_y[1], dir)
      assert_empty extractor.inline_image_omissions
    end
  end

  def test_icc_based_resource_colour_space_resolves_its_component_count
    stream = strip([1, 0, 0, 1, 0, 0], '/W 1 /H 1 /BPC 8 /CS /CS1', bin("\x7F"))
    resources = { '/ColorSpace' => { '/CS1' => ['/ICCBased', '9 0 R'] } }
    objects = { '9 0 R' => { '/N' => 1 } }
    extract(stream, resources, objects) do |extractor, assets, dir|
      assert_equal 1, assets.length
      assert_equal [127, 127, 127, 255], rgba(assets.first, dir)
      assert_empty extractor.inline_image_omissions
    end
  end

  def test_no_capture_without_an_asset_directory
    stream = strip([1, 0, 0, 1, 0, 0], '/W 1 /H 1 /BPC 8 /CS /G', bin("x")) +
             strip([1, 0, 0, 1, 0, 5], '/W 1 /H 1 /BPC 8 /CS /G', bin("y"))
    extractor = Extractor.new(InlineCompositeFakePDF.new(stream), nil)
    assert_empty extractor.extract_page(1, nil, false)
    assert_equal 2, extractor.inline_image_count
    assert_empty extractor.inline_image_composites
    assert_empty extractor.inline_image_omissions
  end

  def test_real_parser_composites_strips_between_vector_paths
    Dir.mktmpdir('su_inline_real_') do |dir|
      content = bin("0 0 m 100 50 l S\n") +
                strip([4, 0, 0, -1, 10, 3], '/W 4 /H 1 /BPC 8 /CS /G', gray([10, 20, 30, 40])) +
                strip([4, 0, 0, -1, 10, 2], '/W 4 /H 1 /BPC 8 /CS /G', gray([1, 2, 3, 4])) +
                bin("10 10 m 20 20 l S\n")
      path = SyntheticPdfBuilder.write_pages(File.join(dir, 'strips.pdf'), [content])
      parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(path)
      parser.parse if parser.respond_to?(:parse)
      extractor = Extractor.new(parser, dir)
      assets = extractor.extract_page(1)
      assert_equal 2, extractor.inline_image_count
      assert_equal 1, assets.length
      assert_equal [10.0, 1.0, 14.0, 3.0], assets.first.bbox_pts
      assert_equal 2, assets.first.inline_composite[:instance_count]
      assert_equal 'FULL_FOOTPRINT', assets.first.original_clip_proof[:status]
      streams = parser.page_data(1)[:content_streams]
      tokens = BlueCollarSystems::PDFVectorImporter::ContentStreamParser.new(streams, parser)
        .send(:tokenize_content_stream, streams.first)
      assert_equal %w[m l S m l S], tokens.select { |t| t[:type] == :operator }.map { |t| t[:value] }.reject { |v| %w[q Q cm].include?(v) }
    end
  end
end
