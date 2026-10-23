#!/usr/bin/env ruby
# The bundled-helper checks are remembered, and anything that changes the
# checked tree runs the full check again.
#
# find_ghostscript re-hashed the whole bundled Ghostscript tree (27 MB,
# about 230 files) on every call, and every Poppler helper selection walked
# the whole Library/share tree for symlinks. Both now remember a clean result
# with a stamp of the tree taken before the check.
#
# All fixture trees here are made up.

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SOURCE_DIR = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer') unless defined?(SOURCE_DIR)

require File.join(SOURCE_DIR, 'logger')
require File.join(SOURCE_DIR, 'command_runner')
require File.join(SOURCE_DIR, 'dependency_resolver')

class DependencyResolverMemoTest < Minitest::Test
  def setup
    @resolver = BlueCollarSystems::PDFVectorImporter::DependencyResolver
    @support = @resolver.method(:support_dir)
    @windows = @resolver.method(:windows?)
    @launch = @resolver.method(:bundled_executable_launchable?)
    @sha = @resolver.method(:sha256_file)
    @resolver.define_singleton_method(:windows?) { true }
    @resolver.define_singleton_method(:bundled_executable_launchable?) { |_path| true }
    @hashes = 0
    original_sha = @sha
    counter = self
    @resolver.define_singleton_method(:sha256_file) do |path|
      counter.instance_variable_set(:@hashes, counter.instance_variable_get(:@hashes) + 1)
      original_sha.call(path)
    end
  end

  def teardown
    @resolver.define_singleton_method(:support_dir, @support)
    @resolver.define_singleton_method(:windows?, @windows)
    @resolver.define_singleton_method(:bundled_executable_launchable?, @launch)
    @resolver.define_singleton_method(:sha256_file, @sha)
  end

  def test_a_verified_ghostscript_tree_is_hashed_once_until_it_changes
    Dir.mktmpdir('bcs_gs_memo') do |dir|
      FileUtils.cp_r(File.join(@support.call, 'Ghostscript'), dir)
      @resolver.define_singleton_method(:support_dir) { dir }
      first = @resolver.bundled_ghostscript_executable
      assert first
      hashed_once = @hashes
      assert_operator hashed_once, :>, 100, 'the first call checks every member'

      3.times { assert_equal first, @resolver.bundled_ghostscript_executable }
      assert_equal hashed_once, @hashes, 'an unchanged tree is not hashed again'

      license = File.join(dir, 'Ghostscript', 'licenses', 'doc', 'COPYING')
      File.open(license, 'ab') { |handle| handle.write('changed') }
      assert_nil @resolver.bundled_ghostscript_executable
      assert_operator @hashes, :>, hashed_once, 'a changed member runs the full check'
      after_change = @hashes
      assert_nil @resolver.bundled_ghostscript_executable
      assert_operator @hashes, :>, after_change, 'a failed check is never remembered'
    end
  end

  def test_an_added_ghostscript_member_is_refused_after_a_remembered_success
    Dir.mktmpdir('bcs_gs_memo_add') do |dir|
      FileUtils.cp_r(File.join(@support.call, 'Ghostscript'), dir)
      @resolver.define_singleton_method(:support_dir) { dir }
      assert @resolver.bundled_ghostscript_executable
      assert @resolver.bundled_ghostscript_executable
      File.write(File.join(dir, 'Ghostscript', 'bin', 'made_up_extra.dll'), 'extra')
      assert_nil @resolver.bundled_ghostscript_executable
    end
  end

  def made_up_poppler_tree(dir)
    FileUtils.mkdir_p(File.join(dir, 'Library', 'bin'))
    FileUtils.mkdir_p(File.join(dir, 'share', 'poppler', 'cMap', 'MadeUp'))
    File.write(File.join(dir, 'poppler-runtime-manifest.json'), '{}')
    File.write(File.join(dir, 'Library', 'bin', 'made_up_helper.exe'), 'stub')
    File.write(File.join(dir, 'share', 'poppler', 'cMap', 'MadeUp', 'map'), 'stub')
    dir
  end

  def count_listings
    listings = 0
    glob = Dir.method(:glob)
    entries = Dir.method(:entries)
    Dir.define_singleton_method(:glob) { |*args, &block| listings += 1; glob.call(*args, &block) }
    Dir.define_singleton_method(:entries) { |*args, &block| listings += 1; entries.call(*args, &block) }
    yield
    listings
  ensure
    Dir.define_singleton_method(:glob, glob)
    Dir.define_singleton_method(:entries, entries)
  end

  def with_symlink_stub(target)
    original = File.method(:symlink?)
    File.define_singleton_method(:symlink?) do |path|
      File.expand_path(path.to_s) == File.expand_path(target) ? true : original.call(path)
    end
    yield
  ensure
    File.define_singleton_method(:symlink?, original)
  end

  def test_a_clean_trust_walk_is_not_repeated_while_the_tree_is_unchanged
    Dir.mktmpdir('bcs_trust_memo') do |dir|
      root = made_up_poppler_tree(dir)
      first = count_listings { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
      assert_operator first, :>, 0
      again = count_listings do
        3.times { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
      end
      assert_equal 0, again, 'an unchanged tree is not listed again'
    end
  end

  def test_a_new_entry_after_a_remembered_walk_is_walked_and_a_symlink_refused
    Dir.mktmpdir('bcs_trust_memo_new') do |dir|
      root = made_up_poppler_tree(dir)
      assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
      sleep 0.05
      planted = File.join(root, 'share', 'poppler', 'cMap', 'MadeUp', 'planted')
      File.write(planted, 'stub')
      with_symlink_stub(planted) do
        refute @resolver.send(:runtime_trust_paths_symlink_free?, root),
               'an entry added after the remembered walk must be checked'
      end
      assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
    end
  end

  def test_a_remembered_directory_that_becomes_a_symlink_is_refused
    Dir.mktmpdir('bcs_trust_memo_dir') do |dir|
      root = made_up_poppler_tree(dir)
      assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
      with_symlink_stub(File.join(root, 'share', 'poppler', 'cMap')) do
        refute @resolver.send(:runtime_trust_paths_symlink_free?, root)
      end
    end
  end
end
