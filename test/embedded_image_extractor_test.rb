#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/embedded_image_extractor'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

class FakeImagePDF
  JPEG_BYTES = [0xFF, 0xD8, 0xFF, 0xD9].pack('C*')

  def initialize(root_stream, root_resources, objects, streams = {})
    @root_stream = root_stream
    @root_resources = root_resources
    @objects = objects
    @streams = streams
  end

  def page_data(_page_num)
    { content_streams: [@root_stream] }
  end

  def page_resources(_page_num)
    @root_resources
  end

  def resolve_object(ref)
    @objects[ref] || ref
  end

  def get_stream_data(obj_num)
    @streams[obj_num]
  end

  def get_raw_object(obj_num)
    bytes = JPEG_BYTES
    "3 0 obj\n<< /Length #{bytes.bytesize} /Filter /DCTDecode >>\nstream\n#{bytes}endstream\nendobj"
  end

  def parse_stream_length(raw)
    raw[/\/Length\s+(\d+)/, 1].to_i
  end

  def extract_stream_filters(_raw, _dict)
    ['/DCTDecode']
  end

  def to_dict(obj)
    obj.is_a?(Hash) ? obj : nil
  end
end

class FakeRawImagePDF < FakeImagePDF
  RGB_BYTES = [
    255, 0, 0,
    0, 255, 0
  ].pack('C*')

  def get_raw_object(_obj_num)
    bytes = RGB_BYTES
    "3 0 obj\n<< /Length #{bytes.bytesize} >>\nstream\n#{bytes}endstream\nendobj"
  end

  def extract_stream_filters(_raw, _dict)
    []
  end
end

class EmbeddedImageExtractorTest < Minitest::Test
  def test_supported_sketchup_image_extensions
    klass = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
    assert klass.supported_sketchup_image?('page_1_img.png')
    assert klass.supported_sketchup_image?('photo.JPG')
    refute klass.supported_sketchup_image?('notes.txt')
  end

  def test_extracts_direct_image_xobject_to_file_and_metadata
    pdf = FakeImagePDF.new(
      'q 10 0 0 20 30 40 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '2',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceRGB',
          '/Filter' => '/DCTDecode'
        }
      }
    )

    Dir.mktmpdir('su_embedded_img_') do |dir|
      assets = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)

      assert_equal 1, assets.length
      asset = assets.first
      assert_equal 'Im1', asset.name
      assert_equal [30.0, 40.0, 40.0, 60.0], asset.bbox_pts
      assert File.file?(asset.file_path), 'expected extracted image file'
      assert_equal FakeImagePDF::JPEG_BYTES, File.binread(asset.file_path)
      assert File.file?(asset.metadata_path), 'expected metadata sidecar'
    end
  end

  def test_extracts_image_nested_inside_form_xobject
    form_stream = 'q 5 0 0 6 7 8 cm /Im2 Do Q'
    pdf = FakeImagePDF.new(
      'q 2 0 0 3 11 13 cm /Fm1 Do Q',
      { '/XObject' => { '/Fm1' => '2 0 R' } },
      {
        '2 0 R' => {
          '/Subtype' => '/Form',
          '/Resources' => { '/XObject' => { '/Im2' => '3 0 R' } },
          '/Matrix' => [1, 0, 0, 1, 0, 0]
        },
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '1',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceRGB',
          '/Filter' => '/DCTDecode'
        }
      },
      2 => form_stream
    )

    Dir.mktmpdir('su_embedded_form_img_') do |dir|
      assets = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)

      assert_equal 1, assets.length
      assert_equal 'Im2', assets.first.name
      assert File.file?(assets.first.file_path)
    end
  end

  def test_converts_decoded_raw_rgb_xobject_to_a_sketchup_png
    pdf = FakeRawImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceRGB'
        }
      },
      3 => FakeRawImagePDF::RGB_BYTES
    )

    Dir.mktmpdir('su_embedded_raw_img_') do |dir|
      assets = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)

      assert_equal 1, assets.length
      asset = assets.first
      assert_equal '.png', File.extname(asset.file_path)
      assert_equal "\x89PNG\r\n\x1a\n".b, File.binread(asset.file_path, 8)

      decoded = File.join(dir, 'decoded.rgba')
      prepared = BlueCollarSystems::PDFVectorImporter::PngCropper
        .prepare_rgba!(asset.file_path, decoded, false)
      assert_equal 2, prepared[:pixel_width]
      assert_equal 1, prepared[:pixel_height]
      assert_equal(
        [255, 0, 0, 255, 0, 255, 0, 255],
        File.binread(decoded).bytes
      )
    end
  end
end
