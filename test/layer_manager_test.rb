require 'minitest/autorun'

module Sketchup
  class LayerStub
    attr_accessor :name, :visible
    def initialize(name)
      @name = name
      @visible = true
    end
  end

  class LayersStub
    def initialize
      @layers = {}
    end

    def [](name)
      @layers[name]
    end

    def add(name)
      layer = LayerStub.new(name)
      @layers[name] = layer
      layer
    end

    def to_a
      @layers.values
    end
  end

  class ModelStub
    attr_reader :layers
    def initialize
      @layers = LayersStub.new
    end
  end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/layer_manager'

class LayerManagerTest < Minitest::Test
  LM = BlueCollarSystems::PDFVectorImporter::LayerManager

  def test_sanitize_strips_pdf_parens_and_forbidden_chars
    assert_equal 'Walls_Electrical',
                 LM.sanitize_layer_name('(Walls/Electrical)')
    assert_equal 'Layer_A_',
                 LM.sanitize_layer_name('Layer<A>')
  end

  def test_sanitize_empty_uses_fallback
    assert_equal 'PDF_Layer_3', LM.sanitize_layer_name('', fallback_index: 3)
  end

  def test_match_on_creates_sanitized_tags
    model = Sketchup::ModelStub.new
    mgr = LM.new(model, base_layer_name: 'PDF Import', match_pdf_layers: true)
    layer = mgr.resolve('Dimensions')
    assert_equal 'Dimensions', layer.name
    assert_includes mgr.imported_names, 'Dimensions'
  end

  def test_match_on_deduplicates_collisions
    model = Sketchup::ModelStub.new
    mgr = LM.new(model, match_pdf_layers: true)
    first = mgr.resolve('Layer/A')
    second = mgr.resolve('Layer:A')
    refute_equal first.name, second.name
    assert second.name.start_with?('Layer_A')
  end

  def test_match_off_ignores_pdf_layers
    model = Sketchup::ModelStub.new
    mgr = LM.new(model, base_layer_name: 'PDF Import', match_pdf_layers: false)
    assert_equal 'PDF Import', mgr.resolve('Walls').name
    assert_equal 'PDF Import', mgr.resolve(nil).name
    assert_equal 'PDF Import:Text', mgr.text_fallback_layer.name
  end
end
