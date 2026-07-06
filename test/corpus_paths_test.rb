#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../corpus_paths'

class CorpusPathsTest < Minitest::Test
  def test_baseline_slug_for_manifest_user_tier_pdf
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'corpus_tier1_user_T1_01_pdf.json',
      corpus.baseline_slug('corpus_tier1_user/T1-01.pdf')
    )
    assert_equal(
      'corpus_tier1_user_T1_02_pdf.json',
      corpus.baseline_slug('corpus_tier1_user/T1-02.pdf')
    )
  end

  def test_baseline_slug_candidates_are_stable_for_manifest_keys
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_includes(
      corpus.baseline_slug_candidates('corpus_tier1_user/T1-03.pdf'),
      'corpus_tier1_user_T1_03_pdf.json'
    )
  end

  def test_canonical_baseline_key_preserves_corpus_prefix
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'corpus_tier1_user/T1-01.pdf',
      corpus.canonical_baseline_key('corpus_tier1_user/T1-01.pdf')
    )
    assert_equal(
      'corpus_root/T1-10.pdf',
      corpus.canonical_baseline_key('env_corpus/T1-10.pdf')
    )
  end
end
