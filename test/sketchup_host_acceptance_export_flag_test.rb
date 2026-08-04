#!/usr/bin/env ruby
# Regression guard: every host completion path must state 'skp_export_only'.
#
# Why this test reads source instead of running a session:
#
# The strict corpus acceptance failed all 360 SketchUp cells with
# "strict release/canonical recertification failed" and an EMPTY
# certification_errors list. The cause was
# sketchup_full_corpus_sweep.rb::resumable_result:
#
#     return nil unless acceptance['skp_export_only'] == @skp_export_only
#
# finish_skp_export_only! emitted 'skp_export_only' => true, but the normal
# completion path emitted nothing at all. In full-acceptance mode Ruby therefore
# compared nil == false, which is false, and returned nil through a path that
# records no error. Export-only mode passed; full mode could never pass.
#
# The existing suites could not catch this: sketchup_full_corpus_sweep_test.rb
# builds its acceptance fixture with 'skp_export_only' => job.fetch(...), and
# sketchup_batch_host_contract_test.rb's FakeSession returns a stub payload.
# Both supply the key themselves, so neither observes the real host omitting it.
# Asserting on the source is what actually closes that gap.
require 'minitest/autorun'

class SketchupHostAcceptanceExportFlagTest < Minitest::Test
  BATCH_IMPORT = File.expand_path(
    '../tools/sketchup_batch_import.rb', __dir__
  ).freeze

  def source
    @source ||= File.read(BATCH_IMPORT, :encoding => 'UTF-8')
  end

  # Each completion path returns a hash literal carrying
  # 'plugins_disabled_verified'. Slice each one and require the flag inside it.
  def payload_literals
    literals = []
    source.each_line.with_index do |line, index|
      next unless line.include?("'plugins_disabled_verified' =>")
      lines = source.lines
      start = index
      # `start > 0`, not `start.positive?` -- Integer#positive? is Ruby 2.3+ and
      # SketchUp 2017 ships Ruby 2.2.4. ruby22_compat_test.rb enforces this.
      start -= 1 while start > 0 && !lines[start].strip.start_with?('{')
      literals << lines[start, 24].join
    end
    literals
  end

  def test_both_completion_paths_declare_skp_export_only
    literals = payload_literals
    assert_equal 2, literals.length,
                 'expected exactly two host completion payloads ' \
                 "(export-only and normal), found #{literals.length}"
    literals.each_with_index do |literal, position|
      assert_includes literal, "'skp_export_only' =>",
                      "host completion payload ##{position + 1} does not state " \
                      "'skp_export_only'. A missing key is NOT read as false by " \
                      'sketchup_full_corpus_sweep.rb::resumable_result -- it ' \
                      'compares nil == false and silently fails every cell.'
    end
  end

  def test_export_only_path_declares_true_and_normal_path_declares_false
    values = source.scan(/'skp_export_only' => (true|false)/).flatten
    assert_includes values, 'true',
                    "expected the export-only completion path to declare " \
                    "'skp_export_only' => true"
    assert_includes values, 'false',
                    "expected the normal completion path to declare " \
                    "'skp_export_only' => false"
  end

  def test_absent_key_would_not_satisfy_the_recertifier
    # Documents the exact Ruby semantics that made the failure silent, so nobody
    # "simplifies" the emission away again on the assumption that absent == false.
    acceptance = {}
    refute_equal false, acceptance['skp_export_only'],
                 'nil must not be treated as equal to false; this inequality is ' \
                 'precisely what failed 360 strict cells with an empty error list'
    assert_nil acceptance['skp_export_only']
  end
end
