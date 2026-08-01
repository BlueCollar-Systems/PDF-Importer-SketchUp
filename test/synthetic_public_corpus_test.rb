#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require 'open3'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'extracted', 'sketchup_ext'))
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/pdf_open_gate'

class SyntheticPublicCorpusTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::PDFParser
  OpenGate = BlueCollarSystems::PDFVectorImporter::PdfOpenGate

  def test_generated_corpus_is_deterministic_private_free_and_multipage
    Dir.mktmpdir('bcs-public-corpus-a') do |first|
      Dir.mktmpdir('bcs-public-corpus-b') do |second|
        generate(first)
        generate(second)
        one = JSON.parse(File.read(File.join(first, 'manifest.json')))
        two = JSON.parse(File.read(File.join(second, 'manifest.json')))
        assert_equal one, two
        assert_equal 'bcs.synthetic_public_pdf_corpus/1.0', one['schema']
        assert_equal 'generated solely from literal public test instructions',
                     one['provenance']
        required = %w[
          rotation crop_box clipping type3_font soft_mask zero_ink
          inline_image page_2_plus malformed_input
        ]
        assert_equal required.sort, one['features'].sort

        one['files'].each do |entry|
          path = File.join(first, entry['name'])
          assert_equal entry['sha256'], Digest::SHA256.file(path).hexdigest
          assert_equal entry['bytes'], File.size(path)
        end

        pdf = File.join(first, 'synthetic-multipage.pdf')
        parser = Parser.new(pdf)
        parser.parse
        assert_equal 3, parser.page_count
        assert_equal 90, parser.page_data(1)[:rotation]
        assert_equal [10.0, 10.0, 290.0, 190.0],
                     parser.page_data(1)[:crop_box].map(&:to_f)
        streams = (1..3).map do |page|
          parser.page_data(page)[:content_streams].join
        end.join
        assert_includes streams, 'BI /W 1 /H 1'
        assert_includes streams, ' re W n'
        parser.release

        malformed = File.join(first, 'synthetic-malformed.pdf')
        refute OpenGate.inspect_path(malformed)[:ok]
      end
    end
  end

  private

  def generate(directory)
    script = File.join(ROOT, 'tools', 'generate_synthetic_public_corpus.py')
    _stdout, stderr, status = Open3.capture3(
      'python', script, '--out', directory
    )
    assert status.success?, stderr
  end
end
