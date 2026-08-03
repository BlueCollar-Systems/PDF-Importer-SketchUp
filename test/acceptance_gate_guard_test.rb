#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class AcceptanceGateGuardTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  GATES = [
    ['golden oracles', 'test/golden_oracle_test.rb', {}],
    [
      'strict timing',
      'test/corpus_strict_timing_test.rb',
      { 'CORPUS_STRICT_TIMING' => '1' }
    ],
    ['shop BOM parity', 'test/shop_bom_visual_parity_regression_test.rb', {}],
    ['SVG multi-page', 'test/svg_text_multi_page_gate_test.rb', {}],
    ['label placement', 'test/text_label_placement_test.rb', {}],
    ['mode placement', 'test/text_mode_placement_test.rb', {}]
  ].freeze

  def test_every_gate_fails_when_private_root_is_configured_but_missing
    Dir.mktmpdir('acceptance-gate-guard') do |root|
      missing_root = File.join(root, 'missing')
      GATES.each do |name, relative_script, extra_env|
        env = {
          'BCS_PRIVATE_VALIDATION_ROOT' => missing_root,
          'PDF_PRIVATE_VALIDATION_ROOT' => nil,
          'BCS_TIER1_USER_PDF' => nil,
          'BCS_SHOP_BOM_REGRESSION_PDF' => nil,
          'BCS_SVG_TEXT_GATE_PDF' => nil,
          'CORPUS_STRICT_TIMING_PDF' => nil
        }.merge(extra_env)
        script = File.join(REPO_ROOT, relative_script)
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script)
        output = stdout.to_s + stderr.to_s

        refute status.success?, "#{name} silently passed:\n#{output}"
        assert_match(/configured private validation root does not exist/i, output, name)
      end
    end
  end

  def test_every_gate_skips_only_when_no_acceptance_input_is_configured
    GATES.each do |name, relative_script, extra_env|
      env = {
        'BCS_PRIVATE_VALIDATION_ROOT' => nil,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil,
        'BCS_TIER1_USER_PDF' => nil,
        'BCS_SHOP_BOM_REGRESSION_PDF' => nil,
        'BCS_SVG_TEXT_GATE_PDF' => nil,
        'CORPUS_STRICT_TIMING_PDF' => nil
      }.merge(extra_env)
      script = File.join(REPO_ROOT, relative_script)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script)
      output = stdout.to_s + stderr.to_s

      assert status.success?, "#{name} did not skip cleanly:\n#{output}"
      assert_match(/skip/i, output, name)
    end
  end
end
