#!/usr/bin/env ruby
# Stable, Ruby-2.2-compatible suite gate. In strict mode every skip is a
# required-fixture failure and the repository-pinned exact Ruby 2.2.4 parser
# gate must pass before tests run.

require 'open3'
require 'optparse'
require 'rbconfig'

module RubyTestSuiteGate
  REPO_ROOT = File.expand_path('..', __dir__).freeze
  DEFAULT_TEST_DIR = File.join(REPO_ROOT, 'test').freeze
  EXTENSION_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext').freeze
  PINNED_RUBY22_GATE = File.join(
    REPO_ROOT, 'tools', 'ruby22_real_parse_gate.rb'
  ).freeze

  class Runner
    def initialize(options = {})
      @test_dir = File.expand_path(options[:test_dir] || DEFAULT_TEST_DIR)
      @strict_fixtures = !!options[:strict_fixtures]
      @out = options[:out] || $stdout
      @err = options[:err] || $stderr
      @ruby_exe = options[:ruby_exe] || default_ruby_exe
      @child_env = options[:child_env] || {}
      # In-process dependency injection exists only for this class's unit
      # tests. run_cli never exposes a path/command override and always uses
      # PINNED_RUBY22_GATE.
      @gate_runner = options[:gate_runner] || method(:run_pinned_ruby22_gate)
    end

    def run
      test_files = Dir.glob(File.join(@test_dir, '*_test.rb')).sort
      if test_files.empty?
        @err.puts("FULL RUBY SUITE: FAIL (0 files found in #{@test_dir})")
        return 1
      end

      return 1 if @strict_fixtures && !exact_ruby22_gate_passes?

      failed_files = []
      required_skips = []
      test_files.each do |test_file|
        stdout, stderr, status = Open3.capture3(
          @child_env, @ruby_exe, test_file
        )
        combined = stdout.to_s + stderr.to_s
        skip_count = detected_skip_count(combined)

        unless status.success?
          failed_files << test_file
          @out.puts("TEST FAILURE: #{File.basename(test_file)}")
          @out.puts(combined)
          next
        end

        if @strict_fixtures && skip_count > 0
          required_skips << [test_file, skip_count]
          @out.puts(
            "REQUIRED SKIP: #{File.basename(test_file)} (#{skip_count})"
          )
          @out.puts(combined)
        end
      end

      if failed_files.empty? && required_skips.empty?
        @out.puts(
          "FULL RUBY SUITE: PASS (#{test_files.length} files, 0 required skips)"
        )
        return 0
      end

      @out.puts(
        "FULL RUBY SUITE: FAIL (#{test_files.length} files, " \
        "#{failed_files.length} failed, #{required_skips.length} required skips)"
      )
      1
    end

    private

    def default_ruby_exe
      File.join(
        RbConfig::CONFIG['bindir'],
        RbConfig::CONFIG['ruby_install_name'].to_s +
          RbConfig::CONFIG['EXEEXT'].to_s
      )
    end

    def exact_ruby22_gate_passes?
      stdout, stderr, success = @gate_runner.call(
        PINNED_RUBY22_GATE, EXTENSION_ROOT, @ruby_exe
      )
      @out.write(stdout.to_s) unless stdout.to_s.empty?
      @err.write(stderr.to_s) unless stderr.to_s.empty?
      unless success
        @err.puts(
          'EXACT RUBY 2.2.4 GATE: FAIL ' \
          '(repository-pinned real parse gate did not pass)'
        )
        return false
      end
      @out.puts('EXACT RUBY 2.2.4 GATE: PASS')
      true
    rescue StandardError => e
      @err.puts(
        "EXACT RUBY 2.2.4 GATE: FAIL (#{e.class}: #{e.message})"
      )
      false
    end

    def run_pinned_ruby22_gate(gate_path, extension_root, ruby_exe)
      unless File.file?(gate_path) &&
             File.expand_path(gate_path) == File.expand_path(PINNED_RUBY22_GATE)
        return ['', "Pinned Ruby 2.2.4 gate missing: #{gate_path}\n", false]
      end
      stdout, stderr, status = Open3.capture3(
        ruby_exe, gate_path, '--root', extension_root
      )
      [stdout, stderr, status.success?]
    end

    def detected_skip_count(combined)
      skip_matches = combined.scan(/(\d+)\s+skips?\b/i)
      summary_count = skip_matches.empty? ? 0 : skip_matches.last[0].to_i
      explicit_count = combined.each_line.inject(0) do |count, line|
        missing_fixture = line =~ /^\s*SKIP(?:\s|\(|:)/i ||
                          line =~ /^\s*WARN:.*(?:fixture|PDF|validation).*(?:missing|not found|not configured)/i
        count + (missing_fixture ? 1 : 0)
      end
      [summary_count, explicit_count].max
    end
  end

  def self.run_cli(argv)
    options = {
      test_dir: DEFAULT_TEST_DIR,
      strict_fixtures:
        ENV['PRIVATE_VALIDATION_CI_STRICT'].to_s.strip == '1'
    }
    OptionParser.new do |parser|
      parser.on('--test-dir DIR') { |value| options[:test_dir] = value }
      parser.on('--strict-fixtures') { options[:strict_fixtures] = true }
    end.parse!(argv)
    Runner.new(options).run
  rescue OptionParser::ParseError => e
    warn(e.message)
    1
  end
end

if __FILE__ == $PROGRAM_NAME
  exit RubyTestSuiteGate.run_cli(ARGV)
end
