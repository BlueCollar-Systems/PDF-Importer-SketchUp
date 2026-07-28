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

class FakeSoftMaskImagePDF < FakeImagePDF
  BASE_BYTES = [0, 0].pack('C*')
  MASK_BYTES = [0, 255].pack('C*')

  def get_raw_object(obj_num)
    bytes = obj_num == 4 ? MASK_BYTES : BASE_BYTES
    "#{obj_num} 0 obj\n<< /Length #{bytes.bytesize} >>\n" \
      "stream\n#{bytes}endstream\nendobj"
  end

  def extract_stream_filters(_raw, _dict)
    []
  end
end

class FakeCmykSoftMaskPDF < FakeImagePDF
  BASE_BYTES = [
    255, 0, 0, 0,
    0, 255, 255, 0
  ].pack('C*')
  MASK_BYTES = [255, 255].pack('C*')

  def get_raw_object(obj_num)
    bytes = obj_num == 4 ? MASK_BYTES : BASE_BYTES
    "#{obj_num} 0 obj\n<< /Length #{bytes.bytesize} >>\n" \
      "stream\n#{bytes}endstream\nendobj"
  end

  def extract_stream_filters(_raw, _dict)
    []
  end
end

class FakeIndexedCmykSoftMaskPDF < FakeImagePDF
  BASE_BYTES = [0, 1].pack('C*')
  MASK_BYTES = [255, 255].pack('C*')
  LOOKUP_BYTES = [
    255, 0, 0, 0,
    0, 255, 255, 0
  ].pack('C*')

  def get_raw_object(obj_num)
    bytes = case obj_num
            when 4 then MASK_BYTES
            when 6 then LOOKUP_BYTES
            else BASE_BYTES
            end
    "#{obj_num} 0 obj\n<< /Length #{bytes.bytesize} >>\n" \
      "stream\n#{bytes}endstream\nendobj"
  end

  def extract_stream_filters(_raw, _dict)
    []
  end
end

