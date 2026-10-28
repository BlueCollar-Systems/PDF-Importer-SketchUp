#!/usr/bin/env ruby
# The font-embedded copy of the user's drawing is deleted when the import
# ends: after success, after a failure and after Esc.
#
# SvgTextRenderer.embed_fonts_cached writes a full copy of the drawing with
# its fonts embedded (bc_embed_<pid>_<time>_<rand>.pdf) into the temp folder
# so Poppler can draw non-embedded fonts. That copy was kept for the whole
# SketchUp session and never deleted.
#
# The PDF here is made up; Ghostscript is stubbed.

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class EmbeddedFontCopyCleanupTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  SVG = IMP::SvgTextRenderer

  def setup
    @folder = Dir.mktmpdir('bc_embed_cleanup')
    @pdf = File.join(@folder, 'made_up.pdf')
    File.binwrite(@pdf, "%PDF-1.4\nmade up drawing\n%%EOF\n")
    SVG.release_embedded_font_copies!
  end

  def teardown
    FileUtils.remove_entry(@folder) if @folder && File.directory?(@folder)
    SVG.release_embedded_font_copies!
  end

  def embedded_copy
    writer = lambda do |args, _opts|
      out = args[args.index('-o') + 1]
      File.binwrite(out, File.binread(@pdf))
      { :ok => true, :exitstatus => 0, :stdout => '', :stderr => '' }
    end
    copy = IMP::CommandRunner.stub(:run, writer) do
      SVG.embed_fonts_cached(@pdf, File.join(@folder, 'gs.exe'))
    end
    assert copy && File.file?(copy), 'the stubbed embed must leave a copy'
    copy
  end

  def test_release_deletes_the_copy_and_forgets_it
    copy = embedded_copy
    assert_equal 1, SVG.release_embedded_font_copies!
    refute File.exist?(copy), 'the copy of the drawing must be gone'
    assert_equal 0, SVG.release_embedded_font_copies!
    again = embedded_copy
    refute_equal copy, again, 'a later import makes a fresh copy'
  end

  # Explicit Raster through the real non-resumable path: the stub stands in
  # for the page work after the copy was made.
  def raster_import(inner)
    opts = { :large_pdf_confirmed => true, :force_raster => true, :text_mode => :raster,
             :cancel_probe => Object.new }
    IMP.stub(:run_forced_raster_pipeline, inner) do
      IMP.run_resumable_pipeline(Object.new, @pdf, opts)
    end
  end

  def test_a_finished_import_deletes_the_copy
    copy = nil
    stats = raster_import(lambda { |*_args| copy = embedded_copy; { :pages => 1 } })
    assert_equal({ :pages => 1 }, stats)
    refute File.exist?(copy)
  end

  def test_a_failed_import_deletes_the_copy
    copy = nil
    assert_raises(RuntimeError) do
      raster_import(lambda { |*_args| copy = embedded_copy; raise 'made-up failure' })
    end
    refute File.exist?(copy)
  end

  def test_an_import_stopped_with_esc_deletes_the_copy
    copy = nil
    result = raster_import(lambda do |*_args|
      copy = embedded_copy
      raise IMP::ImportRunControl::ImportCancelled.new([], 1, nil)
    end)
    assert_equal false, result[:resume_supported]
    refute File.exist?(copy)
  end

  def test_a_resumable_page_keeps_the_copy_for_the_next_page
    copy = nil
    opts = { :resumable_page_call => true, :preserve_prepared_parser => true,
             :preserve_logger => true, :force_raster => true }
    IMP.stub(:run_forced_raster_pipeline, lambda { |*_args| copy = embedded_copy; {} }) do
      IMP.run_pipeline(Object.new, @pdf, opts)
    end
    assert File.exist?(copy), 'a page of a resumable import must not delete it'
  end

  def test_a_resumable_import_deletes_the_copy_when_it_fails_or_is_stopped
    opts = { :large_pdf_confirmed => true, :resumable => true, :import_text => true,
             :text_mode => :text3d, :group_per_page => true }
    [RuntimeError.new('made-up failure'),
     IMP::ImportRunControl::ImportCancelled.new([], 1, nil)].each do |failure|
      copy = nil
      prepare = lambda { |*_args| copy = embedded_copy; raise failure }
      raised = assert_raises(failure.class) do
        IMP::PdfSalvage.stub(:prepare_if_needed, prepare) do
          IMP.run_resumable_pipeline(Object.new, @pdf, opts)
        end
      end
      assert_same failure, raised
      refute File.exist?(copy), "#{failure.class} must not leave the copy"
    end
  end

  def test_the_headless_cli_deletes_the_copy
    source = File.read(File.join(File.dirname(__FILE__), '..', 'extracted', 'sketchup_ext',
                                 'bc_pdf_vector_importer', 'cli.rb'))
    run_body = source[/def run\(cli_opts\).*?\n      def extract_pdf/m]
    refute_nil run_body
    assert_match(/ensure.*SvgTextRenderer\.release_embedded_font_copies!/m, run_body)
  end
end
