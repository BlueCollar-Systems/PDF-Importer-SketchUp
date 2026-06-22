#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_open_gate'

class PdfOpenGateTest < Minitest::Test
  G = BlueCollarSystems::PDFVectorImporter::PdfOpenGate

  def with_temp_pdf(bytes)
    Dir.mktmpdir("su_open_gate_") do |dir|
      path = File.join(dir, "sample.pdf")
      File.open(path, 'wb') { |f| f.write(bytes) }
      yield path
    end
  end

  def valid_pdf_bytes(extra = '')
    "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<#{extra}>>\nstartxref\n0\n%%EOF\n"
  end

  def test_accepts_pdf_with_header_and_startxref
    with_temp_pdf(valid_pdf_bytes) do |path|
      result = G.inspect_path(path)
      assert_equal true, result[:ok]
    end
  end

  def test_rejects_non_pdf
    with_temp_pdf("hello") do |path|
      result = G.inspect_path(path)
      assert_equal false, result[:ok]
      assert_equal 'not_a_pdf', result[:reason]
    end
  end

  def test_rejects_empty_or_truncated_pdf
    with_temp_pdf("%PDF-1.4\n") do |path|
      result = G.inspect_path(path)
      assert_equal false, result[:ok]
      assert_equal 'empty_or_truncated', result[:reason]
    end
  end

  def test_rejects_encrypted_pdf_marker
    with_temp_pdf(valid_pdf_bytes(" /Encrypt 2 0 R ")) do |path|
      result = G.inspect_path(path)
      assert_equal false, result[:ok]
      assert_equal 'encrypted', result[:reason]
    end
  end
end
