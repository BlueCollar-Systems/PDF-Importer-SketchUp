#!/usr/bin/env ruby
# Page failures must survive the resumable runner, durable QA report, and UI.
require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_health'

module UI
  class << self
    attr_reader :outcome_message
  end
  def self.messagebox(message)
    @outcome_message = message
  end
end

class FailedPageOutcomeTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl
  QA = BlueCollarSystems::PDFVectorImporter::QAReport
  HEALTH = BlueCollarSystems::PDFVectorImporter::ImportHealth

  class PageController
    attr_reader :resumable_pages, :retained_pages
    def initialize(saved = {})
      @saved = saved
      @resumable_pages = saved.keys.sort
      @retained_pages = @resumable_pages.dup
    end
    def page_stats(page); @saved[page]; end
    def resume_y_offset; 40.0 * @resumable_pages.length; end
    def certify_page!(_group, page, options)
      @resumable_pages << page
      @saved[page] = options[:stats]
    end
    def retain_page!(page)
      @retained_pages << page unless @retained_pages.include?(page)
    end
    def cancelled_result(error)
      {cancelled: true, next_page: error.next_page}
    end
  end

  def page_stats(page)
    {pages: 1, selected_pages: [page], primitives: 1, edges: 1, text: 0,
     layers: [], text_renderers: [], peak_mb: 1,
     text_mode: :geometry, requested_text_mode: :geometry}
  end

  def run_pages(pages, failed = [], cancelled = nil, saved = {})
    controller = PageController.new(saved)
    runner = lambda do |page, _offset, certify|
      if page == cancelled
        raise IRC::ImportCancelled.new(controller.retained_pages, page, {})
      end
      raise "Cannot build page #{page}" if failed.include?(page)
      stats = page_stats(page)
      certify.call(Object.new, page * 40, stats)
      {stats: stats, next_y_offset: page * 40}
    end
    IRC::PageOrchestrator.new(
      controller: controller, pages: pages, runner: runner,
      group_per_page: true, continue_on_page_error: true
    ).run
  end

  def report_for(stats, pages = :all)
    QA.build_from_stats('fixture-two-pages.pdf',
      {pages: pages, import_mode: 'auto', text_mode: :geometry}, stats)
  end

  def show_health(stats, report)
    extra = report[:extra]
    HEALTH.record!(stats.merge(
      human_summary: extra[:human_summary],
      representation_fidelity: extra[:representation_fidelity],
      import_contract_ready: extra[:import_contract_ready]
    ), 'fixture-two-pages.pdf')
    HEALTH.show
    UI.outcome_message
  end

  def test_all_pages_tail_failure_is_persisted_and_never_ready
    result = run_pages([1, 2], [2])
    stats = result[:stats]
    assert_equal [1, 2], stats[:requested_pages]
    assert_equal [1, 2], stats[:selected_pages]
    assert_equal [1], stats[:retained_pages]
    report = report_for(stats)
    persisted = JSON.parse(JSON.generate(report))
    assert_equal 'incomplete', persisted['result_status']
    assert_equal [1, 2], persisted['extra']['requested_pages']
    assert_equal [1], persisted['extra']['retained_pages']
    failure = persisted['extra']['failed_pages'].first
    assert_equal 2, failure['page']
    assert_equal 'Cannot build page 2', failure['message']
    assert_equal false, persisted['extra']['representation_fidelity']['ready']
    assert_equal false,
      persisted['extra']['representation_fidelity']['checks']['requested_pages_retained']
    assert_equal false, persisted['extra']['import_contract_ready']['ready']
    assert_includes persisted['extra']['page_outcomes']['errors'], 'failed_pages:2'
    text = show_health(stats, report)
    assert_includes text, 'QA contract: NOT READY'
    assert_includes text, 'Failed pages: 2'
    assert_includes text, 'Cannot build page 2'
    assert_includes text, 'Pages not retained: 2'
  end

  def test_cancel_after_failure_preserves_both_failure_and_cancelled_status
    stats = run_pages([1, 2, 3], [1], 3)[:stats]
    report = report_for(stats)
    assert_equal 'cancelled', report[:result_status]
    assert_equal [1, 2, 3], report[:extra][:requested_pages]
    assert_equal [2], report[:extra][:retained_pages]
    assert_equal [1, 3], report[:extra][:missing_pages]
    assert_equal false, report[:extra][:import_contract_ready][:ready]
    assert_includes report[:extra][:representation_fidelity][:errors], 'failed_pages:1'
    assert_includes report[:extra][:human_summary], 'Import cancelled'
    text = show_health(stats, report)
    assert_includes text, 'Result: cancelled'
    assert_includes text, 'Failed pages: 1'
    assert_includes text, 'QA contract: NOT READY'
  end

  def test_successful_resume_restores_complete_coverage_and_ready
    first = run_pages([1, 2], [2])
    assert_equal false, report_for(first[:stats])[:extra][:import_contract_ready][:ready]
    resumed = run_pages([1, 2], [], nil, {1 => page_stats(1)})
    report = report_for(resumed[:stats])
    assert_equal [1], resumed[:resumed_pages]
    assert_equal [2], resumed[:new_pages]
    assert_equal 'success', report[:result_status]
    assert_equal [1, 2], report[:extra][:retained_pages]
    assert_empty report[:extra][:failed_pages]
    assert_empty report[:extra][:page_outcomes][:errors]
    assert_equal true, report[:extra][:representation_fidelity][:ready]
    assert_equal true, report[:extra][:import_contract_ready][:ready]
    assert_includes show_health(resumed[:stats], report), 'QA contract: READY'
  end

  def test_missing_retained_page_overrides_a_declared_success
    stats = page_stats(1).merge(
      selected_pages: [1, 2], requested_pages: [1, 2],
      retained_pages: [1], failed_pages: [], result_status: 'success')
    report = report_for(stats)
    assert_equal 'incomplete', report[:result_status]
    assert_includes report[:extra][:page_outcomes][:errors], 'unretained_requested_pages:2'
    assert_equal false, report[:extra][:representation_fidelity][:ready]
    assert_equal false, report[:extra][:import_contract_ready][:ready]
    assert_includes show_health(stats, report), 'QA contract: NOT READY'
  end

  def test_all_cannot_recover_original_request_from_successful_count
    stats = page_stats(1).merge(retained_pages: [1],
      failed_pages: [{page: 2, error_class: 'RuntimeError', message: 'failed'}])
    report = report_for(stats)
    assert_equal 'incomplete', report[:result_status]
    assert_includes report[:extra][:page_outcomes][:errors], 'requested_page_set_missing'
    assert_equal false, report[:extra][:import_contract_ready][:ready]
  end

  def test_string_keyed_outcome_ledger_has_same_failure_semantics
    stats = page_stats(1).merge(
      'requested_pages' => [1, 2], 'retained_pages' => [1],
      'failed_pages' => [{'page' => 2, 'message' => 'string-keyed failure'}],
      'result_status' => 'incomplete')
    report = report_for(stats)
    assert_equal 'incomplete', report[:result_status]
    assert_equal [1, 2], report[:extra][:requested_pages]
    assert_equal [1], report[:extra][:retained_pages]
    assert_equal 1, report[:result][:warnings]
    assert_equal false, report[:extra][:import_contract_ready][:ready]
    assert_includes show_health(stats, report), 'Failed pages: 2'
  end

  def test_contract_recomputation_cannot_ignore_failed_page_ledger
    report = report_for(page_stats(1), [1])
    assert_equal true, report[:extra][:import_contract_ready][:ready]
    report[:extra].merge!(
      requested_pages: [1, 2], retained_pages: [1],
      failed_pages: [{page: 2, message: 'failed'}], result_status: 'success')
    contract = QA.build_import_contract_ready(report)
    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:requested_pages_retained]
    assert_includes contract[:errors], 'failed_pages:2'
  end

  def test_legacy_stats_without_outcome_ledger_retain_existing_contract
    report = report_for(page_stats(1), [1])
    refute report.key?(:result_status)
    refute report[:extra].key?(:page_outcomes)
    assert_equal true, report[:extra][:representation_fidelity][:ready]
    assert_equal true, report[:extra][:import_contract_ready][:ready]
  end
end
