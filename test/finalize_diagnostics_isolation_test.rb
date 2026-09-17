#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

# Exercise the real finalization seam and all three file writers without a CAD
# host or PDF rendering. Only report calculation is replaced by fictional data.
class FinalizeDiagnosticsIsolationTest < Minitest::Test
  IMPORTER = BlueCollarSystems::PDFVectorImporter
  QA = IMPORTER::QAReport
  TEMP = IMPORTER::SafeTemp
  PATH_KEYS = [
    :import_report_path, :parts_bootstrap_sidecar_path,
    :source_provenance_sidecar_path
  ].freeze

  def test_refinalization_reuses_files_and_another_import_cannot_replace_them
    Dir.mktmpdir('bc_finalize_isolation_') do |root|
      source_dir = File.join(root, 'source')
      Dir.mkdir(source_dir)
      pdf = File.join(source_dir, 'fictional-drawing.pdf')
      File.write(pdf, '%PDF-fictional diagnostic fixture; no rendering required')
      first_stats = import_stats('run-A', 1)
      second_stats = import_stats('run-B', 9)
      opts = { :text_mode => :text3d }
      report_builder = lambda do |source, _options, stats|
        assert_equal pdf, source
        report_fixture(stats)
      end

      TEMP.stub(:root, root) do
        QA.stub(:build_from_stats, report_builder) do
          assert_equal({ :ready => true }, IMPORTER.finalize_import_diagnostics!(pdf, opts, first_stats))
          first_paths = artifact_paths(first_stats)
          assert_artifacts(first_stats, pdf, 'run-A', 1)
          assert_equal 1, first_paths.map { |path| File.dirname(path) }.uniq.length
          refute_equal source_dir, File.dirname(first_paths.first)
          first_file_tree = Dir.glob(File.join(root, '**', '*')).sort

          # Refresh the existing import with changed diagnostic contents. This
          # must update its files in place, not allocate a second report folder.
          first_stats[:diagnostic_revision] = 2
          first_stats[:source_provenance_objects] = [{ :object_id => 'run-A-entity-2' }]
          assert_equal({ :ready => true }, IMPORTER.finalize_import_diagnostics!(pdf, opts, first_stats))
          assert_equal first_paths, artifact_paths(first_stats)
          assert_equal first_file_tree, Dir.glob(File.join(root, '**', '*')).sort
          assert_artifacts(first_stats, pdf, 'run-A', 2)
          retained_bytes = first_paths.map { |path| File.binread(path) }

          # A distinct run of the same source must own a separate set of files.
          assert_equal({ :ready => true }, IMPORTER.finalize_import_diagnostics!(pdf, opts, second_stats))
          second_paths = artifact_paths(second_stats)
          assert_equal 1, second_paths.map { |path| File.dirname(path) }.uniq.length
          refute_equal File.dirname(first_paths.first), File.dirname(second_paths.first)
          assert_empty(first_paths & second_paths)
          assert_equal retained_bytes, first_paths.map { |path| File.binread(path) }
          assert_artifacts(second_stats, pdf, 'run-B', 9)
          assert_equal ['fictional-drawing.pdf'], (Dir.entries(source_dir) - ['.', '..']).sort
        end
      end
    end
  end

  private

  def import_stats(session, revision)
    {
      :import_session_id => session,
      :pages => 1,
      :diagnostic_revision => revision,
      :source_provenance_objects => [{ :object_id => "#{session}-entity-#{revision}" }]
    }
  end

  def report_fixture(stats)
    {
      :schema => QA::SCHEMA,
      :import_session_id => stats.fetch(:import_session_id),
      :extra => {
        :import_contract_ready => { :ready => true },
        :representation_fidelity => { :ready => true },
        :parts_bootstrap => {
          :schema => IMPORTER::PartsBootstrap::SCHEMA,
          :import_session_id => stats.fetch(:import_session_id),
          :row_count => 1,
          :tables => [{ :page => 1, :rows => [{
            :piece_mark => 'T101',
            :quantity => stats.fetch(:diagnostic_revision),
            :description => 'Fictional test plate',
            :span_ids => ['text_span:1:1']
          }] }]
        }
      }
    }
  end

  def artifact_paths(stats)
    PATH_KEYS.map do |key|
      path = stats.fetch(key)
      assert File.file?(path), "missing finalized #{key}: #{path.inspect}"
      path
    end
  end

  def assert_artifacts(stats, pdf, session, revision)
    report_path, parts_path, provenance_path = artifact_paths(stats)
    report = JSON.parse(File.read(report_path))
    parts = JSON.parse(File.read(parts_path))
    provenance = JSON.parse(File.read(provenance_path))
    assert_equal session, report.fetch('import_session_id')
    assert_equal parts_path, report.fetch('extra').fetch('parts_bootstrap').fetch('sidecar_path')
    assert_equal session, parts.fetch('import_session_id')
    assert_equal revision, parts.fetch('tables').first.fetch('rows').first.fetch('quantity')
    assert_equal session, provenance.fetch('import_session_id')
    assert_equal "#{session}-entity-#{revision}", provenance.fetch('objects').first.fetch('object_id')
    assert_equal pdf, provenance.fetch('source_pdf').fetch('path')
    assert_equal Digest::SHA256.file(pdf).hexdigest, provenance.fetch('source_pdf').fetch('sha256')
    assert_equal report_path, IMPORTER::ImportHealth.snapshot.fetch(:import_report_path)
  end
end
