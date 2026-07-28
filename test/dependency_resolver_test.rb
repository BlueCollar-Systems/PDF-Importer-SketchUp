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
        original_ready = @resolver.method(:bundled_bin_ready?)
        @resolver.define_singleton_method(:bundled_bin_dir) { bin_dir }
        @resolver.define_singleton_method(:bundled_bin_ready?) { true }
        assert_equal fake, @resolver.find_pdftocairo
      ensure
        @resolver.define_singleton_method(:bundled_bin_dir, original)
        @resolver.define_singleton_method(:bundled_bin_ready?, original_ready)
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

  def test_missing_helper_notice_describes_bundled_runtime_truthfully
    status = {
      bundled_bin: false,
      pdftocairo: nil,
      pdftotext: nil,
      pdffonts: nil,
      ghostscript: nil,
      mutool: nil
    }
    message = @resolver.build_notice_message(status)

    assert_includes message, 'free bundled Poppler runtime'
    assert_includes message, 'reinstall the latest RBZ'
    refute_match(/source-only/i, message)
    refute_match(/Bundled copy path/i, message)
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

  def with_file_symlink_stub(symlink_path)
    original = File.method(:symlink?)
    target = File.expand_path(symlink_path)
    File.define_singleton_method(:symlink?) do |path|
      File.expand_path(path.to_s) == target || original.call(path)
    end
    yield
  ensure
    File.define_singleton_method(:symlink?, original) if original
  end

  def test_symlinked_manifest_is_rejected_before_json_can_unlock_runtime
    Dir.mktmpdir('bc_dep_manifest_link') do |tmpdir|
      original_support = nil
      begin
        manifest = File.join(tmpdir, 'poppler-runtime-manifest.json')
        File.write(manifest, '{"schema":1,"license_review":{"status":"approved"}}')
        original_support = @resolver.method(:support_dir)
        @resolver.define_singleton_method(:support_dir) { tmpdir }

        with_file_symlink_stub(manifest) do
          assert_nil @resolver.bundled_runtime_manifest
          refute @resolver.bundled_bin_ready?
        end
      ensure
        @resolver.define_singleton_method(:support_dir, original_support) if original_support
      end
    end
  end

  def test_symlinked_support_path_component_is_rejected
    Dir.mktmpdir('bc_dep_support_link') do |tmpdir|
      component = File.join(tmpdir, 'linked-component')
      support = File.join(component, 'bc_pdf_vector_importer')
      FileUtils.mkdir_p(support)

      with_file_symlink_stub(component) do
        refute @resolver.send(:runtime_path_components_symlink_free?, support)
      end
    end
  end
end
