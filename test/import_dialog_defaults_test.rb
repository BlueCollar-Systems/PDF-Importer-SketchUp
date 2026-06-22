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

  def test_vector_quality_modes_default_to_native_3d_text
    %w[Auto Vector Hybrid].each do |mode|
      assert_equal '3D Text', BID::MODES[mode]['text_mode']
      assert_equal '3D Text', BIC::MODES[mode]['text_mode']
    end
  end

  def test_missing_text_mode_builds_as_native_3d_text
    opts = BID.send(:build_opts, import_mode: 'auto', import_text: 'Yes')

    assert_equal :text3d, opts[:text_mode]
    assert_equal true, opts[:use_3d_text]
    assert_equal true, opts[:import_text]
  end

  def test_saved_labels_preference_is_preserved
    prefs = BID.send(:load_prefs)

    assert_equal 'Labels', prefs[:text_mode]
    assert_equal 'Labels',
                 Sketchup.default_value(PREF_KEY, 'text_mode')
    assert_equal 'Labels', BID.effective_text_mode(prefs)
  end

  def test_first_run_text_mode_defaults_to_native_3d_text
    Sketchup.reset_defaults({})

    prefs = BID.send(:load_prefs)

    assert_nil prefs[:text_mode]
    assert_equal '3D Text', BID.effective_text_mode(prefs)
  end

  def test_saved_3d_text_preference_is_preserved
    Sketchup.reset_defaults(
      [PREF_KEY, 'text_mode'] => '3D Text'
    )

    prefs = BID.send(:load_prefs)

    assert_equal '3D Text', prefs[:text_mode]
    assert_equal '3D Text',
                 Sketchup.default_value(PREF_KEY, 'text_mode')
    assert_equal '3D Text', BID.effective_text_mode(prefs)
  end

  def test_saved_glyphs_preference_is_preserved
    Sketchup.reset_defaults(
      [PREF_KEY, 'text_mode'] => 'Glyphs'
    )

    prefs = BID.send(:load_prefs)

    assert_equal 'Glyphs', prefs[:text_mode]
    assert_equal 'Glyphs', BID.effective_text_mode(prefs)
  end

  def test_save_prefs_round_trip_text_mode
    BID.send(:save_prefs, text_mode: 'Labels')
    prefs = BID.send(:load_prefs)

    assert_equal 'Labels', prefs[:text_mode]
    assert_equal 'Labels', BID.effective_text_mode(prefs)
  end

  def test_save_prefs_invalid_text_mode_uses_first_run_fallback
    BID.send(:save_prefs, text_mode: 'Bogus')
    prefs = BID.send(:load_prefs)

    assert_equal '3D Text', prefs[:text_mode]
    assert_equal '3D Text', Sketchup.default_value(PREF_KEY, 'text_mode')
  end

  def test_labels_option_builds_as_labels
    opts = BID.send(:build_opts,
                    import_mode: 'auto',
                    import_text: 'Yes',
                    text_mode: 'Labels')

    assert_equal :labels, opts[:text_mode]
    assert_equal false, opts[:use_3d_text]
    assert_equal true, opts[:import_text]
  end

  def test_no_text_option_disables_text_even_if_import_text_is_yes
    opts = BID.send(:build_opts,
                    import_mode: 'auto',
                    import_text: 'Yes',
                    text_mode: 'No text')

    assert_equal :none, opts[:text_mode]
    assert_equal false, opts[:import_text]
  end

  def test_legacy_preset_names_are_not_modes
    DEPRECATED_MODE_NAMES.each do |name|
      refute_includes BID::MODES.keys, name
      refute_includes BID::MODE_NAMES.split('|'), name
      refute_includes BIC::MODES.keys, name
    end
  end

  def test_text_rendering_dropdown_lists_all_modes
    expected = %w[Geometry Glyphs Labels 3D\ Text]
    assert_equal expected, BID::TEXT_MODES.split('|')

    d = {
      mode: 'Auto', pages: 'All', scale: '1.0', text_mode: 'Geometry',
      import_text: 'Yes', match_pdf_layers: 'Yes',
      grouping_mode: 'Group per page',
      page_arrangement: 'Spread (20% gap)'
    }
    html = BID.send(:advanced_html, 'sample.pdf', d)
    expected.each { |mode| assert_includes html, ">#{mode}<" }
  end

  def test_basic_html_professional_flow
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Geometry', 'Yes', 'Yes')

    assert_includes html, 'Professional import'
    refute_includes html, 'id="mode"'
    assert_includes html, '>Labels<'
  end

  def test_basic_html_selects_last_used_text_mode
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Glyphs', 'Yes', 'Yes')

    assert_includes html, '<option value="Glyphs" selected>Glyphs</option>'
    refute_includes html, '<option value="Geometry" selected>Geometry</option>'
  end

  def test_advanced_html_keeps_mode_selector
    d = {
      mode: 'Auto', pages: 'All', scale: '1.0', text_mode: 'Geometry',
      import_text: 'Yes', match_pdf_layers: 'Yes',
      grouping_mode: 'Group per page',
      page_arrangement: 'Spread (20% gap)'
    }
    html = BID.send(:advanced_html, 'sample.pdf', d)

    assert_includes html, 'id="mode"'
    %w[Auto Vector Raster Hybrid].each { |m| assert_includes html, m }
  end

  def test_basic_import_callback_uses_auto_mode
    mode_raw = BID::MODES['Auto']
    opts = BID.send(:build_opts, mode_raw.merge(
      pages: 'All', scale: '1.0', text_mode: 'Geometry', import_text: 'Yes'
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

  def test_match_pdf_layers_defaults_on
    opts = BID.send(:build_opts, import_mode: 'auto')
    assert_equal true, opts[:match_pdf_layers]
  end

  def test_basic_html_includes_match_pdf_layers
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Geometry', 'Yes', 'Yes')
    assert_includes html, 'id="match_pdf_layers"'
    assert_includes html, 'Match PDF Layers'
  end

  def test_first_run_match_pdf_layers_defaults_yes
    Sketchup.reset_defaults({})
    prefs = BID.send(:load_prefs)
    assert_nil prefs[:match_pdf_layers]
    assert_equal 'Yes', BID.effective_match_pdf_layers(prefs)
  end

  def test_save_prefs_round_trip_match_pdf_layers
    BID.send(:save_prefs, match_pdf_layers: 'No')
    prefs = BID.send(:load_prefs)

    assert_equal 'No', prefs[:match_pdf_layers]
    assert_equal 'No', BID.effective_match_pdf_layers(prefs)
  end

  def test_invalid_match_pdf_layers_preference_uses_first_run_fallback
    BID.send(:save_prefs, match_pdf_layers: 'Maybe')
    prefs = BID.send(:load_prefs)

    assert_equal 'Yes', prefs[:match_pdf_layers]
    assert_equal 'Yes', Sketchup.default_value(PREF_KEY, 'match_pdf_layers')
  end
end
