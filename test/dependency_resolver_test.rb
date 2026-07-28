#!/usr/bin/env ruby
# test/dependency_resolver_test.rb

require 'minitest/autorun'
require 'fileutils'
require 'json'
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
        bin_dir = File.join(tmpdir, 'Library', 'bin')
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

  def test_manifest_contract_uses_library_bin_and_rejects_direct_bin_decoy
    Dir.mktmpdir('bc_dep_manifest') do |tmpdir|
      begin
      library_bin = File.join(tmpdir, 'Library', 'bin')
      direct_bin = File.join(tmpdir, 'bin')
      FileUtils.cp_r(File.join(SOURCE_DIR, 'Library'), tmpdir)
      FileUtils.cp_r(File.join(SOURCE_DIR, 'share'), tmpdir)
      FileUtils.mkdir_p(direct_bin)
      %w[pdftocairo.exe pdftotext.exe pdffonts.exe].each do |name|
        File.write(File.join(direct_bin, name), 'legacy-decoy')
      end
      manifest = JSON.parse(File.read(File.join(
        SOURCE_DIR, 'poppler-runtime-manifest.json'
      )))
      manifest['license_review'] = {
        'status' => 'approved', 'missing' => [],
        'reviewer' => 'Qualified Reviewer',
        'reviewed_at' => '2026-07-16T00:00:00Z',
        'evidence' => 'legal-review-record-1'
      }
      File.write(File.join(tmpdir, 'poppler-runtime-manifest.json'),
                 JSON.generate(manifest))

      original = @resolver.method(:support_dir)
      @resolver.define_singleton_method(:support_dir) { tmpdir }
      assert_equal library_bin, @resolver.bundled_bin_dir
      refute @resolver.bundled_bin_ready?, 'legacy direct bin must invalidate exact runtime'
      FileUtils.rm_rf(direct_bin)
      if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
        assert @resolver.bundled_bin_ready?
        assert_equal File.join(library_bin, 'pdftocairo.exe'),
                     @resolver.send(:bundled_executable, 'pdftocairo.exe')
      else
        refute @resolver.bundled_bin_ready?
        assert_nil @resolver.send(:bundled_executable, 'pdftocairo.exe')
      end
      ensure
        @resolver.define_singleton_method(:support_dir, original) if original
      end
    end
  end

  def test_blocked_or_malformed_manifest_disables_bundled_helpers
    Dir.mktmpdir('bc_dep_blocked') do |tmpdir|
      begin
      bin_dir = File.join(tmpdir, 'Library', 'bin')
      FileUtils.mkdir_p(bin_dir)
      %w[pdftocairo.exe pdftotext.exe pdffonts.exe].each do |name|
        File.write(File.join(bin_dir, name), 'present')
      end
      manifest = {
        schema: 1,
        layout: {
          bin: 'Library/bin', data: 'share/poppler',
          manifest: 'poppler-runtime-manifest.json'
        },
        license_review: { status: 'blocked', missing: ['review'] }
      }
      File.write(File.join(tmpdir, 'poppler-runtime-manifest.json'), JSON.generate(manifest))

      original = @resolver.method(:support_dir)
      @resolver.define_singleton_method(:support_dir) { tmpdir }
      refute @resolver.bundled_bin_ready?
      assert_nil @resolver.send(:bundled_executable, 'pdftocairo.exe')

      manifest[:license_review] = { status: 'approved', missing: [] }
      File.write(File.join(tmpdir, 'poppler-runtime-manifest.json'), JSON.generate(manifest))
      refute @resolver.bundled_bin_ready?, 'bare approved status must not unlock binaries'

      manifest[:layout][:bin] = '../outside'
      manifest[:license_review] = {
        status: 'approved', missing: [], reviewer: 'Qualified Reviewer',
        reviewed_at: '2026-07-16T00:00:00Z', evidence: 'legal-review-record-1'
      }
      File.write(File.join(tmpdir, 'poppler-runtime-manifest.json'), JSON.generate(manifest))
      refute @resolver.bundled_bin_ready?
      assert_nil @resolver.send(:bundled_executable, 'pdftocairo.exe')
      ensure
        @resolver.define_singleton_method(:support_dir, original) if original
      end
    end
  end

  def test_runtime_integrity_rejects_dll_tamper_extra_member_and_missing_data
    Dir.mktmpdir('bc_dep_integrity') do |tmpdir|
      FileUtils.cp_r(File.join(SOURCE_DIR, 'Library'), tmpdir)
      FileUtils.cp_r(File.join(SOURCE_DIR, 'share'), tmpdir)
      manifest_path = File.join(tmpdir, 'poppler-runtime-manifest.json')
      manifest = JSON.parse(File.read(File.join(
        SOURCE_DIR, 'poppler-runtime-manifest.json'
      )))
      manifest['license_review'] = {
        'status' => 'approved', 'missing' => [],
        'reviewer' => 'Qualified Reviewer',
        'reviewed_at' => '2026-07-16T00:00:00Z',
        'evidence' => 'legal-review-record-1'
      }
      File.write(manifest_path, JSON.generate(manifest))

      assert @resolver.send(:bundled_runtime_integrity_valid?, tmpdir, manifest)

      dll = File.join(tmpdir, 'Library', 'bin', 'poppler.dll')
      original_dll = File.binread(dll)
      File.open(dll, 'wb') { |io| io.write(original_dll[0...-1]) }
      refute @resolver.send(:bundled_runtime_integrity_valid?, tmpdir, manifest)
      File.open(dll, 'wb') { |io| io.write(original_dll) }

      extra = File.join(tmpdir, 'Library', 'bin', 'unreviewed.dll')
      File.write(extra, 'extra')
      refute @resolver.send(:bundled_runtime_integrity_valid?, tmpdir, manifest)
      File.delete(extra)

      data = File.join(tmpdir, 'share', 'poppler', 'cidToUnicode', 'Adobe-GB1')
      original_data = File.binread(data)
      File.delete(data)
      refute @resolver.send(:bundled_runtime_integrity_valid?, tmpdir, manifest)
      File.open(data, 'wb') { |io| io.write(original_data) }

      assert @resolver.send(:bundled_runtime_integrity_valid?, tmpdir, manifest)
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