class FakeTransparentSoftMaskPDF < FakeImagePDF
  BASE_BYTES = [0, 0].pack('C*')
  MASK_BYTES = [0, 0].pack('C*')

  def get_raw_object(obj_num)
    bytes = obj_num == 4 ? MASK_BYTES : BASE_BYTES
    "#{obj_num} 0 obj\n<< /Length #{bytes.bytesize} >>\n" \
      "stream\n#{bytes}endstream\nendobj"
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

  def test_applies_pdf_soft_mask_alpha_to_decoded_raw_png
    pdf = FakeSoftMaskImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => FakeSoftMaskImagePDF::BASE_BYTES,
      4 => FakeSoftMaskImagePDF::MASK_BYTES
    )

    Dir.mktmpdir('su_embedded_soft_mask_') do |dir|
      assets = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)

      assert_equal 1, assets.length
      assert_equal '.png', File.extname(assets.first.file_path)
      assert_equal 6, File.binread(assets.first.file_path, 26).getbyte(25)

      decoded = File.join(dir, 'decoded.rgba')
      BlueCollarSystems::PDFVectorImporter::PngCropper
        .prepare_rgba!(assets.first.file_path, decoded, false)
      assert_equal(
        [0, 0, 0, 0, 0, 0, 0, 255],
        File.binread(decoded).bytes
      )

      metadata = JSON.parse(File.binread(assets.first.metadata_path))
      assert_equal 4, metadata['soft_mask_object']
    end
  end

  def test_converts_device_cmyk_before_applying_soft_mask
    pdf = FakeCmykSoftMaskPDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceCMYK',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => FakeCmykSoftMaskPDF::BASE_BYTES,
      4 => FakeCmykSoftMaskPDF::MASK_BYTES
    )

    Dir.mktmpdir('su_embedded_cmyk_mask_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      decoded = File.join(dir, 'decoded.rgba')
      BlueCollarSystems::PDFVectorImporter::PngCropper
        .prepare_rgba!(asset.file_path, decoded, false)
      assert_equal(
        [0, 255, 255, 255, 255, 0, 0, 255],
        File.binread(decoded).bytes
      )
    end
  end

  def test_resolves_indexed_cmyk_lookup_before_applying_soft_mask
    pdf = FakeIndexedCmykSoftMaskPDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '5 0 R',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        },
        '5 0 R' => ['/Indexed', '/DeviceCMYK', '1', '6 0 R']
      },
      3 => FakeIndexedCmykSoftMaskPDF::BASE_BYTES,
      4 => FakeIndexedCmykSoftMaskPDF::MASK_BYTES,
      6 => FakeIndexedCmykSoftMaskPDF::LOOKUP_BYTES
    )

    Dir.mktmpdir('su_embedded_indexed_cmyk_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      decoded = File.join(dir, 'decoded.rgba')
      BlueCollarSystems::PDFVectorImporter::PngCropper
        .prepare_rgba!(asset.file_path, decoded, false)
      assert_equal(
        [0, 255, 255, 255, 255, 0, 0, 255],
        File.binread(decoded).bytes
      )
    end
  end

  def test_marks_fully_transparent_soft_mask_image_as_not_placeable
    pdf = FakeTransparentSoftMaskPDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => FakeTransparentSoftMaskPDF::BASE_BYTES,
      4 => FakeTransparentSoftMaskPDF::MASK_BYTES
    )

    Dir.mktmpdir('su_embedded_transparent_mask_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first
      metadata = JSON.parse(File.binread(asset.metadata_path))

      assert_equal true, metadata['fully_transparent']
      refute(
        BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
          .placeable_sketchup_image?(asset)
      )
    end
  end

  def test_converts_unmasked_device_cmyk_to_rgb
    base = [
      255, 0, 0, 0,
      0, 255, 255, 0
    ].pack('C*')
    pdf = FakeRawImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceCMYK'
        }
      },
      3 => base
    )

    Dir.mktmpdir('su_embedded_unmasked_cmyk_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      assert_equal(
        [0, 255, 255, 255, 255, 0, 0, 255],
        decoded_rgba_bytes(asset, dir)
      )
    end
  end

  def test_converts_unmasked_indexed_cmyk_with_literal_lookup
    literal_lookup = '(\\377\\000\\000\\000\\000\\377\\377\\000)'
    pdf = FakeRawImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => [
            '/Indexed', '/DeviceCMYK', '1', literal_lookup
          ]
        }
      },
      3 => [0, 1].pack('C*')
    )

    Dir.mktmpdir('su_embedded_literal_indexed_cmyk_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      assert_equal(
        [0, 255, 255, 255, 255, 0, 0, 255],
        decoded_rgba_bytes(asset, dir)
      )
    end
  end

  def test_suppresses_indexed_image_with_truncated_lookup
    pdf = FakeRawImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => [
            '/Indexed', '/DeviceCMYK', '1', '<FF0000>'
          ]
        }
      },
      3 => [0, 1].pack('C*')
    )

    Dir.mktmpdir('su_embedded_bad_indexed_lookup_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      refute_placeable_with_error(asset, 'lookup')
    end
  end

  def test_suppresses_raw_image_when_declared_soft_mask_is_invalid
    pdf = FakeRawImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '1',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => [0, 0].pack('C*'),
      4 => [255].pack('C*')
    )

    Dir.mktmpdir('su_embedded_bad_soft_mask_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      refute_placeable_with_error(asset, 'soft mask')
    end
  end

  def test_suppresses_encoded_image_when_soft_mask_cannot_be_composited
    pdf = FakeImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceRGB',
          '/Filter' => '/DCTDecode',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      4 => [255, 255].pack('C*')
    )

    Dir.mktmpdir('su_embedded_encoded_soft_mask_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      refute_placeable_with_error(asset, 'encoded')
    end
  end

  def test_suppresses_image_that_exceeds_safe_conversion_budget
    limit = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor::
      MAX_IMAGE_PIXELS
    pdf = FakeRawImagePDF.new(
      'q 1 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => (limit + 1).to_s,
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => [0].pack('C*')
    )

    Dir.mktmpdir('su_embedded_budget_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      refute_placeable_with_error(asset, 'limit')
    end
  end

  def test_soft_mask_cache_distinguishes_equal_area_dimensions
    pdf = FakeRawImagePDF.new(
      'q /Im1 Do /Im2 Do Q',
      {
        '/XObject' => {
          '/Im1' => '3 0 R',
          '/Im2' => '5 0 R'
        }
      },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '5 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '1',
          '/Height' => '2',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => [0, 0].pack('C*'),
      4 => [255, 255].pack('C*'),
      5 => [0, 0].pack('C*')
    )

    Dir.mktmpdir('su_embedded_mask_cache_dimensions_') do |dir|
      assets = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)

      assert_equal 2, assets.length
      assert(
        BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
          .placeable_sketchup_image?(assets[0])
      )
      refute_placeable_with_error(assets[1], 'soft mask')
    end
  end

  def test_suppresses_soft_mask_with_multiple_bytes_per_pixel
    pdf = FakeRawImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => [0, 0].pack('C*'),
      4 => [255, 0, 255, 0].pack('C*')
    )

    Dir.mktmpdir('su_embedded_multichannel_mask_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      refute_placeable_with_error(asset, 'soft mask')
    end
  end

  def test_suppresses_packed_non_eight_bit_raw_samples
    pdf = FakeRawImagePDF.new(
      'q 1 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '1',
          '/Height' => '1',
          '/BitsPerComponent' => '4',
          '/ColorSpace' => '/DeviceCMYK'
        }
      },
      3 => [0xF0, 0x00].pack('C*')
    )

    Dir.mktmpdir('su_embedded_packed_samples_') do |dir|
      asset = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
        .new(pdf, dir)
        .extract_page(1)
        .first

      refute_placeable_with_error(asset, '8-bit')
    end
  end

  def test_resets_soft_mask_cache_between_pages
    pdf = FakeSoftMaskImagePDF.new(
      'q 2 0 0 1 0 0 cm /Im1 Do Q',
      { '/XObject' => { '/Im1' => '3 0 R' } },
      {
        '3 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray',
          '/SMask' => '4 0 R'
        },
        '4 0 R' => {
          '/Subtype' => '/Image',
          '/Width' => '2',
          '/Height' => '1',
          '/BitsPerComponent' => '8',
          '/ColorSpace' => '/DeviceGray'
        }
      },
      3 => FakeSoftMaskImagePDF::BASE_BYTES,
      4 => FakeSoftMaskImagePDF::MASK_BYTES
    )

    Dir.mktmpdir('su_embedded_page_mask_cache_') do |dir|
      extractor =
        BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor.new(
          pdf,
          dir
        )
      extractor.extract_page(1)
      cache = extractor.instance_variable_get(:@soft_mask_cache)
      cache['cross-page-sentinel'] = 'must be cleared'

      extractor.extract_page(2)

      refute cache.key?('cross-page-sentinel')
    end
  end

  private

  def decoded_rgba_bytes(asset, dir)
    decoded = File.join(dir, 'decoded.rgba')
    BlueCollarSystems::PDFVectorImporter::PngCropper
      .prepare_rgba!(asset.file_path, decoded, false)
    File.binread(decoded).bytes
  end

  def refute_placeable_with_error(asset, message_fragment)
    klass = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
    refute klass.placeable_sketchup_image?(asset)
    assert_includes asset.placement_error.to_s.downcase, message_fragment
  end
end
