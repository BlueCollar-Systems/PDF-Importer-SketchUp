#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../corpus_paths'

class CorpusPathsTest < Minitest::Test
  def test_baseline_slug_is_stable_across_desktop_mirrors
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'corpus_pdftest_1017_Rev_0_pdf.json',
      corpus.baseline_slug('desktop_root/1017 - Rev 0.pdf')
    )
    assert_equal(
      'corpus_pdftest_1017_Rev_0_pdf.json',
      corpus.baseline_slug('desktop_pdftest/1017 - Rev 0.pdf')
    )
    assert_equal(
      'corpus_new_folder_New_folder_1017_Rev_0_pdf.json',
      corpus.baseline_slug('desktop_new_folder/New folder/1017 - Rev 0.pdf')
    )
  end

  def test_baseline_slug_candidates_include_legacy_new_folder_names
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_includes(
      corpus.baseline_slug_candidates('desktop_root/E5039 - Rev 1.pdf'),
      'corpus_new_folder_E5039_Rev_1_pdf.json'
    )
  end

  def test_canonical_baseline_key_uses_stable_corpus_prefix
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'corpus_pdftest/1017 - Rev 0.pdf',
      corpus.canonical_baseline_key('desktop_root/1017 - Rev 0.pdf')
    )
  end
end
