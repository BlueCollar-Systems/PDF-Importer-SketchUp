#!/usr/bin/env ruby
# R21-18 / QQ-3: missing paths must refuse as file_missing without spawning
# pdftocairo (PdfSalvage memoization cannot key absent paths).

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/pdf_open_gate'
require 'bc_pdf_vector_importer/pdf_salvage'
require 'bc_pdf_vector_importer/main'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

class OpenGateFileMissingSalvageTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  PS = IMP::PdfSalvage

  def test_file_missing_skips_salvage_and_pdftocairo
    missing = File.join(Dir.tmpdir, "bc_missing_#{Process.pid}_#{rand(1_000_000)}.pdf")
    refute File.exist?(missing), 'precondition: path must not exist'

    salvage_calls = 0
    original_prepare = PS.method(:prepare_if_needed)
    PS.define_singleton_method(:prepare_if_needed) do |_path|
      salvage_calls += 1
      raise 'pdftocairo must not be invoked for file_missing'
    end

    cairo_calls = 0
    original_run = PS.method(:run_pdftocairo) if PS.respond_to?(:run_pdftocairo, true)
    begin
      if original_run
        PS.define_singleton_method(:run_pdftocairo) do |*_args|
          cairo_calls += 1
          false
        end
      end

      result = IMP.handle_open_gate(missing, {}, show_ui: false)
      assert result, 'missing path must refuse'
      refute result[:ok]
      assert_equal 'file_missing', result[:reason]
      assert_equal 0, salvage_calls, 'prepare_if_needed must not run for file_missing'
      assert_equal 0, cairo_calls, 'pdftocairo must not run for file_missing'
    ensure
      PS.define_singleton_method(:prepare_if_needed, original_prepare)
      if original_run
        PS.define_singleton_method(:run_pdftocairo, original_run)
      end
    end
  end

  def test_not_a_pdf_still_skips_salvage
    Dir.mktmpdir('su_not_pdf_') do |dir|
      path = File.join(dir, 'notes.txt')
      File.write(path, 'not a pdf')

      salvage_calls = 0
      original_prepare = PS.method(:prepare_if_needed)
      PS.define_singleton_method(:prepare_if_needed) do |_path|
        salvage_calls += 1
        [path, nil]
      end
      begin
        result = IMP.handle_open_gate(path, {}, show_ui: false)
        assert result
        refute result[:ok]
        assert_equal 'not_a_pdf', result[:reason]
        assert_equal 0, salvage_calls
      ensure
        PS.define_singleton_method(:prepare_if_needed, original_prepare)
      end
    end
  end
end
