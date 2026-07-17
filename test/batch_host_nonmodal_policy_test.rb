#!/usr/bin/env ruby
require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__) unless defined?(ROOT)

class BatchHostNonmodalPolicyTest < Minitest::Test
  def setup
    load File.join(
      ROOT,
      'extracted', 'sketchup_ext', 'bc_pdf_vector_importer',
      'batch_host_policy.rb'
    )
    @prior = ENV['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE']
  end

  def teardown
    ENV['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE'] = @prior
  end

  def test_noninteractive_large_pdf_fails_without_invoking_prompt
    ENV['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE'] = '1'
    prompted = false
    error = assert_raises(StandardError) do
      BlueCollarSystems::PDFVectorImporter::BatchHostPolicy.
        confirm_large_pdf!(101 * 1024 * 1024) do
          prompted = true
          true
        end
    end
    assert_match(/large PDF/, error.message)
    refute prompted
  end

  def test_interactive_large_pdf_delegates_to_prompt
    ENV.delete('BC_PDF_IMPORTER_BATCH_NONINTERACTIVE')
    assert_equal :decision,
                 BlueCollarSystems::PDFVectorImporter::BatchHostPolicy.
                   confirm_large_pdf!(101 * 1024 * 1024) { :decision }
  end

  def test_noninteractive_notice_and_salvage_paths_fail_closed_without_prompt
    ENV['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE'] = '1'
    prompted = false
    assert_equal false,
                 BlueCollarSystems::PDFVectorImporter::BatchHostPolicy.
                   prompt_allowed?
    error = assert_raises(StandardError) do
      BlueCollarSystems::PDFVectorImporter::BatchHostPolicy.
        handle_salvage_error!(RuntimeError.new('damaged xref')) do
          prompted = true
        end
    end
    assert_match(/damaged xref/, error.message)
    refute prompted
  end

  def test_every_reachable_batch_prompt_is_routed_through_policy
    main = File.read(File.join(
      ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer', 'main.rb'
    ), :encoding => 'UTF-8')
    dependency = File.read(File.join(
      ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer',
      'dependency_resolver.rb'
    ), :encoding => 'UTF-8')

    assert_includes main, 'BatchHostPolicy.prompt_allowed?'
    assert_includes main, 'BatchHostPolicy.confirm_large_pdf!'
    assert_includes main, 'BatchHostPolicy.handle_salvage_error!'
    assert_includes dependency, 'BatchHostPolicy.noninteractive?'
  end
end
