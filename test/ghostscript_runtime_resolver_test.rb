require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/dependency_resolver'

class GhostscriptRuntimeResolverTest < Minitest::Test
  def setup
    @resolver = BlueCollarSystems::PDFVectorImporter::DependencyResolver
    @support = @resolver.method(:support_dir)
    @windows = @resolver.method(:windows?)
    @launch = @resolver.method(:bundled_executable_launchable?)
    @resolver.define_singleton_method(:windows?) { true }
    @resolver.define_singleton_method(:bundled_executable_launchable?) { |_path| true }
  end

  def teardown
    @resolver.define_singleton_method(:support_dir, @support)
    @resolver.define_singleton_method(:windows?, @windows)
    @resolver.define_singleton_method(:bundled_executable_launchable?, @launch)
  end

  def test_exact_separate_runtime_resolves_without_poppler_inventory
    actual = @resolver.bundled_ghostscript_executable
    assert actual
    assert_equal 'gswin64c.exe', File.basename(actual)
    assert_includes actual.tr('\\', '/'), '/Ghostscript/bin/'
  end

  def test_extra_member_or_modified_license_fails_closed
    Dir.mktmpdir('bcs_gs_manifest') do |dir|
      FileUtils.cp_r(File.join(@support.call, 'Ghostscript'), dir)
      @resolver.define_singleton_method(:support_dir) { dir }
      assert @resolver.bundled_ghostscript_executable
      extra = File.join(dir, 'Ghostscript', 'bin', 'unexpected.dll')
      File.write(extra, 'unexpected')
      assert_nil @resolver.bundled_ghostscript_executable
      File.delete(extra)
      File.open(File.join(dir, 'Ghostscript', 'licenses', 'doc', 'COPYING'), 'ab') { |handle| handle.write('changed') }
      assert_nil @resolver.bundled_ghostscript_executable
    end
  end
end
