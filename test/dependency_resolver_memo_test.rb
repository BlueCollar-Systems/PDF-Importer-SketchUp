#!/usr/bin/env ruby
# The bundled-helper checks are remembered for one import, and anything that
# changes the checked tree runs the full check again.
#
# find_ghostscript re-hashed the whole bundled Ghostscript tree (27 MB,
# about 230 files) on every call, and every Poppler helper selection walked
# the whole Library/share tree for symlinks. Inside an import both now
# remember a clean result with a stamp of the tree taken before the check.
# The import forgets both when it starts and when it ends, so the next import
# runs each full check again: a helper changed between imports is caught even
# when its sizes and times were put back.
#
# The Poppler trees and the PDF here are made up; the Ghostscript tree is a
# temporary copy of the one this repo ships.

require 'minitest/autorun'
require 'minitest/mock'
require 'fileutils'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SOURCE_DIR = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer') unless defined?(SOURCE_DIR)

require File.join(SOURCE_DIR, 'logger')
require File.join(SOURCE_DIR, 'command_runner')
require File.join(SOURCE_DIR, 'dependency_resolver')
require File.join(SOURCE_DIR, 'main')

class DependencyResolverMemoTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def setup
    @resolver = IMP::DependencyResolver
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
    reset_import_window
  end

  def teardown
    @resolver.define_singleton_method(:support_dir, @support)
    @resolver.define_singleton_method(:windows?, @windows)
    @resolver.define_singleton_method(:bundled_executable_launchable?, @launch)
    @resolver.define_singleton_method(:sha256_file, @sha)
    reset_import_window
  end

  def reset_import_window
    @resolver.instance_variable_set(:@import_check_depth, 0)
    @resolver.forget_verified_helper_trees!
  end

  def with_ghostscript_copy(prefix)
    Dir.mktmpdir(prefix) do |dir|
      FileUtils.cp_r(File.join(@support.call, 'Ghostscript'), dir)
      @resolver.define_singleton_method(:support_dir) { dir }
      yield dir
    end
  end

  def test_a_verified_ghostscript_tree_is_hashed_once_per_import_until_it_changes
    with_ghostscript_copy('bcs_gs_memo') do |dir|
      @resolver.with_import_checks do
        first = @resolver.bundled_ghostscript_executable
        assert first
        hashed_once = @hashes
        assert_operator hashed_once, :>, 100, 'the first call checks every member'

        3.times { assert_equal first, @resolver.bundled_ghostscript_executable }
        assert_equal hashed_once, @hashes, 'an unchanged tree is not hashed again in one import'

        license = File.join(dir, 'Ghostscript', 'licenses', 'doc', 'COPYING')
        File.open(license, 'ab') { |handle| handle.write('changed') }
        assert_nil @resolver.bundled_ghostscript_executable
        assert_operator @hashes, :>, hashed_once, 'a changed member runs the full check'
        after_change = @hashes
        assert_nil @resolver.bundled_ghostscript_executable
        assert_operator @hashes, :>, after_change, 'a failed check is never remembered'
      end
    end
  end

  def test_an_added_ghostscript_member_is_refused_after_a_remembered_success
    with_ghostscript_copy('bcs_gs_memo_add') do |dir|
      @resolver.with_import_checks do
        assert @resolver.bundled_ghostscript_executable
        assert @resolver.bundled_ghostscript_executable
        File.write(File.join(dir, 'Ghostscript', 'bin', 'made_up_extra.dll'), 'extra')
        assert_nil @resolver.bundled_ghostscript_executable
      end
    end
  end

  # Review finding on e80163c: the check was remembered for the whole
  # SketchUp session, and only sizes and times were compared afterwards, so a
  # content change that kept both was never seen again.
  def test_a_same_size_same_time_change_between_imports_is_caught_by_the_next_import
    with_ghostscript_copy('bcs_gs_memo_between') do |dir|
      root = File.join(dir, 'Ghostscript')
      found = @resolver.with_import_checks { @resolver.bundled_ghostscript_executable }
      assert found
      stamp_before = @resolver.send(:runtime_tree_stamp, File.expand_path(root))
      refute_nil stamp_before

      license = File.join(root, 'licenses', 'doc', 'COPYING')
      kept = File.stat(license)
      bytes = File.binread(license)
      bytes.setbyte(0, bytes.getbyte(0) ^ 0x01)
      File.binwrite(license, bytes)
      File.utime(kept.atime, kept.mtime, license)
      assert_equal stamp_before,
                   @resolver.send(:runtime_tree_stamp, File.expand_path(root)),
                   'the edit keeps every size and time, so only a full check can see it'
      assert_nil @resolver.verify_bundled_ghostscript_tree(File.expand_path(root)),
                 'a full check refuses the edited tree'

      before_next = @hashes
      next_import = @resolver.with_import_checks { @resolver.bundled_ghostscript_executable }
      assert_nil next_import, 'the next import must not reuse the earlier check'
      assert_operator @hashes, :>, before_next, 'the next import runs the full check'
    end
  end

  def test_each_import_runs_one_full_check_and_nothing_is_kept_outside_an_import
    with_ghostscript_copy('bcs_gs_memo_window') do |_dir|
      per_import = []
      2.times do
        before = @hashes
        @resolver.with_import_checks do
          4.times { assert @resolver.bundled_ghostscript_executable }
        end
        per_import << @hashes - before
      end
      assert_operator per_import[0], :>, 100
      assert_equal per_import[0], per_import[1], 'every import pays exactly one full check'
      refute @resolver.import_checks_open?

      before = @hashes
      assert @resolver.bundled_ghostscript_executable
      once = @hashes - before
      assert @resolver.bundled_ghostscript_executable
      assert_equal 2 * once, @hashes - before,
                   'outside an import every call runs the full check'
    end
  end

  def test_the_import_window_closes_when_the_block_raises
    assert_raises(RuntimeError) do
      @resolver.with_import_checks { raise 'made-up failure' }
    end
    refute @resolver.import_checks_open?
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
      @resolver.with_import_checks do
        first = count_listings { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
        assert_operator first, :>, 0
        again = count_listings do
          3.times { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
        end
        assert_equal 0, again, 'an unchanged tree is not listed again in one import'
      end
    end
  end

  def test_the_trust_walk_is_forgotten_when_the_import_ends
    Dir.mktmpdir('bcs_trust_memo_window') do |dir|
      root = made_up_poppler_tree(dir)
      @resolver.with_import_checks do
        assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
      end
      outside = count_listings do
        2.times { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
      end
      first = count_listings { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
      assert_equal 2 * first, outside, 'outside an import every call walks the tree'
      next_import = @resolver.with_import_checks do
        count_listings { assert @resolver.send(:runtime_trust_paths_symlink_free?, root) }
      end
      assert_equal first, next_import, 'the next import walks the tree again'
    end
  end

  def test_a_new_entry_after_a_remembered_walk_is_walked_and_a_symlink_refused
    Dir.mktmpdir('bcs_trust_memo_new') do |dir|
      root = made_up_poppler_tree(dir)
      @resolver.with_import_checks do
        assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
        # Ruby 2.2 on Windows (SketchUp 2017) reads file times in whole
        # seconds, so the entry is added in a later second.
        sleep 1.1
        planted = File.join(root, 'share', 'poppler', 'cMap', 'MadeUp', 'planted')
        File.write(planted, 'stub')
        with_symlink_stub(planted) do
          refute @resolver.send(:runtime_trust_paths_symlink_free?, root),
                 'an entry added after the remembered walk must be checked'
        end
        assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
      end
    end
  end

  def test_a_remembered_directory_that_becomes_a_symlink_is_refused
    Dir.mktmpdir('bcs_trust_memo_dir') do |dir|
      root = made_up_poppler_tree(dir)
      @resolver.with_import_checks do
        assert @resolver.send(:runtime_trust_paths_symlink_free?, root)
        with_symlink_stub(File.join(root, 'share', 'poppler', 'cMap')) do
          refute @resolver.send(:runtime_trust_paths_symlink_free?, root)
        end
      end
    end
  end

  # The real import entry opens the window for the whole import and closes
  # it after success, a failure and Esc, on the non-resumable and the
  # resumable paths. The page work is stubbed; the PDF is made up.
  def made_up_pdf(dir)
    pdf = File.join(dir, 'made_up.pdf')
    File.binwrite(pdf, "%PDF-1.4\nmade up drawing\n%%EOF\n")
    pdf
  end

  def raster_import(pdf, inner)
    opts = { :large_pdf_confirmed => true, :force_raster => true, :text_mode => :raster,
             :cancel_probe => Object.new }
    IMP.stub(:run_forced_raster_pipeline, inner) do
      IMP.run_resumable_pipeline(Object.new, pdf, opts)
    end
  end

  def test_the_import_entry_checks_once_and_forgets_after_success_failure_and_esc
    with_ghostscript_copy('bcs_gs_memo_entry') do |dir|
      pdf = made_up_pdf(dir)
      outcomes = [
        lambda { { :pages => 1 } },
        lambda { raise 'made-up failure' },
        lambda { raise IMP::ImportRunControl::ImportCancelled.new([], 1, nil) }
      ]
      outcomes.each do |finish|
        seen = {}
        inner = lambda do |*_args|
          seen[:open] = @resolver.import_checks_open?
          before = @hashes
          3.times { assert @resolver.bundled_ghostscript_executable }
          seen[:hashes] = @hashes - before
          finish.call
        end
        begin
          raster_import(pdf, inner)
        rescue RuntimeError
          nil
        end
        assert_equal true, seen[:open], 'the import runs inside the window'
        assert_operator seen[:hashes], :>, 100
        assert_operator seen[:hashes], :<, 400, 'one full check per import, not one per call'
        refute @resolver.import_checks_open?, 'the window closes when the import ends'
        assert_nil @resolver.instance_variable_get(:@verified_bundled_ghostscript),
                   'nothing is kept past the import'
      end
    end
  end

  def test_the_resumable_import_closes_the_window_when_it_fails_or_is_stopped
    Dir.mktmpdir('bcs_gs_memo_resumable') do |dir|
      pdf = made_up_pdf(dir)
      opts = { :large_pdf_confirmed => true, :resumable => true, :import_text => true,
               :text_mode => :text3d, :group_per_page => true }
      [RuntimeError.new('made-up failure'),
       IMP::ImportRunControl::ImportCancelled.new([], 1, nil)].each do |failure|
        seen = nil
        prepare = lambda { |*_args| seen = @resolver.import_checks_open?; raise failure }
        raised = assert_raises(failure.class) do
          IMP::PdfSalvage.stub(:prepare_if_needed, prepare) do
            IMP.run_resumable_pipeline(Object.new, pdf, opts)
          end
        end
        assert_same failure, raised
        assert_equal true, seen
        refute @resolver.import_checks_open?, "#{failure.class} must close the window"
      end
    end
  end
end
