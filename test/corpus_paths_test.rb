#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../corpus_paths'

class CorpusPathsTest < Minitest::Test
  def test_baseline_slug_for_manifest_user_tier_pdf
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'private_validation_user_PRIVATE_01_pdf.json',
      corpus.baseline_slug('private_validation_user/PRIVATE-01.pdf')
    )
    assert_equal(
      'private_validation_user_PRIVATE_02_pdf.json',
      corpus.baseline_slug('private_validation_user/PRIVATE-02.pdf')
    )
  end

  def test_baseline_slug_candidates_are_stable_for_manifest_keys
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_includes(
      corpus.baseline_slug_candidates('private_validation_user/PRIVATE-03.pdf'),
      'private_validation_user_PRIVATE_03_pdf.json'
    )
  end

  def test_canonical_baseline_key_preserves_corpus_prefix
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'private_validation_user/PRIVATE-01.pdf',
      corpus.canonical_baseline_key('private_validation_user/PRIVATE-01.pdf')
    )
    assert_equal(
      'private_validation_root/PRIVATE-10.pdf',
      corpus.canonical_baseline_key('env_private_validation/PRIVATE-10.pdf')
    )
  end
end
