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
    def initialize(*); end
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
    :name
  )

  class Entities
    attr_reader :add_image_calls

    def initialize
      @add_image_calls = 0
    end

    def add_image(*)
      @add_image_calls += 1
      Object.new
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
