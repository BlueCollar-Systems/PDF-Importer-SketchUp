#!/usr/bin/env ruby

require_relative 'representation_fidelity_contract_test'

class ImportOperationLifecycleTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  class Model
    attr_reader :starts, :commits, :aborts

    def initialize(options = {})
      @options = options
      @starts = 0
      @commits = 0
      @aborts = 0
    end

    def start_operation(_name, _transparent)
      @starts += 1
      raise @options[:start_error] if @options[:start_error]
      @options.fetch(:start_result, true)
    end

    def commit_operation
      @commits += 1
      raise @options[:commit_error] if @options[:commit_error]
      true
    end

    def abort_operation
      @aborts += 1
      raise @options[:abort_error] if @options[:abort_error]
      true
    end
  end

  def operation(model)
    unless IMP.const_defined?(:ImportOperation)
      flunk 'ImportOperation owner is missing'
    end
    IMP::ImportOperation.new(model, 'Import PDF Test')
  end

  def test_commit_is_impossible_before_readiness_and_happens_once_afterward
    model = Model.new
    subject = operation(model)
    subject.start!

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      subject.commit!
    end
    assert_equal 0, model.commits

    subject.mark_ready!(:diagnostics => true, :persistence => true)
    assert_equal true, subject.commit!
    assert_equal false, subject.commit!
    assert_equal 1, model.starts
    assert_equal 1, model.commits
    assert_equal 0, model.aborts
    assert subject.committed?
  end

  def test_failure_or_cancel_aborts_exactly_once_and_never_commits
    model = Model.new
    subject = operation(model)
    subject.start!

    assert_equal true, subject.abort!
    assert_equal false, subject.abort!
    assert_equal 1, model.aborts
    assert_equal 0, model.commits
    assert subject.aborted?
  end

  def test_false_or_raising_start_never_opens_or_aborts_an_operation
    [
      Model.new(:start_result => false),
      Model.new(:start_error => IOError.new('start refused'))
    ].each do |model|
      subject = operation(model)
      assert_raises(IMP::RepresentationFidelity::ContractError) do
        subject.start!
      end
      assert_equal false, subject.abort!
      assert_equal 1, model.starts
      assert_equal 0, model.commits
      assert_equal 0, model.aborts
    end
  end

  def test_commit_exception_aborts_once_and_cannot_be_retried
    model = Model.new(:commit_error => IOError.new('commit refused'))
    subject = operation(model)
    subject.start!
    subject.mark_ready!(:diagnostics => true, :persistence => true)

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      subject.commit!
    end
    assert_match(/commit refused/, error.message)
    assert_equal 1, model.commits
    assert_equal 1, model.aborts
    assert_equal false, subject.abort!
  end

  def test_abort_exception_is_recorded_and_never_retried
    model = Model.new(:abort_error => IOError.new('abort refused'))
    subject = operation(model)
    subject.start!

    assert_equal false, subject.abort!
    assert_instance_of IOError, subject.abort_error
    assert_match(/abort refused/, subject.abort_error.message)
    assert_equal false, subject.abort!
    assert_equal 1, model.aborts
  end

  def test_readiness_requires_exact_true_diagnostics_and_persistence
    model = Model.new
    subject = operation(model)
    subject.start!

    [
      { :diagnostics => 'true', :persistence => true },
      { :diagnostics => true, :persistence => 1 },
      { :diagnostics => true, :persistence => false }
    ].each do |evidence|
      assert_raises(IMP::RepresentationFidelity::ContractError) do
        subject.mark_ready!(evidence)
      end
    end
    assert_equal 0, model.commits
    subject.abort!
  end

  def test_report_write_failure_is_authoritative_before_commit
    stats = { :source_provenance_objects => [] }
    ready_report = {
      :extra => {
        :representation_fidelity => { :ready => true },
        :import_contract_ready => { :ready => true }
      }
    }

    IMP::QAReport.stub(:build_from_stats, ready_report) do
      IMP::QAReport.stub(:write_json, nil) do
        assert_raises(IMP::RepresentationFidelity::ContractError) do
          IMP.finalize_import_diagnostics!('readonly.pdf', {}, stats)
        end
      end
    end
  end

  def test_report_path_must_exist_and_round_trip_as_ready_json
    stats = { :source_provenance_objects => [] }
    ready_report = {
      :extra => {
        :representation_fidelity => { :ready => true },
        :import_contract_ready => { :ready => true }
      }
    }
    ghost = File.join(Dir.tmpdir, "missing_import_report_#{Process.pid}.json")
    File.delete(ghost) if File.exist?(ghost)

    IMP::QAReport.stub(:build_from_stats, ready_report) do
      IMP::QAReport.stub(:write_json, ghost) do
        assert_raises(IMP::RepresentationFidelity::ContractError) do
          IMP.finalize_import_diagnostics!('readonly.pdf', {}, stats)
        end
      end
    end
  end

  def test_failure_after_owned_provenance_and_parts_removes_both_artifacts
    directory = Dir.mktmpdir('bc_atomic_diagnostics_')
    stats = {
      :import_session_id => 'atomic-session',
      :pages => 1,
      :source_provenance_objects => [
        { :object_id => 'text_span:1:0', :resulting_entity_ids => ['entity_id:1'] }
      ]
    }
    report = {
      :extra => {
        :parts_bootstrap => { :row_count => 1 },
        :representation_fidelity => { :ready => true },
        :import_contract_ready => { :ready => true }
      }
    }
    parts_path = nil
    parts_writer = lambda do |_payload, sidecar_base|
      parts_path = "#{sidecar_base}_parts_bootstrap.json"
      File.write(parts_path, "{}\n")
      parts_path
    end

    IMP::QAReport.stub(:build_from_stats, report) do
      IMP::QAReport.stub(:write_json, nil) do
        IMP::PartsBootstrap.stub(:write_sidecar, parts_writer) do
          assert_raises(IMP::RepresentationFidelity::ContractError) do
            IMP.finalize_import_diagnostics!(
              'readonly.pdf', { :qa_output_dir => directory }, stats
            )
          end
        end
      end
    end

    refute File.exist?(parts_path), 'failed attempt must remove its parts sidecar'
    provenance = Dir[File.join(directory, '*source_provenance.json')]
    assert_empty provenance, 'failed attempt must remove its provenance sidecar'
  ensure
    FileUtils.remove_entry(directory) if directory && File.directory?(directory)
  end

  def test_failed_diagnostics_preserve_preexisting_success_artifacts_exactly
    directory = Dir.mktmpdir('bc_prior_diagnostics_')
    prior_report = File.join(directory, 'readonly_import_report.json')
    prior_parts = File.join(directory, 'readonly_parts.json')
    File.binwrite(prior_report, "PRIOR REPORT\r\n")
    File.binwrite(prior_parts, "PRIOR PARTS\r\n")
    stats = { :import_session_id => 'new-session',
              :source_provenance_objects => [] }
    report = {
      :extra => {
        :representation_fidelity => { :ready => true },
        :import_contract_ready => { :ready => true }
      }
    }

    IMP::QAReport.stub(:build_from_stats, report) do
      IMP::QAReport.stub(:write_json, nil) do
        assert_raises(IMP::RepresentationFidelity::ContractError) do
          IMP.finalize_import_diagnostics!(
            'readonly.pdf', { :qa_output_dir => directory }, stats
          )
        end
      end
    end

    assert_equal "PRIOR REPORT\r\n", File.binread(prior_report)
    assert_equal "PRIOR PARTS\r\n", File.binread(prior_parts)
  ensure
    FileUtils.remove_entry(directory) if directory && File.directory?(directory)
  end

  def test_vector_raster_and_file_importer_use_only_the_single_owner
    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
      :encoding => 'UTF-8'
    )
    refute_match(/model\.start_operation\(['"]Import PDF (?:Raster|Vectors)/, main)
    refute_match(/model\.commit_operation\s*\n/, main)
    assert_operator main.scan(/ImportOperation\.new\(/).length, :>=, 2
    importer = main[/class PDFFileImporter.*?end # if defined\?\(Sketchup::Importer\)/m]
    refute_nil importer
    refute_match(/safe_abort_operation/, importer)
    assert_match(/import_operation_committed.*import_contract_ready/m, importer)
  end

  def test_provenance_target_is_writable_qa_output_not_pdf_directory
    unless IMP.respond_to?(:source_provenance_output_path)
      flunk 'writable source provenance output routing is missing'
    end
    target = IMP.source_provenance_output_path(
      'C:/read-only/source.pdf', {}, 'session-1'
    )

    refute_equal 'C:/read-only/source_source_provenance.json',
                 target.tr('\\', '/')
    assert_equal File.dirname(IMP::QAReport.default_output_path('source.pdf')),
                 File.dirname(target)
  end
end
