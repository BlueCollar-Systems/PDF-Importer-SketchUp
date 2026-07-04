#!/usr/bin/env ruby

require 'minitest/autorun'
require 'json'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/source_provenance'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false
SP = BlueCollarSystems::PDFVectorImporter::SourceProvenance

class SourceProvenanceTest < Minitest::Test
  def test_write_sidecar_schema
    Dir.mktmpdir('su_prov_') do |dir|
      pdf = File.join(dir, 'sample.pdf')
      File.write(pdf, 'sample')
      out = File.join(dir, 'sample_source_provenance.json')
      objects = [
        {
          object_id: 'text_span:1:0',
          page: 1,
          source_kind: 'text_span',
          created_entity_type: 'native_label'
        }
      ]
      path = SP.write_sidecar(
        output_path: out,
        import_session_id: 'test-session',
        pdf_path: pdf,
        objects: objects,
        version: '3.7.79',
        page_count: 1
      )
      assert_equal out, path
      data = JSON.parse(File.read(out))
      assert_equal 'bcs.source_provenance/1.0', data['schema']
      assert_equal 1, data['objects'].length
    end
  end
end
