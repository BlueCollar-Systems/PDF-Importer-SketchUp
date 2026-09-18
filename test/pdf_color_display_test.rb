require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class PdfColorDisplayTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Model = Struct.new(:rendering_options)
  INITIAL = {'EdgeColorMode'=>1, 'DisplayColorByLayer'=>true, 'RenderMode'=>4,
    'Texture'=>false, 'BackgroundColor'=>:dark, 'DrawGround'=>false}.freeze

  class Options < Hash
    attr_accessor :reject, :ignore
    def []=(key,value)
      raise 'native setter failed' if @reject == [key,value]
      return if @ignore == [key,value]
      super
    end
  end

  def test_source_material_display_is_enabled_without_recoloring_the_background
    options = Options.new.merge!(INITIAL)
    assert Importer.apply_pdf_color_display(Model.new(options))
    assert_equal 0, options['EdgeColorMode']
    assert_equal false, options['DisplayColorByLayer']
    assert_equal 2, options['RenderMode']
    assert_equal true, options['Texture']
    assert_equal :dark, options['BackgroundColor']
    assert_equal false, options['DrawGround']
  end

  def test_partial_native_setter_failure_restores_prior_style_and_reports_it
    options = Options.new.merge!(INITIAL)
    options.reject = ['RenderMode',2]
    warnings = []
    Importer::Logger.stub(:warn, lambda { |_area,message| warnings << message }) do
      refute Importer.apply_pdf_color_display(Model.new(options))
    end
    assert_equal INITIAL, options
    assert_equal 1, warnings.length
    assert_match(/native setter failed/, warnings.first)
    assert_match(/By Material/, warnings.first)
  end

  def test_ignored_native_setter_is_detected_and_prior_style_is_restored
    options = Options.new.merge!(INITIAL)
    options.ignore = ['EdgeColorMode',0]
    warnings = []
    Importer::Logger.stub(:warn, lambda { |_area,message| warnings << message }) do
      refute Importer.apply_pdf_color_display(Model.new(options))
    end
    assert_equal INITIAL, options
    assert_match(/not retained/, warnings.first)
  end

  def test_ignored_restore_is_reported_without_losing_original_setup_error
    options = Options.new.merge!(INITIAL)
    options.define_singleton_method(:[]=) do |key, value|
      if key == 'Texture' && value == true
        @restoring = true
        raise 'original texture setup failed'
      end
      return if @restoring && key == 'EdgeColorMode' && value == 1
      super(key, value)
    end
    warnings = []
    Importer::Logger.stub(:warn, lambda { |_area,message| warnings << message }) do
      refute Importer.apply_pdf_color_display(Model.new(options))
    end
    assert_equal 0, options['EdgeColorMode'], 'the native ignored restore is observable'
    INITIAL.each do |key,value|
      assert_equal value, options[key] unless key == 'EdgeColorMode'
    end
    assert_equal 2, warnings.length
    assert_match(/Could not restore display option EdgeColorMode.*not retained/, warnings.first)
    assert_match(/original texture setup failed/, warnings.last)
    assert_match(/By Material/, warnings.last)
  end

  def test_non_native_adapter_has_no_display_to_change
    refute Importer.apply_pdf_color_display(nil)
    refute Importer.apply_pdf_color_display(Object.new)
    refute Importer.apply_pdf_color_display(Model.new(nil))
  end
end
