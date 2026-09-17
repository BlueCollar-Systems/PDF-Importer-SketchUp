#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'

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
    :corners_pts
  )

  class Image
    attr_accessor :layer, :ignore_transform
    attr_reader :transformation, :erased
    def initialize
      @transformation = Geom::Transformation.new([0.01,0,0,0,0,0.02,0,0,0,0,1,0,0,0,0,1])
      @erased = false
    end
    def transform!(value); @transformation = value * @transformation unless @ignore_transform; end
    def valid?; !@erased; end
    def erase!; @erased = true; end
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
      File.binwrite(path, 'original pixel bytes remain untouched')
      asset = EmbeddedImagePlacementFixture::Asset.new(path, false, nil, 'Im1',
        [[300,200],[444,200],[444,128],[300,128]])
      entities = EmbeddedImagePlacementFixture::Entities.new
      yield asset, entities, EmbeddedImagePlacementFixture::Model.new(entities)
      assert_equal 'original pixel bytes remain untouched', File.binread(path)
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
