#!/usr/bin/env ruby
# A rejected item Raster page render is final for the rest of the import.
#
# The page render is cached per import so every text item crops the same
# picture. Only successes were cached, so once Ghostscript's output was
# rejected (for example a substituted non-embedded font), every later text
# item on that page rendered the whole page again at 300 dpi and was rejected
# for the same reason: about 1.5 s per item, dozens of items per sheet.
#
# All fixtures are made up; nothing here is a real drawing.

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class ItemRasterRejectedPageCacheTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def rejected_run
    # Exit 0 with a font-substitution warning: validate_result! refuses it.
    { :ok => true, :exitstatus => 0, :timed_out => false,
      :stdout => "Substituting font Helvetica for MadeUpSans.\n", :stderr => '' }
  end

  def with_rejecting_renderer
    Dir.mktmpdir('bc_rejected_page') do |folder|
      pdf = File.join(folder, 'made_up.pdf')
      exe = File.join(folder, 'gs.exe')
      File.binwrite(pdf, "%PDF-1.4\nmade up\n%%EOF\n")
      File.binwrite(exe, 'fixture executable')
      counts = { :renders => 0, :resolutions => 0 }
      command = lambda do |args, _options|
        counts[:renders] += 1
        File.binwrite(args[-3], 'not checked') if args[-3].to_s.end_with?('.png')
        rejected_run
      end
      resolve = lambda { counts[:resolutions] += 1; exe }
      IMP::DependencyResolver.stub(:find_ghostscript, resolve) do
        IMP::CommandRunner.stub(:run, command) do
          yield pdf, counts
        end
      end
    end
  end

  def test_a_rejected_page_render_runs_once_and_every_later_item_gets_the_same_reason
    with_rejecting_renderer do |pdf, counts|
      opts = { :raster_dpi => 150 }
      IMP.initialize_item_raster_import_cache!(opts, true)
      messages = Array.new(5) do
        error = assert_raises(IMP::RepresentationFidelity::ContractError) do
          IMP.prepare_item_raster_page!(pdf, 1, [0, 0, 72, 36], 0, opts)
        end
        error.message
      end
      assert_equal 1, counts[:renders], 'the rejected page must not be rendered again'
      assert_equal 1, counts[:resolutions]
      assert_equal 1, messages.uniq.length, 'every item must report the same rejection'
      assert_match(/unverified PDF interpretation/, messages.first)
      IMP.cleanup_item_raster_page_cache!(opts)
    end
  end

  def test_the_rejection_is_kept_per_page_and_cleared_with_the_import_cache
    with_rejecting_renderer do |pdf, counts|
      opts = { :raster_dpi => 150 }
      IMP.initialize_item_raster_import_cache!(opts, true)
      2.times do
        [1, 2].each do |page|
          assert_raises(IMP::RepresentationFidelity::ContractError) do
            IMP.prepare_item_raster_page!(pdf, page, [0, 0, 72, 36], 0, opts)
          end
        end
      end
      assert_equal 2, counts[:renders], 'one render per page, not per item'
      IMP.cleanup_item_raster_page_cache!(opts)
      assert_empty opts[:item_raster_page_failures]
      assert_raises(IMP::RepresentationFidelity::ContractError) do
        IMP.prepare_item_raster_page!(pdf, 1, [0, 0, 72, 36], 0, opts)
      end
      assert_equal 3, counts[:renders], 'a new import cache renders again'
      IMP.cleanup_item_raster_page_cache!(opts)
    end
  end

  def test_an_import_without_text_drops_the_rejection_cache_too
    opts = { :item_raster_page_failures => { 'k' => 'old' } }
    IMP.initialize_item_raster_import_cache!(opts, false)
    refute opts.key?(:item_raster_page_failures)
  end

  def test_errors_that_are_not_contract_rejections_are_not_remembered
    opts = {}
    calls = 0
    2.times do
      assert_raises(IOError) do
        IMP.fetch_item_raster_page_cache!(opts, 'made-up:1:150') do
          calls += 1
          raise IOError, 'transient'
        end
      end
    end
    assert_equal 2, calls
    value = IMP.fetch_item_raster_page_cache!(opts, 'made-up:1:150') { { :ok => true } }
    assert_equal({ :ok => true }, value)
  end
end
