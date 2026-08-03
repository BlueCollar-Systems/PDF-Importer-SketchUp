#!/usr/bin/env ruby

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../corpus_paths'

class CorpusPathsTest < Minitest::Test
  def with_environment(values)
    previous = {}
    values.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def write_acceptance_manifest(root, entries)
    File.write(
      File.join(root, 'manifest.json'),
      JSON.generate('entries' => entries)
    )
  end

  def write_pdf(root, relative_path)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'wb') { |file| file.write("%PDF-1.4\n%%EOF\n") }
    path
  end

  def test_resolve_acceptance_pdf_uses_semantic_manifest_key
    Dir.mktmpdir('acceptance-key') do |root|
      pdf = write_pdf(root, File.join('references', 'drawing.pdf'))
      write_acceptance_manifest(
        root,
        [
          {
            'id' => 'external-only-id',
            'acceptance_key' => 'shop-bom-tier1',
            'local_path' => 'references/drawing.pdf'
          }
        ]
      )

      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        actual = BlueCollarSystems::PDFVectorImporter::CorpusPaths
                 .resolve_acceptance_pdf('shop-bom-tier1')
        assert_equal File.expand_path(pdf), actual
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_a_missing_configured_root
    missing = File.join(Dir.tmpdir, 'missing-private-validation-root')
    with_environment(
      'BCS_PRIVATE_VALIDATION_ROOT' => missing,
      'PDF_PRIVATE_VALIDATION_ROOT' => nil
    ) do
      error = assert_raises(
        BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
      ) do
        BlueCollarSystems::PDFVectorImporter::CorpusPaths
          .resolve_acceptance_pdf('shop-bom-tier1')
      end
      assert_match(/configured private validation root does not exist/i, error.message)
    end
  end

  def test_resolve_acceptance_pdf_rejects_a_configured_root_without_manifest
    Dir.mktmpdir('acceptance-no-manifest') do |root|
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/manifest\.json is missing/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_malformed_manifest_json
    Dir.mktmpdir('acceptance-malformed-manifest') do |root|
      File.write(File.join(root, 'manifest.json'), '{not-json')
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/manifest\.json is malformed/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_a_malformed_manifest_shape
    Dir.mktmpdir('acceptance-malformed-shape') do |root|
      File.write(File.join(root, 'manifest.json'), JSON.generate([]))
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/manifest\.json entries must be an array/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_non_object_manifest_entries
    Dir.mktmpdir('acceptance-malformed-entry') do |root|
      write_acceptance_manifest(root, [nil])
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/manifest\.json entries must contain objects/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_a_missing_acceptance_key
    Dir.mktmpdir('acceptance-missing-key') do |root|
      write_acceptance_manifest(root, [])
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/acceptance_key.*shop-bom-tier1.*not found/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_duplicate_acceptance_keys
    Dir.mktmpdir('acceptance-duplicate-key') do |root|
      write_acceptance_manifest(
        root,
        [
          { 'acceptance_key' => 'shop-bom-tier1', 'local_path' => 'one.pdf' },
          { 'acceptance_key' => 'shop-bom-tier1', 'local_path' => 'two.pdf' }
        ]
      )
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/acceptance_key.*shop-bom-tier1.*ambiguous/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_an_unresolved_local_path
    Dir.mktmpdir('acceptance-missing-pdf') do |root|
      write_acceptance_manifest(
        root,
        [
          {
            'acceptance_key' => 'shop-bom-tier1',
            'local_path' => 'references/missing.pdf'
          }
        ]
      )
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf('shop-bom-tier1')
        end
        assert_match(/does not resolve to a readable PDF/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_accepts_an_explicit_pdf_override
    Dir.mktmpdir('acceptance-override') do |root|
      pdf = write_pdf(root, 'override.pdf')
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => nil,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil,
        'BCS_TEST_ACCEPTANCE_PDF' => pdf
      ) do
        actual = BlueCollarSystems::PDFVectorImporter::CorpusPaths
                 .resolve_acceptance_pdf(
                   'shop-bom-tier1', 'BCS_TEST_ACCEPTANCE_PDF'
                 )
        assert_equal File.expand_path(pdf), actual
      end
    end
  end

  def test_explicit_override_does_not_mask_a_malformed_configured_root
    Dir.mktmpdir('acceptance-override-with-root') do |root|
      pdf = write_pdf(root, 'override.pdf')
      with_environment(
        'BCS_PRIVATE_VALIDATION_ROOT' => root,
        'PDF_PRIVATE_VALIDATION_ROOT' => nil,
        'BCS_TEST_ACCEPTANCE_PDF' => pdf
      ) do
        error = assert_raises(
          BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
        ) do
          BlueCollarSystems::PDFVectorImporter::CorpusPaths
            .resolve_acceptance_pdf(
              'shop-bom-tier1', 'BCS_TEST_ACCEPTANCE_PDF'
            )
        end
        assert_match(/manifest\.json is missing/i, error.message)
      end
    end
  end

  def test_resolve_acceptance_pdf_rejects_ambiguous_configured_roots
    Dir.mktmpdir('acceptance-root-one') do |root_one|
      Dir.mktmpdir('acceptance-root-two') do |root_two|
        with_environment(
          'BCS_PRIVATE_VALIDATION_ROOT' => root_one,
          'PDF_PRIVATE_VALIDATION_ROOT' => root_two
        ) do
          error = assert_raises(
            BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
          ) do
            BlueCollarSystems::PDFVectorImporter::CorpusPaths
              .resolve_acceptance_pdf('shop-bom-tier1')
          end
          assert_match(/private validation roots are ambiguous/i, error.message)
        end
      end
    end
  end

  def test_resolve_acceptance_pdf_returns_nil_only_when_nothing_is_configured
    with_environment(
      'BCS_PRIVATE_VALIDATION_ROOT' => nil,
      'PDF_PRIVATE_VALIDATION_ROOT' => nil,
      'BCS_TEST_ACCEPTANCE_PDF' => nil
    ) do
      actual = BlueCollarSystems::PDFVectorImporter::CorpusPaths
               .resolve_acceptance_pdf(
                 'shop-bom-tier1', 'BCS_TEST_ACCEPTANCE_PDF'
               )
      assert_nil actual
    end
  end

  def test_resolve_acceptance_pdf_rejects_a_missing_explicit_override
    missing = File.join(Dir.tmpdir, 'missing-acceptance-override.pdf')
    with_environment(
      'BCS_PRIVATE_VALIDATION_ROOT' => nil,
      'PDF_PRIVATE_VALIDATION_ROOT' => nil,
      'BCS_TEST_ACCEPTANCE_PDF' => missing
    ) do
      error = assert_raises(
        BlueCollarSystems::PDFVectorImporter::CorpusPaths::AcceptanceInputError
      ) do
        BlueCollarSystems::PDFVectorImporter::CorpusPaths
          .resolve_acceptance_pdf(
            'shop-bom-tier1', 'BCS_TEST_ACCEPTANCE_PDF'
          )
      end
      assert_match(/BCS_TEST_ACCEPTANCE_PDF.*readable PDF/i, error.message)
    end
  end

  def test_baseline_slug_for_synthetic_manifest_pdf
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'synthetic_validation_set_alpha_sheet_a_pdf.json',
      corpus.baseline_slug('synthetic_validation_set/alpha-sheet-a.pdf')
    )
    assert_equal(
      'synthetic_validation_set_beta_sheet_b_pdf.json',
      corpus.baseline_slug('synthetic_validation_set/beta-sheet-b.pdf')
    )
  end

  def test_baseline_slug_candidates_are_stable_for_manifest_keys
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_includes(
      corpus.baseline_slug_candidates('synthetic_validation_set/gamma-sheet-c.pdf'),
      'synthetic_validation_set_gamma_sheet_c_pdf.json'
    )
  end

  def test_canonical_baseline_key_preserves_corpus_prefix
    corpus = BlueCollarSystems::PDFVectorImporter::CorpusPaths

    assert_equal(
      'synthetic_validation_set/alpha-sheet-a.pdf',
      corpus.canonical_baseline_key('synthetic_validation_set/alpha-sheet-a.pdf')
    )
    assert_equal(
      'private_validation_root/delta-sheet-d.pdf',
      corpus.canonical_baseline_key('env_private_validation/delta-sheet-d.pdf')
    )
  end
end
