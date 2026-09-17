require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_salvage'

class PdfSalvageScreenRecoveryTest < Minitest::Test
  PS = BlueCollarSystems::PDFVectorImporter::PdfSalvage

  def public_pdf
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>',
      "<< /Length 0 >>\nstream\n\nendstream"]
    data = "%PDF-1.4\n".dup; offsets = [0]
    objects.each_with_index do |value, index|
      offsets << data.bytesize
      data << "#{index + 1} 0 obj\n#{value}\nendobj\n"
    end
    xref = data.bytesize
    data << "xref\n0 5\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| data << format('%010d 00000 n ', offset) + "\n" }
    data << "trailer << /Size 5 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    data
  end

  def exercise_recovery(reason, should_fail)
    Dir.mktmpdir('pdf_screen_recovery') do |dir|
      source = File.join(dir, 'original.pdf')
      printed_copy = File.join(dir, 'printing-recovery.pdf')
      screen_copy = File.join(dir, 'screen-normalized.pdf')
      [source, printed_copy, screen_copy].each { |path| File.binwrite(path, public_pdf) }
      PS.temp_salvages << printed_copy
      received = []
      normalize = lambda do |input, page_count = nil|
        received << [input, page_count]
        raise PS::SalvageError, 'public screen-normalizer failure' if should_fail
        screen_copy
      end
      PS.stub(:needs_salvage_reason, reason) do
        PS.stub(:salvage_with_poppler, printed_copy) do
          PS.stub(:normalize_annotation_appearances, normalize) do
            if should_fail
              assert_raises(PS::SalvageError) { PS.send(:prepare_uncached, source) }
            else
              result = PS.send(:prepare_uncached, source)
              assert_equal screen_copy, result[0]
              refute_equal printed_copy, result[0]
            end
          end
        end
      end
      assert_equal [[source, 1]], received, 'GS must flatten the original; printing recovery only proves page count'
      refute File.exist?(printed_copy), 'Temporary printing recovery must always be removed'
      refute_includes PS.temp_salvages, printed_copy
      assert_equal public_pdf, File.binread(source)
    end
  end

  def test_encrypted_recovery_normalizes_original_with_independent_page_count
    exercise_recovery('encrypted', false)
  end

  def test_damaged_recovery_normalizes_original_with_independent_page_count
    exercise_recovery('parse failed: PublicFixtureError', false)
  end

  def test_failed_screen_normalization_still_cleans_printing_recovery
    exercise_recovery('encrypted', true)
  end
end
