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

# Recording stand-in for SketchUp's HtmlDialog / inputbox. Only the window
# size, the registered callbacks and the inputbox prompts matter here.
module UI
  class HtmlDialog
    class << self
      attr_accessor :instances, :on_show
    end
    self.instances = []

    attr_reader :options, :sizes, :callbacks, :html, :closed

    def initialize(options)
      @options = options
      @sizes = []
      @callbacks = {}
      @closed = false
      self.class.instances << self
    end

    def set_size(width, height)
      @sizes << [width, height]
    end

    def set_html(html)
      @html = html
    end

    def add_action_callback(name, &block)
      @callbacks[name] = block
    end

    def show_modal
      hook = self.class.on_show
      hook.call(self) if hook
    end

    def close
      @closed = true
    end
  end

  class << self
    attr_accessor :inputbox_calls, :messages
  end
  self.inputbox_calls = []
  self.messages = []

  def self.inputbox(prompts, defaults, dropdowns, title)
    inputbox_calls << [prompts, defaults, dropdowns, title]
    nil
  end

  def self.messagebox(message, *_rest)
    messages << message
  end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_config'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class ImportDialogDefaultsTest < Minitest::Test
  BID = BlueCollarSystems::PDFVectorImporter::ImportDialog
  BIC = BlueCollarSystems::PDFVectorImporter::ImportConfig
  PREF_KEY = 'BlueCollarSystems_PDFVectorImporter'.freeze
  MAIN_SOURCE = File.read(File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__))

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
    UI::HtmlDialog.instances = []
    UI::HtmlDialog.on_show = nil
    UI.inputbox_calls = []
    UI.messages = []
  end

  def advanced_defaults(extra = {})
    {
      mode: 'Auto', pages: 'All', scale: '1.0', text_mode: 'Geometry',
      import_text: 'Yes', match_pdf_layers: 'Yes',
      grouping_mode: 'Group per page',
      page_arrangement: 'Spread (20% gap)'
    }.merge(extra)
  end

  def test_vector_quality_modes_default_to_3d_text
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

  def test_saved_labels_preference_is_preserved
    prefs = BID.send(:load_prefs)

    assert_equal 'Labels', prefs[:text_mode]
    assert_equal 'Labels',
                 Sketchup.default_value(PREF_KEY, 'text_mode')
    assert_equal 'Labels', BID.effective_text_mode(prefs)
  end

  def test_first_run_text_mode_defaults_to_3d_text
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

  def test_text_and_label_aliases_preserve_distinct_requested_modes
    { 'Text' => :text, 'text' => :text,
      'Label' => :labels, 'label' => :labels }.each do |raw, expected|
      opts = BID.send(:build_opts,
                      import_mode: 'auto',
                      import_text: 'Yes',
                      text_mode: raw)

      assert_equal expected, opts[:text_mode], "expected #{raw} -> #{expected}"
      assert_equal false, opts[:use_3d_text], raw
      assert_equal true, opts[:import_text], raw
    end
  end

  def test_saving_text_preserves_canonical_text_preference
    BID.send(:save_prefs, text_mode: 'Text')
    prefs = BID.send(:load_prefs)

    assert_equal 'Text', prefs[:text_mode]
    assert_equal 'Text', Sketchup.default_value(PREF_KEY, 'text_mode')
    assert_equal 'Text', BID.effective_text_mode(prefs)
  end

  def test_cli_snake_case_text_mode_aliases_match_pdfcadcore_contract
    {
      '3d_text' => :text3d,
      'text' => :text,
      'labels' => :labels,
      'glyphs' => :glyphs,
      'geometry' => :geometry,
      'raster' => :raster,
      'no_text' => :none
    }.each do |raw, expected|
      opts = BID.send(:build_opts,
                      import_mode: 'auto',
                      import_text: 'Yes',
                      text_mode: raw)
      assert_equal expected, opts[:text_mode], "expected #{raw} -> #{expected}"
    end
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
    expected = ['Text', 'Labels', '3D Text', 'Glyphs', 'Geometry', 'Raster']
    assert_equal expected, BID::TEXT_MODES.split('|')

    d = {
      mode: 'Auto', pages: 'All', scale: '1.0', text_mode: 'Geometry',
      import_text: 'Yes', match_pdf_layers: 'Yes',
      grouping_mode: 'Group per page',
      page_arrangement: 'Spread (20% gap)'
    }
    html = BID.send(:advanced_html, 'sample.pdf', d)
    expected.each { |mode| assert_includes html, ">#{mode}<" }

    basic = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Text', 'Yes', 'Yes')
    expected.each { |mode| assert_includes basic, ">#{mode}<" }
  end

  # One short plain line per text choice. Labels must never be promised as
  # editable SketchUp annotations: on SketchUp 2017 they arrive as 3D letters.
  def test_text_mode_hint_is_one_plain_line_per_choice
    lines = BID::TEXT_MODE_HINT_LINES
    prefixes = ['3D Text:', 'Text / Labels:', 'Glyphs:', 'Geometry:', 'Raster:']

    assert_equal prefixes.length, lines.length
    prefixes.zip(lines).each do |prefix, line|
      assert line.start_with?(prefix), "#{line.inspect} should start with #{prefix}"
      assert_operator line.length, :<=, 70, line
    end
    labels = lines.find { |line| line.start_with?('Text / Labels:') }
    assert_match(/SketchUp 2017/, labels)
    assert_match(/3D letters/, labels)
    refute_match(/editable/i, BID::TEXT_MODE_HINT)
    refute_match(/bbox|semantic|provenance|visual-equivalent|annotation/i,
                 BID::TEXT_MODE_HINT)
  end

  def test_basic_html_professional_flow
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Geometry', 'Yes', 'Yes')

    assert_includes html, BID::AUTO_MODE_HINT
    refute_includes html, 'picks vector, raster, or hybrid'
    refute_includes html, 'id="mode"'
    assert_includes html, '>Labels<'
    BID::TEXT_MODE_HINT_LINES.each { |line| assert_includes html, line }
  end

  # Old shop laptops often have a 1366x768 screen; a 1080p laptop at 150%
  # scaling has about 720 px. Minus the taskbar, a window taller than 640
  # would put its bottom edge off the screen. The buttons are pinned to the
  # bottom of the window, so a window that fits always shows them.
  def test_dialog_windows_fit_a_768_pixel_screen_and_show_their_buttons
    BID.show_html_basic('sample.pdf', {})
    BID.show_html_advanced('sample.pdf', 'All', '1.0', '3D Text', {})
    basic, advanced = UI::HtmlDialog.instances

    refute_empty basic.sizes, 'Basic window must set_size (SketchUp 2017 ignores width/height once a preferences_key is saved)'
    refute_empty advanced.sizes, 'Advanced window must set_size'
    assert_operator BID::DIALOG_MAX_HEIGHT, :<=, 768 - 128
    [basic, advanced].each do |dlg|
      height = dlg.sizes.last[1]
      assert_operator height, :<=, BID::DIALOG_MAX_HEIGHT
      assert_operator height, :>=, 560, 'tall enough that Basic needs no scrolling'
      assert_equal height, dlg.options[:height]
      assert_equal false, dlg.options[:resizable]
    end
    assert_match(/\.actions\{[^}]*position:fixed[^}]*bottom:0/, BID::DIALOG_CSS)
  end

  def test_enter_starts_the_import_from_the_advanced_window_too
    html = BID.send(:advanced_html, 'sample.pdf', advanced_defaults)

    assert_includes html, "e.key==='Enter' && e.target && e.target.tagName!=='BUTTON'"
    assert_includes html, 'e.preventDefault();doImport();'
  end

  def test_hints_do_not_over_promise
    assert_match(/scan/, BID::AUTO_MODE_HINT)
    assert_match(/cannot be placed separately/, BID::AUTO_MODE_HINT)
    refute_match(/only for scanned pages/, BID::AUTO_MODE_HINT)
    assert_match(/Picture of each page/, BID::GROUPING_HINT)
    assert_match(/one picture/, BID::GROUPING_HINT)
  end

  # Chromium 52 (SketchUp 2017) has no CSS grid and no flex gap; the buttons
  # stay pinned to the bottom of the window either way.
  def test_dialog_css_works_without_grid_or_gap
    css = BID::DIALOG_CSS

    refute_match(/display:\s*grid/, css)
    refute_match(/(?:^|[;{\s])gap\s*:/, css)
    assert_match(/\.actions\{[^}]*position:fixed/, css)
    assert_match(/\.actions\{[^}]*bottom:0/, css)
    assert_match(/body\{[^}]*padding-bottom:64px/, css)
    assert_includes css, '.btn+.btn{margin-left:8px}'
  end

  def test_enter_on_a_button_does_not_start_the_import
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Geometry', 'Yes', 'Yes')

    assert_includes html, "e.key==='Enter' && e.target && e.target.tagName!=='BUTTON'"
    assert_includes html, 'e.preventDefault();doImport();'
    refute_includes html, "if(e.key==='Enter')doImport();"
  end

  def test_cancel_never_returns_import_options
    UI::HtmlDialog.on_show = lambda do |dlg|
      dlg.callbacks['on_import'].call(nil, 'pages' => 'All', 'scale' => '1.0',
                                      'text_mode' => '3D Text',
                                      'import_text' => 'Yes',
                                      'match_pdf_layers' => 'Yes',
                                      'mode' => 'Auto')
      dlg.callbacks['on_cancel'].call(nil, {})
    end

    assert_nil BID.show_html_basic('sample.pdf', {})
    assert_nil BID.show_html_advanced('sample.pdf', 'All', '1.0', '3D Text', {})
  end

  def test_advanced_html_drops_dead_grouping_and_duplicate_hybrid_choices
    html = BID.send(:advanced_html, 'sample.pdf', advanced_defaults)

    refute_includes html, 'id="grouping_mode"'
    refute_includes html, 'Grouping Mode'
    refute_includes html, 'Hybrid'
    assert_includes html, BID::GROUPING_HINT
    assert_includes html, '<option value="Auto" selected>Auto (recommended)</option>'
    assert_includes html, '<option value="Vector">Lines and text only (skips pictures)</option>'
    assert_includes html, '<option value="Raster">Picture of each page</option>'

    saved_hybrid = BID.send(:advanced_html, 'sample.pdf', advanced_defaults(mode: 'Hybrid'))
    assert_includes saved_hybrid, '<option value="Auto" selected>Auto (recommended)</option>'
  end

  def test_saved_hybrid_mode_still_loads_and_builds
    assert_equal 'Hybrid', BID.valid_mode_name('Hybrid')
    assert BID::MODES.key?('Hybrid')
    opts = BID.send(:build_opts, import_mode: 'hybrid', import_text: 'Yes',
                                 text_mode: '3D Text',
                                 grouping_mode: 'Single group')
    assert_equal 'hybrid', opts[:import_mode]
    assert_equal 'Single group', opts[:grouping_mode]
  end

  # The Audit setting (item 17) gets its Advanced-window control once the
  # window rework (item 08) is in: default No, the saved choice shows next
  # time, and the choice reaches the import options and the saved setting.
  def test_advanced_window_offers_the_audit_setting_default_off
    html = BID.send(:advanced_html, 'sample.pdf', advanced_defaults)

    assert_includes html, "<label>#{BID::AUDIT_LABEL}</label>"
    assert_includes html, '<select id="audit"><option value="No" selected>No (recommended)</option>' \
                          '<option value="Yes">Yes</option></select>'
    assert_includes html, BID::AUDIT_HINT
    assert_includes html, "audit:document.getElementById('audit').value"

    saved_yes = BID.send(:advanced_html, 'sample.pdf', advanced_defaults(audit: 'Yes'))
    assert_includes saved_yes, '<option value="Yes" selected>Yes</option>'
    refute_includes saved_yes, '<option value="No" selected>'
  end

  def test_advanced_audit_choice_reaches_options_and_saved_setting
    saved_env = ENV.delete('BC_PDF_AUDIT')
    choice = nil
    UI::HtmlDialog.on_show = lambda do |dlg|
      dlg.callbacks['on_import'].call(nil, 'pages' => 'All', 'scale' => '1.0',
                                      'text_mode' => '3D Text', 'import_text' => 'Yes',
                                      'match_pdf_layers' => 'Yes', 'mode' => 'Auto',
                                      'page_arrangement' => 'Spread (20% gap)',
                                      'audit' => choice)
    end

    choice = 'Yes'
    opts = BID.show_html_advanced('sample.pdf', 'All', '1.0', '3D Text', {})
    assert_equal true, opts[:audit]
    assert_equal 'Yes', Sketchup.default_value(PREF_KEY, 'audit')
    shown = BID.show_html_advanced('sample.pdf', 'All', '1.0', '3D Text', BID.load_prefs)
    assert_equal true, shown[:audit]
    assert_includes UI::HtmlDialog.instances.last.html, '<option value="Yes" selected>Yes</option>'

    choice = 'No'
    opts = BID.show_html_advanced('sample.pdf', 'All', '1.0', '3D Text', BID.load_prefs)
    assert_equal false, opts[:audit]
    assert_equal 'No', Sketchup.default_value(PREF_KEY, 'audit')

    # A window that sends no Audit value saves and builds 'No', never ''.
    choice = nil
    opts = BID.show_html_advanced('sample.pdf', 'All', '1.0', '3D Text', {})
    assert_equal false, opts[:audit]
    assert_equal 'No', Sketchup.default_value(PREF_KEY, 'audit')
  ensure
    if saved_env.nil?
      ENV.delete('BC_PDF_AUDIT')
    else
      ENV['BC_PDF_AUDIT'] = saved_env
    end
  end

  # A saved Audit = Yes also applies to the Basic window's import, so that
  # window says Audit is on instead of leaving a slow mode on unseen.
  def test_basic_window_says_when_a_saved_audit_choice_is_on
    saved_env = ENV.delete('BC_PDF_AUDIT')
    off = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Text', 'Yes', 'Yes')
    refute_includes off, 'audit-note'
    refute_includes off, BID::AUDIT_ON_NOTE

    on = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Text', 'Yes', 'Yes', true)
    assert_includes on, BID::AUDIT_ON_NOTE
    assert_includes on, 'id="audit-note"'

    BID.show_html_basic('sample.pdf', BID.load_prefs)
    refute_includes UI::HtmlDialog.instances.last.html, BID::AUDIT_ON_NOTE

    Sketchup.write_default(PREF_KEY, 'audit', 'Yes')
    BID.show_html_basic('sample.pdf', BID.load_prefs)
    assert_includes UI::HtmlDialog.instances.last.html, BID::AUDIT_ON_NOTE
  ensure
    if saved_env.nil?
      ENV.delete('BC_PDF_AUDIT')
    else
      ENV['BC_PDF_AUDIT'] = saved_env
    end
  end

  # BC_PDF_AUDIT=1 turns Audit on whatever is saved, so the Advanced box
  # shows Yes and says the box cannot turn it off.
  def test_advanced_window_shows_audit_forced_on_by_the_environment
    saved_env = ENV['BC_PDF_AUDIT']
    ENV.delete('BC_PDF_AUDIT')
    plain = BID.send(:advanced_html, 'sample.pdf', advanced_defaults)
    refute_includes plain, BID::AUDIT_FORCED_NOTE

    ENV['BC_PDF_AUDIT'] = '1'
    forced = BID.send(:advanced_html, 'sample.pdf', advanced_defaults(audit: 'No'))
    assert_includes forced, '<option value="Yes" selected>Yes</option>'
    refute_includes forced, '<option value="No" selected>'
    assert_includes forced, BID::AUDIT_FORCED_NOTE
    assert_includes BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Text', 'Yes', 'Yes',
                             BID.audit_requested?({})), BID::AUDIT_ON_NOTE
  ensure
    if saved_env.nil?
      ENV.delete('BC_PDF_AUDIT')
    else
      ENV['BC_PDF_AUDIT'] = saved_env
    end
  end

  def test_inputbox_fallback_has_no_dead_grouping_prompt
    BID.show_inputbox_advanced('sample.pdf', 'All', '1.0', '3D Text', {})
    prompts, _defaults, dropdowns, _title = UI.inputbox_calls.last

    refute prompts.any? { |prompt| prompt =~ /Grouping/i }, prompts.inspect
    refute_includes dropdowns, BID::GROUPING_CHOICES
    assert_equal prompts.length, dropdowns.length
    refute_includes dropdowns.first.split('|'), 'Hybrid'
  end

  def test_compact_gap_is_tighter_than_spread
    compact = BID.send(:build_opts, import_mode: 'auto', page_arrangement: 'Compact gap')
    spread = BID.send(:build_opts, import_mode: 'auto', page_arrangement: 'Spread (20% gap)')
    imp = BlueCollarSystems::PDFVectorImporter

    assert_operator compact[:page_gap_ratio], :<, 0.20
    assert_in_delta 0.20, spread[:page_gap_ratio], 1e-9
    assert_in_delta 11.55,
                    imp.page_stack_step(11.0, imp.normalize_page_arrangement(compact[:page_arrangement]),
                                        compact[:page_gap_ratio]), 1e-6
    assert_in_delta 13.2,
                    imp.page_stack_step(11.0, imp.normalize_page_arrangement(spread[:page_arrangement]),
                                        spread[:page_gap_ratio]), 1e-6
  end

  def test_basic_html_selects_last_used_text_mode
    html = BID.send(:basic_html, 'sample.pdf', 'Auto', 'All', '1.0', 'Glyphs', 'Yes', 'Yes')

    assert_includes html, '<option value="Glyphs" selected>Glyphs</option>'
    refute_includes html, '<option value="Geometry" selected>Geometry</option>'
  end

  def test_advanced_html_keeps_mode_selector
    html = BID.send(:advanced_html, 'sample.pdf', advanced_defaults)

    assert_includes html, 'id="mode"'
    %w[Auto Vector Raster].each { |m| assert_includes html, "<option value=\"#{m}\"" }
  end

  def test_advanced_html_closed_shape_extrusion_disabled_independently
    d = {
      mode: 'Auto', pages: 'All', scale: '1.0', text_mode: 'Geometry',
      import_text: 'Yes', match_pdf_layers: 'Yes',
      grouping_mode: 'Group per page',
      page_arrangement: 'Spread (20% gap)',
      extrude_to_3d: 'No',
      extrude_depth_mm: ''
    }
    html = BID.send(:advanced_html, 'sample.pdf', d)

    # Closed-shape extrusion controls remain unavailable; 3D Text is separate.
    refute_includes html, 'id="extrude_to_3d"'
    refute_includes html, 'id="extrude_depth_mm"'
    assert_includes html, 'Closed-shape 3D Model controls intentionally disabled'
    assert_includes html, 'source-glyph 3D Text remains available'
  end

  def test_build_opts_maps_3d_model_controls
    opts = BID.send(:build_opts,
                    import_mode: 'auto',
                    extrude_to_3d: 'Yes',
                    extrude_depth_mm: '10.5')

    if BID::SHAPE_EXTRUSION_UI_ENABLED
      assert_equal true, opts[:extrude_to_3d]
      assert_in_delta 10.5, opts[:extrude_depth_mm], 0.001
    else
      assert_equal false, opts[:extrude_to_3d]
      assert_nil opts[:extrude_depth_mm]
    end
  end

  def test_closed_shape_extrusion_pipeline_remains_disabled
    assert_includes MAIN_SOURCE, 'SHAPE_EXTRUSION_ENABLED = false'
    assert_includes MAIN_SOURCE, 'if SHAPE_EXTRUSION_ENABLED && opts[:extrude_depth].to_f > 0.0'
    assert_includes MAIN_SOURCE, 'if SHAPE_EXTRUSION_ENABLED && opts[:extrude_to_3d]'
  end

  def test_basic_import_callback_uses_auto_mode
    mode_raw = BID::MODES['Auto']
    opts = BID.send(:build_opts, mode_raw.merge(
      pages: 'All', scale: '1.0', text_mode: 'Geometry', import_text: 'Yes'
    ))

    assert_equal 'auto', opts[:import_mode]
  end

  def test_non_raster_modes_never_authorize_implicit_page_raster_substitution
    %w[auto vector hybrid].each do |mode|
      opts = BID.send(:build_opts,
                      import_mode: mode,
                      import_text: 'Yes',
                      text_mode: '3D Text')
      assert_equal false, opts[:force_raster], mode
      assert_equal false, opts[:raster_fallback], mode

      config = BIC.from_mode(mode.capitalize)
      assert_equal 'No', config.raster_fallback, mode
      assert_equal 'No', config.force_raster, mode
    end
  end

  def test_raster_mode_is_an_explicit_requested_representation_not_a_fallback
    opts = BID.send(:build_opts, import_mode: 'raster')
    assert_equal true, opts[:force_raster]
    assert_equal false, opts[:raster_fallback]

    config = BIC.from_mode('Raster')
    assert_equal 'Yes', config.force_raster
    assert_equal 'No', config.raster_fallback
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

  def test_large_import_copy_names_exact_counts_cancel_and_page_retention
    message = BID.complexity_confirmation_message(
      :class => :very_large,
      :counts => { :paths => 20, :text_items => 1_200,
                   :glyph_placements => 5_000 },
      :work_units => 9_820
    )

    assert_includes message, 'Very large editable import'
    assert_includes message, '20 paths'
    assert_includes message, '1,200 text items'
    assert_includes message, '5,000 glyph placements'
    assert_includes message, 'Esc cancels the current partial page'
    assert_includes message, 'certified completed pages are kept'
  end

  def test_progress_status_uses_measured_eta_only_when_available
    measured = BID.progress_status(
      :stage => :text_item, :page => 2, :page_index => 2, :page_total => 3,
      :completed => 25, :total => 100, :percentage => 25.0,
      :elapsed_seconds => 10.2, :eta_seconds => 30.1
    )
    assert_equal(
      'PDF Import — page 2/3 — text item 25/100 — 25.0% — ' \
      'elapsed 10.2s — ETA 30.1s — Esc to cancel', measured
    )

    unmeasured = BID.progress_status(
      :stage => :geometry_path, :page => 1, :page_index => 1,
      :page_total => 1, :completed => 0, :total => 100,
      :percentage => 0.0, :elapsed_seconds => 0.0, :eta_seconds => nil
    )
    refute_includes unmeasured, 'ETA'
    assert_includes unmeasured, 'Esc to cancel'
  end

  def test_resume_is_enabled_only_for_grouped_editable_text_imports
    editable = BID.send(
      :build_opts,
      :import_mode => 'vector', :import_text => 'Yes',
      :text_mode => '3D Text', :group_per_page => 'Yes'
    )
    assert_equal true, editable[:resumable]

    no_text = BID.send(
      :build_opts,
      :import_mode => 'vector', :import_text => 'No',
      :text_mode => '3D Text', :group_per_page => 'Yes'
    )
    assert_equal false, no_text[:resumable]

    raster = BID.send(
      :build_opts,
      :import_mode => 'raster', :import_text => 'Yes',
      :text_mode => 'Raster', :group_per_page => 'Yes'
    )
    assert_equal false, raster[:resumable]

    ungrouped = BID.send(
      :build_opts,
      :import_mode => 'vector', :import_text => 'Yes',
      :text_mode => 'Geometry', :group_per_page => 'No'
    )
    assert_equal false, ungrouped[:resumable]
  end
end
