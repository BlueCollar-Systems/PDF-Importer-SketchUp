#!/usr/bin/env ruby
# Fail-closed syntax proof using the exact SketchUp 2017 Ruby host runtime.

require 'open3'
require 'optparse'
require 'rbconfig'

module RealRuby224ParseGate
  EXACT_VERSION = '2.2.4'.freeze
  EXACT_PATCHLEVEL = 230
  VERSION_PROBE =
    'STDOUT.write([RUBY_VERSION, RUBY_PATCHLEVEL].join("|"))'.freeze
  WINDOWS_LOCAL_RUBY = 'C:/Ruby22-x64/bin/ruby.exe'.freeze

  class Gate
    attr_reader :out, :err

    def initialize(options = {})
      @env = options[:env] || ENV
      @out = options[:out] || $stdout
      @err = options[:err] || $stderr
      @runner = options[:runner] || method(:run_command)
      @platform = options[:platform] || RUBY_PLATFORM
      @current_version = options[:current_version] || RUBY_VERSION
      @current_patchlevel = if options.key?(:current_patchlevel)
                              options[:current_patchlevel]
                            else
                              RUBY_PATCHLEVEL
                            end
      @current_exe = options[:current_exe] || RbConfig.ruby
      @file_checker = options[:file_checker] || lambda { |path| File.file?(path) }
    end

    def run(root)
      selected = resolve_ruby22
      return false unless selected

      files = Dir.glob(File.join(root.to_s, '**', '*.rb')).sort
      if files.empty?
        @err.puts("REAL RUBY 2.2.4 PARSE: FAIL (zero Ruby files under #{root})")
        return false
      end

      failures = []
      files.each do |path|
        stdout, stderr, success = invoke(
          [selected[:exe], '--disable-gems', '-c', path]
        )
        next if success
        details = [stdout, stderr].map { |value| value.to_s.strip }.
          reject { |value| value.empty? }.join(' | ')
        details = 'syntax check process failed without diagnostics' if details.empty?
        failures << [path, details]
      end

      unless failures.empty?
        @err.puts("REAL RUBY 2.2.4 PARSE: FAIL (#{failures.length} of #{files.length} files)")
        failures.each do |path, details|
          @err.puts("  #{path}: #{details}")
        end
        return false
      end

      @out.puts(
        "REAL RUBY 2.2.4 PARSE: PASS (#{files.length} files, " \
        "2.2.4p230, source=#{selected[:source]})"
      )
      true
    rescue StandardError => e
      @err.puts("REAL RUBY 2.2.4 PARSE: FAIL (#{e.class}: #{e.message})")
      false
    end

    def resolve_ruby22
      explicit = explicit_candidate
      return validate_candidate(explicit[0], explicit[1]) if explicit

      if windows_platform? && @file_checker.call(WINDOWS_LOCAL_RUBY)
        selected = validate_candidate(WINDOWS_LOCAL_RUBY, 'windows_local')
        return selected if selected
      end

      if exact_current_runtime? && @file_checker.call(@current_exe)
        selected = validate_candidate(@current_exe, 'current_interpreter')
        return selected if selected
      end

      @err.puts(
        'REAL RUBY 2.2.4 PARSE: FAIL (exact Ruby 2.2.4p230 runtime unavailable; ' \
        'set RUBY22_EXE to its absolute executable path)'
      )
      nil
    rescue StandardError => e
      @err.puts("REAL RUBY 2.2.4 PARSE: FAIL (runtime resolution: #{e.message})")
      nil
    end

    private

    def explicit_candidate
      [['RUBY22_EXE', @env['RUBY22_EXE']],
       ['BCS_RUBY22_EXE', @env['BCS_RUBY22_EXE']]].each do |source, value|
        path = value.to_s.strip
        return [path, source] unless path.empty?
      end
      nil
    end

    def validate_candidate(exe, source)
      unless @file_checker.call(exe)
        @err.puts("REAL RUBY 2.2.4 PARSE: FAIL (#{source} not found: #{exe})")
        return nil
      end

      stdout, stderr, success = invoke(
        [exe, '--disable-gems', '-e', VERSION_PROBE]
      )
      unless success
        details = [stdout, stderr].map { |value| value.to_s.strip }.
          reject { |value| value.empty? }.join(' | ')
        @err.puts(
          "REAL RUBY 2.2.4 PARSE: FAIL (#{source} probe failed: #{details})"
        )
        return nil
      end

      version, patchlevel = stdout.to_s.strip.split('|', 2)
      unless version == EXACT_VERSION && patchlevel.to_i == EXACT_PATCHLEVEL
        observed = version.to_s.empty? ? stdout.to_s.strip :
          "#{version}p#{patchlevel}"
        @err.puts(
          "REAL RUBY 2.2.4 PARSE: FAIL (#{source} expected " \
          "2.2.4p230, observed #{observed})"
        )
        return nil
      end

      { exe: exe, source: source }
    end

    def exact_current_runtime?
      @current_version.to_s == EXACT_VERSION &&
        @current_patchlevel.to_i == EXACT_PATCHLEVEL
    end

    def windows_platform?
      @platform.to_s =~ /mswin|mingw|cygwin/i
    end

    def invoke(argv)
      result = @runner.call(argv)
      [result[0].to_s, result[1].to_s, !!result[2]]
    rescue StandardError => e
      ['', "#{e.class}: #{e.message}", false]
    end

    def run_command(argv)
      stdout, stderr, status = Open3.capture3(*argv)
      [stdout, stderr, status.success?]
    end
  end

  def self.run_cli(argv)
    options = {}
    root = File.join(File.expand_path('..', __dir__), 'extracted', 'sketchup_ext')
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby tools/ruby22_real_parse_gate.rb [options]'
      opts.on('--root PATH', 'Extension root to parse') { |value| root = value }
      opts.on('--ruby PATH', 'Exact Ruby 2.2.4p230 executable') do |value|
        options[:env] = ENV.to_hash
        options[:env]['RUBY22_EXE'] = value
      end
    end
    parser.parse!(argv)
    Gate.new(options).run(root) ? 0 : 1
  rescue OptionParser::ParseError => e
    warn(e.message)
    1
  end
end

if __FILE__ == $PROGRAM_NAME
  exit RealRuby224ParseGate.run_cli(ARGV)
end
