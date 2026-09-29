#!/usr/bin/env ruby
# Owner rule (2026-09-28): once an import has started, nothing may put a
# question in front of the operator. A multi-page import that stops on a
# modal after the operator walked away is a reason to look for another tool.
#
# What this pins:
#   * the per-page complexity check never opens a dialog (it logs and builds);
#   * the missing-SVG-renderer stop never opens a dialog (one failure message);
#   * the only question an import may ask - a very large file - is asked ONCE,
#     before page 1, by run_resumable_pipeline, and every per-page call runs
#     with :large_pdf_confirmed so run_pipeline cannot ask again;
#   * declining it returns a cancelled result, never nil, so the caller does
#     not report "No vector content found in PDF." for a declined import;
#   * the page loop of run_pipeline contains no UI.messagebox at all.

require 'minitest/autorun'

class NoMidImportPromptsTest < Minitest::Test
  MAIN = File.read(File.expand_path(
    '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
  ))

  def method_source(name)
    src = MAIN[/^    def self\.#{Regexp.escape(name)}(?=[\s(]).*?^    end\n/m]
    refute_nil src, "#{name} not found in main.rb"
    src
  end

  def test_per_page_complexity_check_never_opens_a_dialog
    src = method_source('confirm_page_complexity!')
    refute_includes src, 'UI.messagebox'
    refute_includes src, 'UI.inputbox'
    assert_includes src, 'continuing without a per-page confirmation'
  end

  def test_missing_renderer_stop_never_opens_a_dialog
    src = method_source('enforce_svg_renderer_available!')
    refute_includes src, 'UI.messagebox'
    assert_includes src, 'raise RepresentationFidelity::ContractError'
    assert_includes src, 'BC_PDFTOCAIRO_PATH', 'the single failure message must carry the remedy'
  end

  def test_large_pdf_question_is_asked_once_before_page_one
    resumable = method_source('run_resumable_pipeline')
    ask = resumable.index('confirm_large_pdf_once!(source_path)')
    fallback = resumable.index('unless resumable_import?(opts)')
    refute_nil ask
    assert_operator ask, :<, fallback,
                    'the question must precede the non-resumable fallback so every entry point asks exactly once'
    assert_includes resumable, ':large_pdf_confirmed => true'
    assert_includes resumable, "cancelled_before_start(source_path, 'very large PDF declined')"

    pipeline = MAIN[/^    def self\.run_pipeline\(model, path, opts\).*?^    def self\./m]
    refute_nil pipeline
    block = pipeline[/File size warning for very large PDFs.*?PdfSalvage/m]
    refute_nil block
    assert_includes block, 'unless opts[:large_pdf_confirmed]'
    refute_includes block, 'UI.messagebox'
  end

  def test_page_loop_contains_no_dialog
    pipeline = MAIN[/^    def self\.run_pipeline\(model, path, opts\).*?^    def self\./m]
    loop_src = pipeline[/pages\.each_with_index.*?post_build_commit_started/m]
    refute_nil loop_src, 'page loop not found'
    refute_includes loop_src, 'UI.messagebox'
    refute_includes loop_src, 'UI.inputbox'
  end

  def test_runner_survives_a_page_call_that_returns_nil
    resumable = method_source('run_resumable_pipeline')
    assert_includes resumable,
                    ':next_y_offset => page_stats.is_a?(Hash) ? page_stats[:next_y_offset] : nil'
  end

  # ---- behaviour of confirm_large_pdf_once! with a scripted UI ----------

  # Plain modules (Ruby 2.2-safe, no define_method): a scripted UI, a
  # recording Logger and a BatchHostPolicy with the real confirm_large_pdf!
  # contract and a 100-byte threshold.
  module FakeUI
    class << self
      attr_accessor :answers
      def calls; @calls ||= []; end
      def messagebox(message, *_rest)
        calls << message
        answers.shift
      end
    end
  end

  module FakeLogger
    class << self
      def lines; @lines ||= []; end
      def info(ctx, msg); lines << [ctx, msg]; end
      def warn(ctx, msg); lines << [ctx, msg]; end
    end
  end

  module FakePolicy
    LARGE_PDF_BYTES = 100
    class NoninteractiveError < StandardError; end
    class << self
      attr_accessor :noninteractive
      def noninteractive?; noninteractive == true; end
      def confirm_large_pdf!(file_size_bytes)
        return true unless file_size_bytes.to_i > LARGE_PDF_BYTES
        if noninteractive?
          raise NoninteractiveError,
                'large PDF requires interactive confirmation; batch import stopped'
        end
        block_given? ? yield : false
      end
    end
  end

  def build_scope(answers, noninteractive = false)
    FakeUI.answers = answers.dup
    FakeUI.calls.clear
    FakeLogger.lines.clear
    FakePolicy.noninteractive = noninteractive
    scope = Module.new
    scope.const_set(:IDOK, 6)
    scope.const_set(:IDCANCEL, 2)
    scope.const_set(:MB_OKCANCEL, 1)
    scope.const_set(:UI, FakeUI)
    scope.const_set(:Logger, FakeLogger)
    scope.const_set(:BatchHostPolicy, FakePolicy)
    src = method_source('confirm_large_pdf_once!') +
          method_source('cancelled_before_start')
    scope.module_eval(src, __FILE__, __LINE__)
    scope
  end

  def test_small_file_asks_nothing
    scope = build_scope([2])
    assert_equal true, scope.confirm_large_pdf_once!('any.pdf', 50)
    assert_empty scope::UI.calls
  end

  def test_large_file_asks_exactly_once_and_continues_on_ok
    scope = build_scope([6])
    assert_equal true, scope.confirm_large_pdf_once!('big.pdf', 1_000)
    assert_equal 1, scope::UI.calls.length
    assert_match(/only question this import will ask/, scope::UI.calls.first)
    assert_match(/Esc/, scope::UI.calls.first)
  end

  def test_large_file_declined_returns_false_and_a_cancelled_result_not_nil
    scope = build_scope([2])
    assert_equal false, scope.confirm_large_pdf_once!('big.pdf', 1_000)
    assert_equal 1, scope::UI.calls.length
    result = scope.cancelled_before_start('C:/x/big.pdf', 'very large PDF declined')
    assert_equal true, result[:cancelled]
    assert_equal true, result[:cancelled_before_start]
    assert_equal [], result[:retained_pages]
    assert_match(/was not started/, result[:message])
    assert_match(/very large PDF declined/, result[:message])
  end

  def test_noninteractive_policy_is_unchanged
    scope = build_scope([6], true)
    assert_raises(scope::BatchHostPolicy::NoninteractiveError) do
      scope.confirm_large_pdf_once!('big.pdf', 1_000)
    end
    assert_empty scope::UI.calls
  end

  def test_unreadable_size_never_blocks
    scope = build_scope([2])
    assert_equal true, scope.confirm_large_pdf_once!('C:/does/not/exist.pdf')
    assert_empty scope::UI.calls
    assert scope::Logger.lines.any? { |ctx, msg| ctx == 'Pipeline' && msg =~ /File size check failed/ }
  end
end
