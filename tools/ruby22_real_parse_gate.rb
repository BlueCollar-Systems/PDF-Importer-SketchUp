#!/usr/bin/env ruby
# frozen_string_literal: true

# A real-parser release gate for SketchUp 2017's embedded Ruby. Static scans
# cannot detect every grammar incompatibility, so every shipped extension Ruby
# file must be parsed by the exact host-compatible Ruby release.

require 'open3'
require 'rbconfig'

module Ruby22RealParseGate
  EXPECTED_RUNTIME = '2.2.4-p230' unless const_defined?(:EXPECTED_RUNTIME)
  VERSION_PROBE = 'STDOUT.write("#{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}")' unless const_defined?(:VERSION_PROBE)

  class SubprocessRunner
    def capture(executable, arguments)
      stdout, stderr, status = Open3.capture3(executable, *arguments)
      [stdout, stderr, status.success?]
    rescue StandardError => error
      ['', error.message, false]
    end

    def run(executable, arguments)
      system(executable, *arguments) == true
    rescue StandardError
      false
    end
  end

  class Gate
    def initialize(options = {})
      repo_root = File.expand_path('..', File.dirname(__FILE__))
      @extension_dir = File.expand_path(
        options[:extension_dir] || File.join(repo_root, 'extracted', 'sketchup_ext')
      )
      @ruby_executable = options[:ruby_executable]
      @runner = options[:runner] || SubprocessRunner.new
      @stdout = options[:stdout] || $stdout
      @stderr = options[:stderr] || $stderr
    end

    def run
      files = extension_files
      if files.empty?
        @stderr.puts("ERROR: no extension Ruby files found under #{@extension_dir}")
        return 1
      end

      executable = @ruby_executable || self.class.resolve_exact_ruby
      unless executable
        @stderr.puts(
          "ERROR: Ruby parse gate requires exact Ruby #{EXPECTED_RUNTIME}; " \
          'set RUBY22_EXE (or BCS_RUBY22_EXE) to that interpreter'
        )
        return 1
      end

      runtime, probe_error, probe_ok = @runner.capture(
        executable,
        ['--disable-gems', '-e', VERSION_PROBE]
      )
      actual_runtime = runtime.to_s.strip
      unless probe_ok && actual_runtime == EXPECTED_RUNTIME
        detail = probe_ok ? actual_runtime : probe_error.to_s.strip
        detail = 'unavailable' if detail.empty?
        @stderr.puts(
          "ERROR: Ruby parse gate requires exact Ruby #{EXPECTED_RUNTIME}; " \
          "#{executable} reported #{detail}"
        )
        return 1
      end

      failures = []
      files.each do |path|
        @stdout.puts("Ruby #{EXPECTED_RUNTIME} parse: #{path}")
        parsed = @runner.run(executable, ['--disable-gems', '-c', path])
        failures << path unless parsed
      end

      unless failures.empty?
        @stderr.puts(
          "ERROR: Ruby #{EXPECTED_RUNTIME} parse gate failed for " \
          "#{failures.length} file(s):"
        )
        failures.each { |path| @stderr.puts("  #{path}") }
        return 1
      end

      @stdout.puts(
        "PASS: Ruby #{EXPECTED_RUNTIME} parsed all #{files.length} extension Ruby file(s)"
      )
      0
    end

    def extension_files
      return [] unless File.directory?(@extension_dir)

      Dir.glob(File.join(@extension_dir, '**', '*.rb')).select do |path|
        File.file?(path)
      end.sort
    end

    def self.resolve_exact_ruby
      explicit = ENV['RUBY22_EXE']
      explicit = ENV['BCS_RUBY22_EXE'] if explicit.nil? || explicit.strip.empty?
      return explicit.strip unless explicit.nil? || explicit.strip.empty?

      if RUBY_VERSION == '2.2.4' && RUBY_PATCHLEVEL == 230
        return RbConfig.ruby
      end

      windows_candidates = [
        'C:/Ruby22-x64/bin/ruby.exe',
        'C:/Ruby22/bin/ruby.exe'
      ]
      windows_candidates.each do |candidate|
        return candidate if File.file?(candidate)
      end
      nil
    end
  end

  def self.command_line_options(arguments)
    options = {}
    remaining = arguments.dup
    until remaining.empty?
      argument = remaining.shift
      case argument
      when '--extension-dir'
        value = remaining.shift
        raise ArgumentError, '--extension-dir requires a path' unless value
        options[:extension_dir] = value
      when '--ruby'
        value = remaining.shift
        raise ArgumentError, '--ruby requires an executable' unless value
        options[:ruby_executable] = value
      when '--help', '-h'
        options[:help] = true
      else
        raise ArgumentError, "unknown argument: #{argument}"
      end
    end
    options
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = Ruby22RealParseGate.command_line_options(ARGV)
    if options.delete(:help)
      puts 'Usage: ruby tools/ruby22_real_parse_gate.rb [--extension-dir PATH] [--ruby EXE]'
      exit 0
    end
    exit Ruby22RealParseGate::Gate.new(options).run
  rescue ArgumentError => error
    warn "ERROR: #{error.message}"
    exit 1
  end
end
