require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_salvage'

class PdfSalvageMemoIntegrityTest < Minitest::Test
  PS = BlueCollarSystems::PDFVectorImporter::PdfSalvage

  def setup
    PS.instance_variable_set(:@memo, {})
  end

  def teardown
    PS.cleanup_all
    PS.instance_variable_set(:@memo, {})
  end

  def public_pdf(x = 20)
    stream = "#{x} 20 m 80 80 l S"
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>',
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"]
    data = "%PDF-1.4\n".dup
    offsets = [0]
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

  def with_normalizer(fail_first = false)
    Dir.mktmpdir('pdf_memo_integrity') do |dir|
      source = File.join(dir, 'public-fixture.pdf')
      File.binwrite(source, public_pdf)
      calls = []
      normalize = lambda do |input|
        if fail_first
          fail_first = false
          raise PS::SalvageError, 'public test helper unavailable'
        end
        output = File.join(dir, 'normalized-' + (calls.length + 1).to_s + '.pdf')
        File.binwrite(output, File.binread(input))
        PS.temp_salvages << output
        calls << output
        [output, 'public test normalization']
      end
      PS.stub(:prepare_uncached, normalize) { yield source, calls }
    end
  end

  def test_unchanged_source_and_normalized_bytes_reuse_the_helper_result
    with_normalizer do |source, calls|
      first = PS.prepare_if_needed(source)
      assert_equal first, PS.prepare_if_needed(source)
      assert_equal 1, calls.length
      assert File.file?(first[0])
    end
  end

  def test_repaired_helper_retries_after_a_transient_error_in_the_same_session
    with_normalizer(true) do |source, calls|
      assert_raises(PS::SalvageError) { PS.prepare_if_needed(source) }
      repaired = PS.prepare_if_needed(source)
      assert_equal 1, calls.length
      assert File.file?(repaired[0])
      assert_equal File.binread(source), File.binread(repaired[0])
    end
  end

  def test_cleanup_does_not_leave_a_deleted_result_in_the_memo
    with_normalizer do |source, calls|
      first = PS.prepare_if_needed(source)[0]
      PS.cleanup(first)
      refute File.exist?(first)
      second = PS.prepare_if_needed(source)[0]
      assert_equal 2, calls.length
      refute_equal first, second
      assert_equal File.binread(source), File.binread(second)
    end
  end

  def test_missing_normalized_file_is_regenerated
    with_normalizer do |source, calls|
      first = PS.prepare_if_needed(source)[0]
      File.delete(first)
      second = PS.prepare_if_needed(source)[0]
      assert_equal 2, calls.length
      refute_equal first, second
      assert File.file?(second)
    end
  end

  def test_same_size_and_mtime_normalized_corruption_is_not_trusted
    with_normalizer do |source, calls|
      first = PS.prepare_if_needed(source)[0]
      stamp = File.mtime(first)
      size = File.size(first)
      File.binwrite(first, public_pdf(30))
      File.utime(stamp, stamp, first)
      assert_equal size, File.size(first)
      assert_equal stamp, File.mtime(first)
      second = PS.prepare_if_needed(source)[0]
      assert_equal 2, calls.length
      refute_equal first, second
      assert_equal File.binread(source), File.binread(second)
    end
  end

  def test_same_size_and_mtime_source_replacement_requires_new_normalization
    with_normalizer do |source, calls|
      first = PS.prepare_if_needed(source)[0]
      stamp = File.mtime(source)
      size = File.size(source)
      File.binwrite(source, public_pdf(30))
      File.utime(stamp, stamp, source)
      assert_equal size, File.size(source)
      assert_equal stamp, File.mtime(source)
      second = PS.prepare_if_needed(source)[0]
      assert_equal 2, calls.length
      refute_equal first, second
      assert_equal File.binread(source), File.binread(second)
      assert_equal public_pdf(20), File.binread(first)
    end
  end
end
