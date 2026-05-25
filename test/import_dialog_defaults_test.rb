require 'minitest/autorun'

module Sketchup
  @defaults = {}

  def self.reset_defaults(hash = {})
    @defaults = hash
  end

  def self.read_default(key, name, default = nil)
    @defaults.fetch([key, name], default)
  end

  def self.write_default(key, name, value)
    @defaults[[key, name]] = value
  end

  def self.default_value(key, name)
    @defaults[[key, name]]
  end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_config'

class ImportDialogDefaultsTest < Minitest::Test
  BID = BlueCollarSystems::PDFVectorImporter::ImportDialog
  BIC = BlueCollarSystems::PDFVectorImporter::ImportConfig
  PREF_KEY = 'BlueCollarSystems_PDFVectorImporter'.freeze

  DEPRECATED_MODE_NAMES = [
    'Fast',
    'Balanced',
    'Full',
    'Max Fidelity',
    'Raster Image',
    'Custom...'
  ].freeze

  def setup
    Sketchup.reset_defaults(
      [PREF_KEY, 'text_mode'] => 'Labels'
    )
  end

  def test_vector_quality_modes_default_to_scale_stable_text
    %w[Auto Vector Hybrid].each do |mode|
      assert_equal '3D Text', BID::MODES[mode]['text_mode']
      assert_equal '3D Text', BIC::MODES[mode]['text_mode']
    end
  end

  def test_missing_text_mode_builds_as_3d_text
    opts = BID.send(:build_opts, import_mode: 'auto', import_text: 'Yes')

    assert_equal :text3d, opts[:text_mode]
    assert_equal true, opts[:use_3d_text]
    assert_equal true, opts[:import_text]
  end

  def test_legacy_labels_preference_migrates_once
    prefs = BID.send(:load_prefs)

    assert_equal '3D Text', prefs[:text_mode]
    assert_equal '3D Text',
                 Sketchup.default_value(PREF_KEY, 'text_mode')
    assert_equal 'Yes',
                 Sketchup.default_value(PREF_KEY, 'text_mode_default_migrated_v372')
  end

  def test_legacy_preset_names_are_not_modes
    DEPRECATED_MODE_NAMES.each do |name|
      refute_includes BID::MODES.keys, name
      refute_includes BID::MODE_NAMES.split('|'), name
      refute_includes BIC::MODES.keys, name
    end
  end

  def test_basic_html_professional_flow
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', '3D Text', 'Yes')

    assert_includes html, 'Professional import'
    refute_includes html, 'id="mode"'
  end

  def test_advanced_html_keeps_mode_selector
    d = {
      mode: 'Auto', pages: 'All', scale: '1.0', text_mode: '3D Text',
      import_text: 'Yes', grouping_mode: 'Group per page',
      page_arrangement: 'Spread (20% gap)'
    }
    html = BID.send(:advanced_html, 'sample.pdf', d)

    assert_includes html, 'id="mode"'
    %w[Auto Vector Raster Hybrid].each { |m| assert_includes html, m }
  end

  def test_basic_import_callback_uses_auto_mode
    mode_raw = BID::MODES['Auto']
    opts = BID.send(:build_opts, mode_raw.merge(
      pages: 'All', scale: '1.0', text_mode: '3D Text', import_text: 'Yes'
    ))

    assert_equal 'auto', opts[:import_mode]
  end

  def test_legacy_saved_mode_migrates_to_auto
    Sketchup.reset_defaults(
      [PREF_KEY, 'last_mode'] => 'Full',
      [PREF_KEY, 'last_preset'] => 'Max Fidelity'
    )

    prefs = BID.send(:load_prefs)

    assert_equal 'Auto', prefs[:last_mode]
    assert_equal 'Auto', Sketchup.default_value(PREF_KEY, 'last_mode')
    assert_equal 'Auto', Sketchup.default_value(PREF_KEY, 'last_preset')
  end
end
