#!/usr/bin/env ruby
# test/dependency_resolver_test.rb

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
SOURCE_DIR = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer')

$LOAD_PATH.unshift SOURCE_DIR
require File.join(SOURCE_DIR, 'logger')
require File.join(SOURCE_DIR, 'command_runner')
require File.join(SOURCE_DIR, 'dependency_resolver')

module BlueCollarSystems
  module PDFVectorImporter
    unless defined?(PLUGIN_VERSION)
      PLUGIN_VERSION = 'test'.freeze
    end
  end
end

class DependencyResolverTest < Minitest::Test
  def setup
    @resolver = BlueCollarSystems::PDFVectorImporter::DependencyResolver
    @orig_env = {}
    %w[BC_PDFTOCAIRO_PATH BC_PDFTOTEXT_PATH BC_MUTOOL_PATH BC_GHOSTSCRIPT_PATH].each do |key|
      @orig_env[key] = ENV[key]
      ENV.delete(key)
    end
  end

  def teardown
    @orig_env.each { |key, val| val ? ENV[key] = val : ENV.delete(key) }
  end

  def test_bundled_bin_preferred_over_system_search
    Dir.mktmpdir('bc_dep_test') do |tmpdir|
      begin
        bin_dir = File.join(tmpdir, 'bin')
        FileUtils.mkdir_p(bin_dir)
        exe_name = RUBY_PLATFORM =~ /mswin|mingw|cygwin/ ? 'pdftocairo.exe' : 'pdftocairo'
        fake = File.join(bin_dir, exe_name)
        File.write(fake, 'stub')

        original = @resolver.method(:bundled_bin_dir)
        @resolver.define_singleton_method(:bundled_bin_dir) { bin_dir }
        assert_equal fake, @resolver.find_pdftocairo
      ensure
        @resolver.define_singleton_method(:bundled_bin_dir, original)
      end
    end
  end

  def test_missing_recommended_lists_poppler_when_no_helpers
    status = {
      bundled_bin: false,
      pdftocairo: nil,
      pdftotext: nil,
      pdffonts: nil,
      ghostscript: nil,
      mutool: nil
    }
    missing = @resolver.missing_recommended(status)
    assert_includes missing, :poppler
    assert_includes missing, :pdftotext
    assert_includes missing, :ghostscript
  end

  def test_download_lines_include_poppler_url
    lines = @resolver.download_lines(%i[poppler pdftotext ghostscript])
    joined = lines.join("\n")
    assert_includes joined, 'poppler-windows'
    assert_includes joined, 'ghostscript.com'
  end

  def test_build_notice_message_nil_when_all_present
    status = {
      bundled_bin: true,
      pdftocairo: 'C:/bin/pdftocairo.exe',
      pdftotext: 'C:/bin/pdftotext.exe',
      pdffonts: 'C:/bin/pdffonts.exe',
      ghostscript: 'C:/bin/gswin64c.exe',
      mutool: nil
    }
    assert_nil @resolver.build_notice_message(status)
  end
end
