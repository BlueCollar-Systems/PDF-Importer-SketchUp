#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'tools', 'ruby22_real_parse_gate')

class Ruby22RealParseGateContractTest < Minitest::Test
  Gate = RealRuby224ParseGate::Gate

  def gate_options(overrides = {})
    {
      env: {},
      out: StringIO.new,
      err: StringIO.new,
      platform: 'x64-mingw32',
      current_version: '3.4.4',
      current_patchlevel: 0,
      current_exe: 'C:/Ruby34/bin/ruby.exe',
      file_checker: lambda { |_path| true }
    }.merge(overrides)
  end

  def successful_runner(calls)
    lambda do |argv|
      calls << argv
      if argv.include?('-e')
        ['2.2.4|230', 'wrapper warning', true]
      else
        ['Syntax OK', '', true]
      end
    end
  end

  def test_explicit_runtime_is_authoritative_and_uses_disable_gems
    calls = []
    gate = Gate.new(gate_options(
      env: { 'RUBY22_EXE' => 'C:/explicit/ruby22.exe' },
      runner: successful_runner(calls)
    ))

    selected = gate.resolve_ruby22

    assert_equal 'C:/explicit/ruby22.exe', selected[:exe]
    assert_equal 'RUBY22_EXE', selected[:source]
    assert_equal ['C:/explicit/ruby22.exe', '--disable-gems'], calls.first[0, 2]
  end

  def test_invalid_explicit_runtime_fails_without_falling_through
    calls = []
    gate = Gate.new(gate_options(
      env: { 'RUBY22_EXE' => 'C:/missing/ruby22.exe' },
      runner: successful_runner(calls),
      file_checker: lambda { |_path| false }
    ))

    assert_nil gate.resolve_ruby22
    assert_empty calls
    assert_match(/RUBY22_EXE.*not found/i, gate.err.string)
  end

  def test_wrong_explicit_version_fails_without_falling_through
    calls = []
    runner = lambda do |argv|
      calls << argv
      ['2.2.6|396', '', true]
    end
    gate = Gate.new(gate_options(
      env: { 'RUBY22_EXE' => 'C:/wrong/ruby.exe' }, runner: runner
    ))

    assert_nil gate.resolve_ruby22
    assert_equal 1, calls.length
    assert_match(/expected 2\.2\.4p230.*2\.2\.6p396/i, gate.err.string)
  end

  def test_current_interpreter_is_candidate_only_when_exact_224p230
    calls = []
    exact = Gate.new(gate_options(
      platform: 'linux', current_version: '2.2.4', current_patchlevel: 230,
      current_exe: '/ruby224/bin/ruby', runner: successful_runner(calls),
      file_checker: lambda { |path| path == '/ruby224/bin/ruby' }
    ))
    assert_equal '/ruby224/bin/ruby', exact.resolve_ruby22[:exe]

    calls = []
    wrong = Gate.new(gate_options(
      platform: 'linux', current_version: '2.2.5', current_patchlevel: 319,
      current_exe: '/ruby225/bin/ruby', runner: successful_runner(calls),
      file_checker: lambda { |_path| true }
    ))
    assert_nil wrong.resolve_ruby22
    assert_empty calls
  end

  def test_run_parses_every_nested_extension_file_once_in_sorted_order
    Dir.mktmpdir('ruby224_gate_') do |dir|
      sub = File.join(dir, 'sub')
      Dir.mkdir(sub)
      first = File.join(dir, 'a.rb')
      second = File.join(sub, 'b.rb')
      File.write(second, "puts 'b'\n")
      File.write(first, "puts 'a'\n")
      calls = []
      gate = Gate.new(gate_options(
        env: { 'RUBY22_EXE' => 'C:/explicit/ruby22.exe' },
        runner: successful_runner(calls)
      ))

      assert gate.run(dir)
      parse_calls = calls.select { |argv| argv.include?('-c') }
      assert_equal [first, second], parse_calls.map(&:last)
      assert parse_calls.all? { |argv| argv[1] == '--disable-gems' }
      assert_match(/PASS \(2 files, 2\.2\.4p230/, gate.out.string)
    end
  end

  def test_run_fails_on_zero_files
    Dir.mktmpdir('ruby224_empty_') do |dir|
      gate = Gate.new(gate_options(
        env: { 'RUBY22_EXE' => 'C:/explicit/ruby22.exe' },
        runner: successful_runner([])
      ))
      refute gate.run(dir)
      assert_match(/zero Ruby files/i, gate.err.string)
    end
  end

  def test_run_reports_every_syntax_failure
    Dir.mktmpdir('ruby224_fail_') do |dir|
      bad = File.join(dir, 'bad.rb')
      good = File.join(dir, 'good.rb')
      File.write(bad, "def broken(\n")
      File.write(good, "puts 'ok'\n")
      calls = []
      runner = lambda do |argv|
        calls << argv
        if argv.include?('-e')
          ['2.2.4|230', '', true]
        elsif argv.last == bad
          ['', 'syntax error', false]
        else
          ['Syntax OK', '', true]
        end
      end
      gate = Gate.new(gate_options(
        env: { 'RUBY22_EXE' => 'C:/explicit/ruby22.exe' }, runner: runner
      ))

      refute gate.run(dir)
      assert_equal 2, calls.count { |argv| argv.include?('-c') }
      assert_match(/bad\.rb.*syntax error/m, gate.err.string)
    end
  end

  def test_ci_and_release_use_the_exact_blocking_runtime_gate
    digest = 'ruby:2.2.4@sha256:c8ed9ed708728b89e0744f70eed170c42ab2e52fa6443baf7488c381c65c6643'
    ci = File.read(File.join(REPO_ROOT, '.github', 'workflows', 'su-pdfimporter-ci.yml'))
    release = File.read(File.join(REPO_ROOT, '.github', 'workflows', 'auto-release.yml'))

    [ci, release].each do |workflow|
      assert_includes workflow, digest
      assert_includes workflow, 'tools/ruby22_real_parse_gate.rb'
    end
    assert_operator release.index('tools/ruby22_real_parse_gate.rb'), :<,
                    release.index('Build .rbz')
  end
end
