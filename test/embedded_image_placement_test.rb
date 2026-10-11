#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'zlib'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

module Geom
  class Point3d
    attr_accessor :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Transformation
    IDENTITY = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1].freeze
    def initialize(values = IDENTITY); @values = values.map(&:to_f); end
    def to_a; @values.dup; end
    def *(other)
      right = other.to_a
      self.class.new(Array.new(16) do |i|
        row, col = i % 4, i / 4
        (0..3).inject(0.0) { |sum, k| sum + @values[k * 4 + row] * right[col * 4 + k] }
      end)
    end
    def self.rotation(*); new; end
    def self.scaling(*); new; end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)
TextAlignLeft = 0 unless defined?(TextAlignLeft)

class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end
end unless Numeric.method_defined?(:degrees)

require 'bc_pdf_vector_importer/main'

module EmbeddedImagePlacementFixture
  Asset = Struct.new(
    :file_path,
    :fully_transparent,
    :placement_error,
    :name,
    :corners_pts,
    :width,
    :height
  )

  class Image
    attr_accessor :layer, :ignore_transform, :ignore_attributes
    attr_reader :transformation, :erased
    def initialize
      @transformation = Geom::Transformation.new([0.01,0,0,0,0,0.02,0,0,0,0,1,0,0,0,0,1])
      @erased = false
      @attributes = {}
    end
    def transform!(value); @transformation = value * @transformation unless @ignore_transform; end
    def valid?; !@erased; end
    def erase!; @erased = true; end
    def set_attribute(dictionary, key, value); @attributes[[dictionary, key]] = value unless @ignore_attributes; end
    def get_attribute(dictionary, key, default = nil); @attributes.fetch([dictionary, key], default); end
  end

  class Entities
    attr_reader :add_image_calls, :arguments, :image

    def initialize
      @add_image_calls = 0
      @image = Image.new
    end

    def add_image(*args)
      @add_image_calls += 1
      @arguments = args
      @image
    end
  end

  class Layers
    def [](name)
      name
    end

    def add(name)
      name
    end
  end

  class Model
    attr_reader :active_entities, :layers

    def initialize(entities)
      @active_entities = entities
      @layers = Layers.new
    end
  end
end

