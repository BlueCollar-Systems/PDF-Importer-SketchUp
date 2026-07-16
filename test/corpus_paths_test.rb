#!/usr/bin/env ruby

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../corpus_paths'

class CorpusPathsTest < Minitest::Test
  def with_corpus_env(private_root, public_root)
    old_private = ENV['BCS_PRIVATE_VALIDATION_ROOT']
    old_public = ENV['BCS_CORPUS_ROOT']
    ENV['BCS_PRIVATE_VALIDATION_ROOT'] = private_root
    ENV['BCS_CORPUS_ROOT'] = public_root
    yield
  ensure
    ENV['BCS_PRIVATE_VALIDATION_ROOT'] = old_private
    ENV['BCS_CORPUS_ROOT'] = old_public
  end

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

  def test_public_and_private_roots_coexist_without_widening_private_scan
    Dir.mktmpdir('corpus_paths_') do |tmp|
      private_root = File.join(tmp, 'private-assets')
      public_root = File.join(tmp, 'public-corpus')
      private_pdf = File.join(private_root, 'private', 'user', 'PRIVATE-01.pdf')
      public_pdf = File.join(public_root, 'tier1', 'web', 'public.pdf')
      FileUtils.mkdir_p(File.dirname(private_pdf))
      FileUtils.mkdir_p(File.dirname(public_pdf))
      File.open(private_pdf, 'wb') { |io| io.write('%PDF-private') }
      File.open(public_pdf, 'wb') { |io| io.write('%PDF-public') }

      with_corpus_env(private_root, public_root) do
        corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths
        assert_equal File.expand_path(private_root), corpus.resolve_private_validation_root
        assert_equal File.expand_path(public_root), corpus.resolve_public_corpus_root
        assert_equal File.expand_path(public_pdf),
                     corpus.resolve_public_corpus_path('tier1/web/public.pdf')
        assert_equal [File.expand_path(private_root)], corpus.corpus_scan_roots
        paths = corpus.collect_corpus_pdfs.map { |info| info[:path] }
        assert_includes paths, File.expand_path(private_pdf)
        refute_includes paths, File.expand_path(public_pdf)
      end
    end
  end
end
