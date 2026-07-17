require 'minitest/autorun'
require 'tmpdir'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/poppler_result_validator'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/poppler_semantic_proof'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/cairo_glyph_source'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class PopplerSemanticCompletionContractTest < Minitest::Test
  VALIDATOR = BlueCollarSystems::PDFVectorImporter::PopplerResultValidator
  PROOF = BlueCollarSystems::PDFVectorImporter::PopplerSemanticProof
  CAIRO = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource
  SVG = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer
  IMPORTER = BlueCollarSystems::PDFVectorImporter

  SpanItem = Struct.new(:text, :font_name, :source_span_id,
                        :bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1)

  FAILURE_KEYS = [
    :unmatched_source_runs,
    :unmatched_placements,
    :missing_language_packs,
    :skipped_placements,
    :placement_failures
  ].freeze

  DIAGNOSTIC_CLUSTER = [
    "Syntax Error: Missing language pack for 'Adobe-GB1' mapping",
    "Syntax Error: Unknown font tag 'china-s'",
    'Syntax Error (44846): No font in show/space'
  ].join("\n") + "\n"

  def exact_evidence
    {
      :renderer => :pdftocairo,
      :representation => :glyph_geometry,
      :glyphs => { 'glyph-a' => 'M0 0L1 0Z' },
      :placements => [
        { :glyph_id => 'glyph-a', :x => 10.0, :y => 20.0, :matrix => nil }
      ],
      :unmatched_source_runs => [],
      :unmatched_placements => [],
      :missing_language_packs => [],
      :skipped_placements => [],
      :placement_failures => []
    }
  end

  def test_failure_evidence_requires_every_key_to_be_present_array_and_empty
    assert PROOF.complete_failure_evidence?(exact_evidence)

    FAILURE_KEYS.each do |key|
      missing = exact_evidence
      missing.delete(key)
      refute PROOF.complete_failure_evidence?(missing), "missing #{key} passed"

      wrong_type = exact_evidence.merge(key => nil)
      refute PROOF.complete_failure_evidence?(wrong_type), "nil #{key} passed"

      nonempty = exact_evidence.merge(key => ['failure'])
      refute PROOF.complete_failure_evidence?(nonempty), "nonempty #{key} passed"
    end
  end

  def test_exact_certificate_cannot_treat_absent_failure_evidence_as_success
    Dir.mktmpdir('bc_poppler_proof') do |dir|
      pdf = File.join(dir, 'fixture.pdf')
      File.open(pdf, 'wb') { |file| file.write('%PDF-certified-source') }
      evidence = exact_evidence
      certificate = {
        :pdf_sha256 => PROOF.file_sha256(pdf),
        :page => 1,
        :glyph_count => 1,
        :placement_count => 1,
        :semantic_sha256 => PROOF.semantic_fingerprint(evidence),
        :allowed_unoutlined_glyph_ids => []
      }
      callback = PROOF.for_certificate(pdf, 1, certificate)

      assert callback.call(evidence)
      FAILURE_KEYS.each do |key|
        incomplete = evidence.dup
        incomplete.delete(key)
        refute callback.call(incomplete), "certificate accepted absent #{key}"
      end
    end
  end

  def test_cairo_builds_real_match_and_placement_evidence_after_rendering
    span = SpanItem.new('A', 'pdftotext', 'text_span:1:0',
                        8.0, 18.0, 14.0, 24.0)
    svg_result = {
      :renderer => :pdftocairo,
      :placements_pdf => [{ :x => 10.0, :y => 20.0 }],
      :semantic_svg_glyphs => { 'glyph-a' => 'M0 0L1 0Z' },
      :semantic_svg_placements => [
        { :glyph_id => 'glyph-a', :x => 10.0, :y => 20.0, :matrix => nil }
      ],
      :missing_language_packs => [],
      :skipped_placement_evidence => [],
      :unoutlined_placement_evidence => [],
      :placement_failure_evidence => []
    }

    evidence = CAIRO.semantic_completion_evidence(
      svg_result, [span], [0.0, 0.0, 100.0, 100.0]
    )

    assert PROOF.complete_failure_evidence?(evidence)
    assert_equal ['text_span:1:0'], evidence[:matched_source_span_ids]
    FAILURE_KEYS.each { |key| assert_kind_of Array, evidence[key] }
  end

  def test_cairo_evidence_fails_closed_for_unmatched_or_absent_render_evidence
    span = SpanItem.new('A', 'pdftotext', 'text_span:1:0',
                        8.0, 18.0, 14.0, 24.0)
    incomplete = {
      :renderer => :pdftocairo,
      :placements_pdf => [{ :x => 90.0, :y => 90.0 }],
      :semantic_svg_glyphs => {},
      :semantic_svg_placements => [],
      :missing_language_packs => [],
      :skipped_placement_evidence => nil,
      :unoutlined_placement_evidence => nil,
      :placement_failure_evidence => nil
    }

    evidence = CAIRO.semantic_completion_evidence(
      incomplete, [span], [0.0, 0.0, 100.0, 100.0]
    )

    refute PROOF.complete_failure_evidence?(evidence)
    refute_empty evidence[:unmatched_source_runs]
    refute_empty evidence[:unmatched_placements]
    refute_empty evidence[:skipped_placements]
    refute_empty evidence[:placement_failures]
  end

  def test_unoutlined_placements_require_exact_certificate_allowlist
    span = SpanItem.new('A B', 'pdftotext', 'text_span:1:0',
                        8.0, 18.0, 30.0, 24.0)
    svg_result = {
      :renderer => :pdftocairo,
      :placements_pdf => [{ :x => 10.0, :y => 20.0 }],
      :semantic_svg_glyphs => { 'glyph-a' => 'M0 0L1 0Z' },
      :semantic_svg_placements => [
        { :glyph_id => 'glyph-a', :x => 10.0, :y => 20.0,
          :matrix => nil },
        { :glyph_id => 'glyph-space', :x => 18.0, :y => 20.0,
          :matrix => nil }
      ],
      :unoutlined_placement_evidence => [
        { :index => 1, :glyph_id => 'glyph-space',
          :reason => :unoutlined_glyph }
      ],
      :missing_language_packs => [],
      :skipped_placement_evidence => [],
      :placement_failure_evidence => []
    }

    ordinary = CAIRO.semantic_completion_evidence(
      svg_result, [span], [0.0, 0.0, 100.0, 100.0]
    )
    refute_empty ordinary[:skipped_placements]

    certified = CAIRO.semantic_completion_evidence(
      svg_result, [span], [0.0, 0.0, 100.0, 100.0],
      ['glyph-space']
    )
    assert_empty certified[:skipped_placements]
    assert_equal ['glyph-space'], certified[:allowed_unoutlined_glyph_ids]
  end

  def test_deferred_validator_accepts_only_a_callable_full_proof
    Dir.mktmpdir('bc_poppler_deferred') do |dir|
      artifact = File.join(dir, 'owned.svg')
      File.open(artifact, 'wb') { |file| file.write('<svg/>') }
      run = {
        :ok => true, :timed_out => false, :exitstatus => 0,
        :stdout => '', :stderr => DIAGNOSTIC_CLUSTER, :error => nil
      }
      transport = VALIDATOR.validate(
        run,
        :context => 'test', :page => 1,
        :representation => :glyph_geometry,
        :artifacts => [artifact],
        :artifact_policy => :all_nonempty,
        :defer_semantic_completion => true
      )
      svg_result = { :poppler_transport_validation => transport }

      assert transport[:semantic_completion_deferred]
      refute SVG.finalize_deferred_semantic_validation(
        svg_result, true, exact_evidence
      ), 'literal true must not cross the active boundary'
      incomplete = exact_evidence
      incomplete.delete(:placement_failures)
      refute SVG.finalize_deferred_semantic_validation(
        svg_result, lambda { |_evidence| true }, incomplete
      ), 'a callable cannot compensate for missing required evidence'
      assert SVG.finalize_deferred_semantic_validation(
        svg_result,
        lambda do |evidence|
          PROOF.complete_failure_evidence?(evidence)
        end,
        exact_evidence
      )
    end
  end

  def test_main_finalizes_only_after_cairo_supplies_real_match_evidence
    Dir.mktmpdir('bc_poppler_main_final') do |dir|
      original = nil
      begin
      artifact = File.join(dir, 'owned.svg')
      File.open(artifact, 'wb') { |file| file.write('<svg/>') }
      transport = VALIDATOR.validate(
        {
          :ok => true, :timed_out => false, :exitstatus => 0,
          :stdout => '', :stderr => DIAGNOSTIC_CLUSTER, :error => nil
        },
        :context => 'test', :page => 1,
        :representation => :glyph_geometry,
        :artifacts => [artifact], :artifact_policy => :all_nonempty,
        :defer_semantic_completion => true
      )
      svg_result = {
        :renderer => :pdftocairo,
        :placements_pdf => [{ :x => 10.0, :y => 20.0 }],
        :semantic_svg_glyphs => { 'glyph-a' => 'M0 0L1 0Z' },
        :semantic_svg_placements => [
          { :glyph_id => 'glyph-a', :x => 10.0, :y => 20.0,
            :matrix => nil }
        ],
        :missing_language_packs => [],
        :skipped_placement_evidence => [],
        :unoutlined_placement_evidence => [],
        :placement_failure_evidence => [],
        :poppler_transport_validation => transport
      }
      span = SpanItem.new('A', 'pdftotext', 'text_span:1:0',
                          8.0, 18.0, 14.0, 24.0)
      captured = nil
      original = PROOF.method(:for_svg_page)
      PROOF.define_singleton_method(:for_svg_page) do |_pdf, _page|
        lambda do |evidence|
          captured = evidence
          PROOF.complete_failure_evidence?(evidence)
        end
      end

      assert IMPORTER.finalize_svg_poppler_semantics(
        svg_result, 'fixture.pdf', 1, [span], [0.0, 0.0, 100.0, 100.0]
      )
      refute_nil captured
      assert_equal ['text_span:1:0'], captured[:matched_source_span_ids]

      svg_result[:poppler_transport_validation] = transport
      svg_result.delete(:placement_failure_evidence)
      refute IMPORTER.finalize_svg_poppler_semantics(
        svg_result, 'fixture.pdf', 1, [span], [0.0, 0.0, 100.0, 100.0]
      )
      ensure
        PROOF.define_singleton_method(:for_svg_page, original) if original
      end
    end
  end

  def test_headless_cairo_rejects_zero_exit_poppler_diagnostic_cluster
    Dir.mktmpdir('bc_poppler_headless') do |dir|
      svg_path = File.join(dir, 'headless.svg')
      command_runner = BlueCollarSystems::PDFVectorImporter::CommandRunner
      original_renderer = SVG.method(:find_svg_renderer)
      original_temp_path = SVG.method(:temp_svg_path)
      original_variants = SVG.method(:svg_render_arg_variants)
      original_run = command_runner.method(:run)

      begin
        SVG.define_singleton_method(:find_svg_renderer) do
          { :kind => :pdftocairo, :exe => 'pdftocairo.exe' }
        end
        SVG.define_singleton_method(:temp_svg_path) { svg_path }
        SVG.define_singleton_method(:svg_render_arg_variants) do |*_args|
          [['pdftocairo.exe', '-svg', 'fixture.pdf', svg_path]]
        end
        command_runner.define_singleton_method(:run) do |*_args|
          File.open(svg_path, 'wb') { |file| file.write('<svg/>') }
          {
            :ok => true, :timed_out => false, :exitstatus => 0,
            :stdout => '', :stderr => DIAGNOSTIC_CLUSTER, :error => nil
          }
        end

        failure = {}
        result = CAIRO.render_page_svg(
          'fixture.pdf', 1, :failure_info => failure
        )
        assert_nil result
        assert_equal 'proven_adobe_gb1_fixture_incomplete_output',
                     failure[:reason]
      ensure
        SVG.define_singleton_method(:find_svg_renderer, original_renderer) if
          original_renderer
        SVG.define_singleton_method(:temp_svg_path, original_temp_path) if
          original_temp_path
        SVG.define_singleton_method(:svg_render_arg_variants, original_variants) if
          original_variants
        command_runner.define_singleton_method(:run, original_run) if original_run
      end
    end
  end
end
