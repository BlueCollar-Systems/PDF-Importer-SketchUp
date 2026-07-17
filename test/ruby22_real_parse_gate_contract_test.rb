#!/usr/bin/env ruby

require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class Ruby22RealParseGateContractTest < Minitest::Test
  DEPRECATED_EXACT_IMAGE = 'ruby:2.2.4@sha256:c8ed9ed708728b89e0744f70eed170c42ab2e52fa6443baf7488c381c65c6643'
  SOURCE_HELPER = 'tools/run_ruby22_exact_source.sh'
  OFFICIAL_SOURCE_URL = 'https://cache.ruby-lang.org/pub/ruby/2.2/ruby-2.2.4.tar.gz'
  OFFICIAL_SOURCE_BYTES = '16638151'
  OFFICIAL_SOURCE_SHA256 = 'b6eff568b48e0fda76e5a36333175df049b204e91217aa32a65153cc0cdcb761'

  class RecordingRunner
    attr_reader :capture_calls, :run_calls

    def initialize(runtime_description, parse_results = {})
      @runtime_description = runtime_description
      @parse_results = parse_results
      @capture_calls = []
      @run_calls = []
    end

    def capture(executable, arguments)
      @capture_calls << [executable, arguments]
      [@runtime_description, '', true]
    end

    def run(executable, arguments)
      @run_calls << [executable, arguments]
      @parse_results.fetch(arguments.last, true)
    end
  end

  def gate_tool
    File.join(REPO_ROOT, 'tools', 'ruby22_real_parse_gate.rb')
  end

  def load_gate_tool
    assert File.file?(gate_tool), 'exact Ruby 2.2.4 parse tool must exist'
    load gate_tool
  end

  def test_exact_ruby_224_parse_gate_is_blocking_in_local_ci_and_release_paths
    assert File.file?(gate_tool), 'exact Ruby 2.2.4 parse tool must exist'

    local = File.read(File.join(REPO_ROOT, 'tools', 'run_ruby_test_suite.rb'), encoding: 'UTF-8')
    ci = File.read(File.join(REPO_ROOT, '.github', 'workflows', 'su-pdfimporter-ci.yml'), encoding: 'UTF-8')
    release = File.read(File.join(REPO_ROOT, '.github', 'workflows', 'auto-release.yml'), encoding: 'UTF-8')
    assert_includes local, 'ruby22_real_parse_gate.rb'
    [local, ci, release].each do |source|
      refute_match(/continue-on-error:\s*true.*(?:ruby22_real_parse_gate|run_ruby22_exact_source)/m, source)
    end
    refute_match(
      /system\(RbConfig\.ruby,\s*'--disable-gems',\s*test_file\)/,
      local,
      'local tests must retain their installed Minitest/default-gem load path'
    )
    helper_path = File.join(REPO_ROOT, SOURCE_HELPER)
    assert File.file?(helper_path), 'verified official-source Ruby helper must exist'
    helper = File.read(helper_path, encoding: 'UTF-8')
    assert_includes helper, OFFICIAL_SOURCE_URL
    assert_includes helper, OFFICIAL_SOURCE_BYTES
    assert_includes helper, OFFICIAL_SOURCE_SHA256
    assert_includes helper, '2.2.4-p230'
    assert_includes helper, 'ruby22_real_parse_gate.rb'
    assert_includes helper, '${SOURCE_DIR}/test/lib'
    assert_match(/sha256sum/, helper)
    assert_match(/wc\s+-c/, helper)
    %w[awk curl dirname env find gcc make mkdir mktemp mv rm sha256sum tar tr wc].each do |command_name|
      assert_match(/for command_name in .*?\b#{Regexp.escape(command_name)}\b/m, helper)
    end
    assert_includes local, File.basename(SOURCE_HELPER)
    assert_includes local, 'BCS_RUBY22_SOURCE_GATE'
    assert_match(/system\('bash',\s*source_gate,\s*'--parse'\)/, local)

    [ci, release].each do |workflow|
      assert_includes workflow, SOURCE_HELPER
      refute_includes workflow, DEPRECATED_EXACT_IMAGE
      assert_includes workflow, '--parse'
    end
    assert_includes ci, '--smoke'
    assert_includes release, '--smoke'
    assert_operator release.index(SOURCE_HELPER), :<,
                    release.index('Build .rbz')
  end

  def test_gate_rejects_any_runtime_other_than_exact_224_p230
    load_gate_tool
    Dir.mktmpdir('ruby22-gate') do |dir|
      File.write(File.join(dir, 'extension.rb'), "puts 'ok'\n")
      runner = RecordingRunner.new('2.2.4-p231')
      stderr = StringIO.new
      gate = Ruby22RealParseGate::Gate.new(
        :extension_dir => dir,
        :ruby_executable => 'candidate-ruby',
        :runner => runner,
        :stdout => StringIO.new,
        :stderr => stderr
      )

      assert_equal 1, gate.run
      assert_match(/requires exact Ruby 2\.2\.4-p230/, stderr.string)
      assert_empty runner.run_calls
    end
  end

  def test_gate_parses_every_extension_file_in_sorted_order_with_gems_disabled
    load_gate_tool
    Dir.mktmpdir('ruby22-gate') do |dir|
      nested = File.join(dir, 'nested')
      Dir.mkdir(nested)
      z_file = File.join(dir, 'z_file.rb')
      a_file = File.join(nested, 'a_file.rb')
      File.write(z_file, "puts 'z'\n")
      File.write(a_file, "puts 'a'\n")
      File.write(File.join(dir, 'ignored.txt'), 'not Ruby')
      runner = RecordingRunner.new('2.2.4-p230')
      gate = Ruby22RealParseGate::Gate.new(
        :extension_dir => dir,
        :ruby_executable => 'candidate-ruby',
        :runner => runner,
        :stdout => StringIO.new,
        :stderr => StringIO.new
      )

      assert_equal 0, gate.run
      assert_equal [
        ['candidate-ruby', ['--disable-gems', '-c', a_file]],
        ['candidate-ruby', ['--disable-gems', '-c', z_file]]
      ], runner.run_calls
      assert_equal [
        ['candidate-ruby', ['--disable-gems', '-e',
                            'STDOUT.write("#{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}")']]
      ], runner.capture_calls
    end
  end

  def test_gate_checks_remaining_files_after_a_parse_failure_and_fails
    load_gate_tool
    Dir.mktmpdir('ruby22-gate') do |dir|
      first = File.join(dir, 'a_bad.rb')
      second = File.join(dir, 'b_good.rb')
      File.write(first, "def broken(\n")
      File.write(second, "puts 'still checked'\n")
      runner = RecordingRunner.new('2.2.4-p230', first => false)
      stderr = StringIO.new
      gate = Ruby22RealParseGate::Gate.new(
        :extension_dir => dir,
        :ruby_executable => 'candidate-ruby',
        :runner => runner,
        :stdout => StringIO.new,
        :stderr => stderr
      )

      assert_equal 1, gate.run
      assert_equal [first, second], runner.run_calls.map { |call| call.last.last }
      assert_match(/Ruby 2\.2\.4-p230 parse gate failed/, stderr.string)
    end
  end

  def test_gate_fails_closed_when_extension_tree_has_no_ruby_files
    load_gate_tool
    Dir.mktmpdir('ruby22-gate') do |dir|
      runner = RecordingRunner.new('2.2.4-p230')
      stderr = StringIO.new
      gate = Ruby22RealParseGate::Gate.new(
        :extension_dir => dir,
        :ruby_executable => 'candidate-ruby',
        :runner => runner,
        :stdout => StringIO.new,
        :stderr => stderr
      )

      assert_equal 1, gate.run
      assert_match(/no extension Ruby files found/, stderr.string)
      assert_empty runner.capture_calls
      assert_empty runner.run_calls
    end
  end
end