class EmbeddedImagePlacementTest < Minitest::Test
  def with_image
    Dir.mktmpdir('su_affine_image_') do |dir|
      path = File.join(dir, 'asymmetric.png')
      chunk = lambda { |kind, bytes| [bytes.bytesize].pack('N') + kind + bytes + [Zlib.crc32(kind + bytes)].pack('N') }
      pixels = [255,0,0,255,0,255,0,255].pack('C*')
      original = "\x89PNG\r\n\x1a\n".force_encoding(Encoding::BINARY) +
        chunk.call('IHDR', [2,1,8,6,0,0,0].pack('N2C5')) +
        chunk.call('IDAT', Zlib::Deflate.deflate("\x00".force_encoding(Encoding::BINARY) + pixels)) + chunk.call('IEND', ''.force_encoding(Encoding::BINARY))
      File.binwrite(path, original)
      asset = EmbeddedImagePlacementFixture::Asset.new(path, false, nil, 'Im1',
        [[300,200],[444,200],[444,128],[300,128]], 2, 1)
      entities = EmbeddedImagePlacementFixture::Entities.new
      yield asset, entities, EmbeddedImagePlacementFixture::Model.new(entities)
      assert_equal original, File.binread(path)
    end
  end

  def test_png_source_binding_uses_independently_decoded_pixels
    with_image do |asset, entities, model|
      importer = BlueCollarSystems::PDFVectorImporter
      importer.place_embedded_images(model, [asset], [0,0,720,360],
        { :scale => 1.0, :embedded_source_pdf_sha256 => 'a' * 64 }, 0, 0)
      image = entities.image
      assert_equal Digest::SHA256.file(asset.file_path).hexdigest,
        image.get_attribute('BC_PDF_Importer', 'embedded_source_artifact_sha256')
      assert_equal Digest::SHA256.hexdigest([255,0,0,255,0,255,0,255].pack('C*')),
        image.get_attribute('BC_PDF_Importer', 'embedded_source_visual_pixel_sha256')
      assert_equal 2, image.get_attribute('BC_PDF_Importer', 'embedded_source_pixel_width')
      assert_equal 1, image.get_attribute('BC_PDF_Importer', 'embedded_source_pixel_height')
      assert_equal 'a' * 64, image.get_attribute('BC_PDF_Importer', 'embedded_source_pdf_sha256')
    end
  end

  def test_source_binding_readback_failure_erases_partial_image
    with_image do |asset, entities, model|
      entities.image.ignore_attributes = true
      error = assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
        BlueCollarSystems::PDFVectorImporter.place_embedded_images(
          model, [asset], [0,0,720,360], { :scale => 1.0 }, 0, 0)
      end
      assert_match(/readback/, error.message)
      assert entities.image.erased
    end
  end

  def test_source_asset_change_during_host_load_erases_partial_image
    with_image do |asset, entities, model|
      original_bytes = File.binread(asset.file_path)
      original_add_image = entities.method(:add_image)
      entities.define_singleton_method(:add_image) do |*args|
        image = original_add_image.call(*args)
        File.binwrite(asset.file_path, 'changed while loading')
        image
      end
      error = assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
        BlueCollarSystems::PDFVectorImporter.place_embedded_images(
          model, [asset], [0,0,720,360], { :scale => 1.0 }, 0, 0)
      end
      assert_match(/changed while the host loaded/, error.message)
      assert entities.image.erased
      # Restore this fictional fixture so with_image still verifies its bytes.
      File.binwrite(asset.file_path, original_bytes)
    end
  end

  def test_jpeg_passes_original_encoded_bytes_to_host_without_claiming_a_pixel_decoder
    Dir.mktmpdir('su_encoded_image_') do |dir|
      path = File.join(dir, 'source.jpg')
      bytes = "\xff\xd8encoded source preserved\xff\xd9".force_encoding(Encoding::BINARY)
      File.binwrite(path, bytes)
      asset = EmbeddedImagePlacementFixture::Asset.new(path, false, nil, 'Im1',
        [[0,0],[72,0],[72,72],[0,72]], 2, 1)
      entities = EmbeddedImagePlacementFixture::Entities.new
      model = EmbeddedImagePlacementFixture::Model.new(entities)
      assert_equal 1, BlueCollarSystems::PDFVectorImporter.place_embedded_images(
        model, [asset], [0,0,720,360], { :scale => 1.0 }, 0, 0)
      assert_equal path, entities.arguments.first
      assert_equal bytes, File.binread(path)
      assert_equal Digest::SHA256.hexdigest(bytes),
        entities.image.get_attribute('BC_PDF_Importer', 'embedded_source_artifact_sha256')
      assert_nil entities.image.get_attribute('BC_PDF_Importer', 'embedded_source_visual_pixel_sha256')
    end
  end

  def test_native_image_keeps_intrinsic_pixel_scale_and_source_reflection
    with_image do |asset, entities, model|
      placed = BlueCollarSystems::PDFVectorImporter.place_embedded_images(
        model, [asset], [0,0,720,360], { :scale => 2.0 }, 7.0, 0)
      assert_equal 1, placed
      assert_equal [1.0,1.0], entities.arguments.last(2)
      actual = entities.image.transformation.to_a
      assert_in_delta 0.04, actual[0], 1.0e-12
      assert_in_delta(-0.04, actual[5], 1.0e-12)
      assert_in_delta 300.0 / 36, actual[12], 1.0e-12
      assert_in_delta 200.0 / 36 + 7, actual[13], 1.0e-12
    end
  end

  def test_host_losing_transform_fails_and_erases_partial_image
    with_image do |asset, entities, model|
      entities.image.ignore_transform = true
      assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
        BlueCollarSystems::PDFVectorImporter.place_embedded_images(
          model, [asset], [0,0,720,360], { :scale => 1.0 }, 0, 0)
      end
      assert entities.image.erased
    end
  end

  def test_unsafe_image_never_reaches_sketchup_add_image
    Dir.mktmpdir('su_unsafe_image_placement_') do |dir|
      path = File.join(dir, 'unsafe.png')
      File.open(path, 'wb') { |file| file.write('not used') }
      asset = EmbeddedImagePlacementFixture::Asset.new(
        path,
        false,
        'declared PDF soft mask could not be decoded safely',
        'Im1'
      )
      entities = EmbeddedImagePlacementFixture::Entities.new
      model = EmbeddedImagePlacementFixture::Model.new(entities)

      placed = BlueCollarSystems::PDFVectorImporter.place_embedded_images(
        model,
        [asset],
        {},
        { scale: 1.0 },
        0.0,
        0.0
      )

      assert_equal 0, placed
      assert_equal 0, entities.add_image_calls
    end
  end
end
