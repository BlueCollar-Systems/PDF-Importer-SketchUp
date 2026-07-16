#!/usr/bin/env ruby

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
RUNNER = File.join(REPO_ROOT, 'tools', 'run_ruby_test_suite.rb')

class FullSuiteGateTest < Minitest::Test
  def run_fixture(source, strict, env_strict = '0', extra_env = {})
    Dir.mktmpdir('ruby_suite_gate_') do |dir|
      path = File.join(dir, 'fixture_test.rb')
      File.open(path, 'wb') { |io| io.write(source) }
      args = [Gem.ruby, RUNNER, '--test-dir', dir]
      args << '--strict-fixtures' if strict
      env = { 'PRIVATE_VALIDATION_CI_STRICT' => env_strict }.merge(extra_env)
      stdout, stderr, status = Open3.capture3(env, *args)
      return [stdout, stderr, status]
    end
  end

  def test_fixture_skip_is_allowed_normally_but_fails_in_strict_mode
    source = <<-RUBY
require 'minitest/autorun'
class RequiredFixtureSkipTest < Minitest::Test
  def test_fixture
    skip 'required fixture missing'
  end
end
    RUBY

    normal_out, normal_err, normal_status = run_fixture(source, false)
    assert normal_status.success?, "#{normal_out}\n#{normal_err}"

    strict_out, strict_err, strict_status = run_fixture(source, true)
    refute strict_status.success?, "#{strict_out}\n#{strict_err}"
    assert_match(/REQUIRED SKIP.*fixture_test\.rb/, strict_out + strict_err)
  end

  def test_passing_summary_is_totalled_without_null_summary_errors
    source = <<-RUBY
require 'minitest/autorun'
class PassingFixtureTest < Minitest::Test
  def test_pass
    assert true
  end
end
    RUBY

    stdout, stderr, status = run_fixture(source, true)
    assert status.success?, "#{stdout}\n#{stderr}"
    assert_match(/FULL RUBY SUITE: PASS \(1 files, 0 required skips\)/,
                 stdout)
    refute_match(/null-valued|null-summary|null array/i, stdout + stderr)
  end

  def test_custom_fixture_skip_line_also_fails_in_strict_mode
    source = <<-RUBY
puts 'SKIP: required private PDF not configured'
exit 0
    RUBY

    stdout, stderr, status = run_fixture(source, true)
    refute status.success?, "#{stdout}\n#{stderr}"
    assert_match(/REQUIRED SKIP.*fixture_test\.rb/, stdout + stderr)
  end

  def test_visible_parenthesized_skip_also_fails_in_strict_mode
    source = <<-RUBY
puts 'SKIP (visible): pdf-type-matrix not found'
exit 0
    RUBY

    stdout, stderr, status = run_fixture(source, true)
    refute status.success?, "#{stdout}\n#{stderr}"
    assert_match(/REQUIRED SKIP.*fixture_test\.rb/, stdout + stderr)
  end

  def test_private_validation_ci_strict_environment_enables_strict_mode
    source = <<-RUBY
puts 'SKIP GO-07 — PDF not on disk (private fixture missing)'
exit 0
    RUBY

    stdout, stderr, status = run_fixture(source, false, '1')
    refute status.success?, "#{stdout}\n#{stderr}"
    assert_match(/REQUIRED SKIP.*fixture_test\.rb/, stdout + stderr)
  end

  def test_public_and_private_corpus_roots_are_passed_to_test_processes
    source = <<-RUBY
public_ok = ENV['BCS_CORPUS_ROOT'] == 'public-corpus-marker'
private_ok = ENV['BCS_PRIVATE_VALIDATION_ROOT'] == 'private-corpus-marker'
exit(public_ok && private_ok ? 0 : 1)
    RUBY

    env = {
      'BCS_CORPUS_ROOT' => 'public-corpus-marker',
      'BCS_PRIVATE_VALIDATION_ROOT' => 'private-corpus-marker'
    }
    stdout, stderr, status = run_fixture(source, true, '1', env)
    assert status.success?, "#{stdout}\n#{stderr}"
  end
end
