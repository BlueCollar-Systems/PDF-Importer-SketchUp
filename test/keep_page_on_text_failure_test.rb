#!/usr/bin/env ruby
# test/keep_page_on_text_failure_test.rb
#
# Owner ruling (2026-10-05): deliver, step down, report. A text problem never
# costs the page: when the free text helper cannot run, or one text stage
# fails, the page's lines, fills and pictures are kept, whatever the failed
# stage built is erased, and every text item it was delivering is listed as
# not delivered (report, Import Health, status line). A geometry-builder
# failure still rolls its page back (test/unattended_multipage_import_test.rb
# test_confirmed_rollback_removes_partial_page_and_keeps_committed_pages).
#
# Fictional data only.

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'
require_relative 'support/synthetic_pdf_builder'

unless defined?(UI) && UI.respond_to?(:messagebox)
  module UI
    def self.messagebox(*_args); 0; end
  end
end
MB_OKCANCEL = 1 unless defined?(MB_OKCANCEL)
IDOK = 1 unless defined?(IDOK)

class KeepPageOnTextFailureTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  IRC = IMP::ImportRunControl
  CE = IMP::RepresentationFidelity::ContractError
  MAIN_RB = File.expand_path(
    '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
  )

  # ---- host fakes -------------------------------------------------------

  class AttrObject
    def initialize; @attributes = {}; end
    def set_attribute(dict, key, value); @attributes[[dict, key]] = value; end
    def get_attribute(dict, key, default = nil)
      @attributes.fetch([dict, key], default)
    end
  end

  class Edge < AttrObject
    Point = Struct.new(:x, :y, :z)
    Vertex = Struct.new(:position)
    attr_reader :persistent_id
    def initialize(id)
      super()
      @persistent_id = id
      @start = Vertex.new(Point.new(0.0, 0.0, 0.0))
      @end = Vertex.new(Point.new(1.0, 0.0, 0.0))
    end
    def valid?; true; end
    def typename; 'Edge'; end
    def start; @start; end
    def end; @end; end
  end

  class Entities
    attr_reader :erased
    def initialize(items = []); @items = items; @erased = []; end
    def to_a; @items.dup; end
    def length; @items.length; end
    def add(item); @items << item; item; end
    def erase_entities(*doomed)
      doomed.flatten.each { |item| @erased << item if @items.delete(item) }
    end
  end

  class Group < AttrObject
    attr_accessor :name
    attr_reader :persistent_id, :entities
    def initialize(id, name = nil, items = [])
      super()
      @persistent_id = id
      @name = name
      @entities = Entities.new(items)
    end
    def valid?; true; end
    def typename; 'Group'; end
  end

  class Model < AttrObject
    attr_reader :active_entities
    def initialize; super; @active_entities = Entities.new; end
  end

  def text_item(page, index, text = 'EX101')
    IMP::TextParser::TextItem.new(
      text, 10 + index, 20, 12, 0, 'F1', 12,
      9 + index, 19, 20 + index, 30, nil, "text_span:#{page}:#{index}"
    )
  end

  def text_group(id, source_id)
    group = Group.new(id, "PDF 3D Text #{source_id}", [Edge.new(id * 10)])
    group.set_attribute('BC_PDF_Importer', 'source_span_id', source_id)
    group
  end

  def page_with_lines(edge_count = 3)
    Group.new(900, 'PDF Page 1', (1..edge_count).map { |i| Edge.new(9000 + i) })
  end

  # ---- (a) the free text helper cannot run ------------------------------

  def test_missing_helper_returns_false_flags_stats_and_does_not_raise
    stats = {}
    IMP::SvgTextRenderer.stub(:svg_renderer_available?, false) do
      refute IMP.enforce_svg_renderer_available!(nil, stats, '3D Text')
    end
    assert_equal true, stats[:svg_renderer_missing]
    IMP::SvgTextRenderer.stub(:svg_renderer_available?, true) do
      assert IMP.enforce_svg_renderer_available!(nil, {}, '3D Text')
    end
  end

  def test_missing_helper_lists_every_item_with_reason_renderer_missing
    stats = { :text_delivery_failures => [] }
    items = [text_item(2, 0), text_item(2, 1, 'NOTE A')]
    IMP.record_text_step_down!(
      stats, 2, :text3d, items, 'renderer_missing', IMP::SVG_RENDERER_REMEDY
    )
    rows = stats[:text_delivery_failures]
    assert_equal %w[text_span:2:0 text_span:2:1], rows.map { |row| row[:source_span_id] }
    assert rows.all? { |row| row[:reason] == 'renderer_missing' && row[:page] == 2 }
    assert rows.all? { |row| row[:certified] == false }
    assert_match(/Poppler or MuPDF/, rows.first[:detail])
    assert_match(/BC_PDFTOCAIRO_PATH/, rows.first[:detail])
    step = stats[:text_step_downs].first
    assert_equal({ :page => 2, :requested_mode => :text3d,
                   :reason_code => 'renderer_missing', :item_count => 2,
                   :page_kept => true },
                 step.reject { |key, _| key == :detail })
  end

  # The 3-page acceptance fixture: the real resumable entry point, the real
  # page orchestrator and certifier, a real 3-page PDF, the helper hidden.
  # Each page is built by the page body below (lines first, then the same
  # helper checks run_pipeline makes) because the full page builder needs a
  # live SketchUp.
  def run_fixture(page_count, helper_available)
    Dir.mktmpdir('keep-page') do |dir|
      pdf = SyntheticPdfBuilder.write_pages(
        File.join(dir, 'fixture.pdf'),
        (1..page_count).map { |page| "0 0 m #{page * 10} 10 l S" }
      )
      model = Model.new
      page_body = lambda do |host_model, _path, opts|
        page = opts[:pages].first
        stats = { :pages => 1, :edges => 0, :text => 0,
                  :text_delivery_failures => [] }
        failures_before = stats[:text_delivery_failures].length
        group = Group.new(100 + page, "PDF Page #{page}",
                          [Edge.new(1000 + page), Edge.new(2000 + page)])
        host_model.active_entities.add(group)
        stats[:edges] += group.entities.length
        items = [text_item(page, 0), text_item(page, 1, 'NOTE')]
        if IMP.svg_renderer_required_for_page?('3D Text', true, items, false)
          unless IMP.enforce_svg_renderer_available!(host_model, stats, '3D Text')
            IMP.record_text_step_down!(stats, page, '3D Text', items,
                                       'renderer_missing', IMP::SVG_RENDERER_REMEDY)
          end
        end
        IMP.ensure_kept_page_has_content!(group, page, stats, failures_before)
        offset = opts[:initial_y_offset].to_f + 10.0
        opts[:page_certifier].call(group, offset, stats)
        stats[:next_y_offset] = offset
        stats
      end
      result = nil
      IMP::PdfSalvage.stub(:prepare_if_needed, lambda { |source| [source, nil] }) do
      IMP::SvgTextRenderer.stub(:svg_renderer_available?, helper_available) do
        IMP.stub(:run_pipeline, page_body) do
          IMP.stub(:finalize_import_diagnostics!, lambda { |*_| true }) do
            result = IMP.run_resumable_pipeline(
              model, pdf,
              :pages => (1..page_count).to_a, :text_mode => '3D Text',
              :import_text => true, :group_per_page => true,
              :resumable => true,
              :cancel_probe => lambda { false },
              :status_sink => lambda { |_| }
            )
          end
        end
      end
      end
      return [result, model]
    end
  end

  def test_three_page_fixture_keeps_every_page_with_its_lines_when_helper_is_hidden
    result, model = run_fixture(3, false)
    groups = model.active_entities.to_a
    assert_equal ['PDF Page 1', 'PDF Page 2', 'PDF Page 3'], groups.map(&:name)
    assert groups.all? { |group| group.entities.to_a.count { |e| e.typename == 'Edge' } > 0 }
    assert_equal [1, 2, 3], result[:retained_pages]
    assert_empty result[:failed_pages]
    rows = result[:text_delivery_failures]
    assert_equal 6, rows.length
    assert rows.all? { |row| row[:reason] == 'renderer_missing' }
    assert_equal [1, 2, 3], rows.map { |row| row[:page] }.uniq.sort
    assert_equal 'incomplete', result[:result_status]
    assert_equal 'incomplete', IMP.import_result_status(result)
    assert IMP.pages_kept_with_step_downs?(result)

    line = IMP::ReportDialog.completion_status(result)
    assert_includes line, 'PDF import finished with problems'
    assert_includes line, '6 text items could not be delivered on pages 1-3 ' \
                          '(the free PDF text helper could not run); the rest ' \
                          'of each page was kept.'
    assert_includes line, 'Extensions > PDF Vector Importer > Import Health'
  end

  # ---- (c) a one-page PDF never ends in a failure because of text --------

  def test_one_page_pdf_with_a_text_failure_returns_incomplete_instead_of_raising
    result, model = run_fixture(1, false)
    assert_equal 'incomplete', result[:result_status]
    assert_equal [1], result[:retained_pages]
    assert_equal 1, model.active_entities.length
  end

  def test_helper_present_keeps_the_clean_success_path
    result, = run_fixture(2, true)
    assert_equal 'success', result[:result_status]
    assert_empty Array(result[:text_delivery_failures])
    assert_match(/\APDF import complete/, IMP::ReportDialog.completion_status(result))
  end

  # ---- (b) a page-scoped renderer exception keeps the page ---------------

  def test_page_scoped_text_failure_erases_only_the_stage_text_and_keeps_the_page
    page = page_with_lines(3)
    items = [text_item(4, 0), text_item(4, 1)]
    stats = { :text => 0, :faces => 5, :text_delivery_failures => [],
              :source_glyph_physical_deliveries => [] }
    kept = IMP.keep_page_on_text_failure(
      stats, 4, :text3d, :parent => page.entities, :owner => :any_text,
      :items => items, :reason_code => 'text_stage_failed'
    ) do
      page.entities.add(text_group(51, 'text_span:4:0'))
      container = Group.new(52, 'PDF Glyphs Text Page 4')
      container.set_attribute('BC_PDF_Importer', 'representation_container', true)
      page.entities.add(container)
      stats[:text] += 2
      stats[:faces] += 40
      stats[:source_glyph_physical_deliveries] << { :page => 4 }
      stats[:text_attempts] = [{ :source_span_id => 'text_span:4:0' }]
      failures = [{ :source_span_id => nil, :reason => 'renderer_exception',
                    :detail => 'one glyph blew up' }]
      IMP.enforce_requested_text_delivery!(4, :text3d, failures)
    end
    assert_equal false, kept
    assert_equal [9001, 9002, 9003], page.entities.to_a.map(&:persistent_id),
                 'the page keeps every line; only the stage text is erased'
    assert_equal [51, 52], page.entities.erased.map(&:persistent_id)
    assert_equal 0, stats[:text], 'counters roll back with the erased text'
    assert_equal 5, stats[:faces]
    assert_empty stats[:source_glyph_physical_deliveries]
    refute stats.key?(:text_attempts), 'rows the failed stage created are dropped'
    rows = stats[:text_delivery_failures]
    assert_equal %w[text_span:4:0 text_span:4:1], rows.map { |row| row[:source_span_id] }
    assert rows.all? { |row| row[:reason] == 'text_stage_failed' }
    assert_match(/renderer_exception/, rows.first[:detail])
    assert_equal 1, stats[:text_step_downs].length
  end

  def test_one_failed_item_keeps_its_delivered_peers
    container = Group.new(60, 'PDF Glyphs Text Page 2')
    peer = text_group(61, 'text_span:2:0')
    container.entities.add(peer)
    stats = { :text_delivery_failures => [] }
    kept = IMP.keep_page_on_text_failure(
      stats, 2, :glyphs, :parent => container.entities,
      :owner => 'text_span:2:1', :items => [text_item(2, 1)],
      :reason_code => 'text_item_failed'
    ) do
      container.entities.add(text_group(62, 'text_span:2:1'))
      raise CE, 'text_span:2:1: glyphs item renderer failed generically'
    end
    assert_equal false, kept
    assert_equal [61], container.entities.to_a.map(&:persistent_id)
    assert_equal ['text_span:2:1'],
                 stats[:text_delivery_failures].map { |row| row[:source_span_id] }
  end

  def test_successful_stage_changes_nothing
    page = page_with_lines(1)
    stats = { :text => 0 }
    kept = IMP.keep_page_on_text_failure(
      stats, 1, :text3d, :parent => page.entities, :owner => :any_text,
      :items => [text_item(1, 0)]
    ) do
      page.entities.add(text_group(71, 'text_span:1:0'))
      stats[:text] += 1
    end
    assert_equal true, kept
    assert_equal 2, page.entities.length
    assert_equal 1, stats[:text]
    refute stats.key?(:text_delivery_failures)
  end

  def test_text_presence_failure_is_listed_as_text_not_read
    stats = {}
    kept = IMP.keep_page_on_text_failure(
      stats, 3, :geometry, :reason_code => 'text_not_read'
    ) do
      raise CE, 'Page 3: 4 nonempty PDF text-show operation(s) were detected'
    end
    assert_equal false, kept
    row = stats[:text_delivery_failures].first
    assert_equal 'unidentified source span', row[:source_span_id]
    assert_equal 'text_not_read', row[:reason]
  end

  # ---- stops that must still stop ----------------------------------------

  def test_cancel_rollback_resume_and_batch_stops_still_propagate
    noninteractive = defined?(IMP::BatchHostPolicy::NoninteractiveError) ?
      IMP::BatchHostPolicy::NoninteractiveError.new('batch stop') : nil
    errors = [IRC::ImportCancelled.new([1], 2, {}),
              IRC::RollbackFailure.new('rollback failed'),
              IRC::ResumeMismatch.new('journal changed'),
              noninteractive].compact
    errors.each do |error|
      raised = assert_raises(error.class) do
        IMP.keep_page_on_text_failure({}, 1, :text3d) { raise error }
      end
      assert_same error, raised
    end
  end

  def test_unremovable_partial_text_still_rolls_the_page_back
    page = page_with_lines(2)
    stats = {}
    error = assert_raises(CE) do
      IMP.keep_page_on_text_failure(
        stats, 5, :text3d, :parent => page.entities, :owner => :any_text,
        :items => [text_item(5, 0)]
      ) do
        page.entities.add(Group.new(81, 'anonymous partial'))
        raise CE, 'renderer exploded'
      end
    end
    assert_match(/renderer exploded/, error.message)
    assert_match(/could not be removed/, error.message)
    refute stats.key?(:text_delivery_failures)
  end

  def test_kept_page_with_nothing_left_is_not_kept
    empty = Group.new(91, 'PDF Page 7')
    stats = { :text_delivery_failures => [{ :page => 7 }] }
    assert_raises(CE) { IMP.ensure_kept_page_has_content!(empty, 7, stats, 0) }
    assert IMP.ensure_kept_page_has_content!(empty, 7, stats, 1),
           'an empty page with no step-down keeps its old behaviour'
    assert IMP.ensure_kept_page_has_content!(page_with_lines(1), 7, stats, 0)
  end

  # ---- (d) and the wiring in run_pipeline --------------------------------

  def pipeline_source
    source = File.read(MAIN_RB, :encoding => 'UTF-8')
    source[/    def self\.run_pipeline\(model, path, opts\).*?(?=    def self\.place_embedded_images)/m]
  end

  def test_every_text_stage_runs_inside_the_keep_page_wrapper
    pipeline = pipeline_source
    refute_nil pipeline
    wrapped = pipeline.scan(/keep_page_on_text_failure\(/).length
    assert_operator wrapped, :>=, 8
    {
      'enforce_extracted_text_presence!(' => 'text_not_read',
      'complete_label_item_fallbacks!(' => ':owner => fallback_source_ids',
      'Svg3DTextRenderer.render_svg(' => ':owner => :any_text',
      'complete_text3d_item_fallbacks!(' => ':owner => proof_ids',
      'SvgItemRepresentationRenderer.render_unmatched_svg(' => ':owner => :source_unit'
    }.each do |call, owner|
      index = pipeline.index(call)
      refute_nil index, call
      opener = pipeline.rindex('keep_page_on_text_failure(', index)
      refute_nil opener, "#{call} is not wrapped"
      assert_includes pipeline[opener, index - opener], owner, call
    end
    ladders = pipeline.scan(/keep_page_on_text_failure\(.{0,260}?\) do\n\s*complete_item_representation_ladder!\(/m)
    assert_equal 2, ladders.length, 'Raster and Glyphs/Geometry items are each wrapped'
    refute_match(/enforce_requested_text_delivery!\(\s*page_num, requested_text_mode, hard_builder_failures/m,
                 pipeline, 'builder item failures are listed, not raised')
  end

  def test_geometry_builder_failure_still_rolls_the_page_back
    pipeline = pipeline_source
    build = pipeline.index('result = builder.build')
    refute_nil build
    last_wrapper_before_build = pipeline.rindex('keep_page_on_text_failure(', build)
    if last_wrapper_before_build
      between = pipeline[last_wrapper_before_build, build - last_wrapper_before_build]
      assert_match(/\n          end\n/, between, 'builder.build is not inside a wrapper')
    end
    assert_match(/      rescue RepresentationFidelity::ContractError => e\n.*?abort_open_operation!.*?raise e\n      rescue StandardError => e\n.*?abort_open_operation!.*?raise e\n      end\n      end\n/m,
                 pipeline, 'the page rescue still aborts and re-raises')
  end

  # ---- EXTRA: one failing white-area check no longer empties the sheet ----

  def test_failed_white_area_check_keeps_the_page_and_lists_it
    stats = {}
    composition = :untouched
    done = IMP.keep_page_on_page_stage_failure(
      stats, 6, 'white_areas', 'white_area_check_failed',
      'Some white areas were left as plain white shapes'
    ) do
      composition = nil
      raise CE, 'source-unit physical roots are missing or duplicated before mask composition'
    end
    assert_equal false, done
    assert_nil composition
    row = stats[:page_step_downs].first
    assert_equal 6, row[:page]
    assert_equal 'white_areas', row[:item]
    assert_equal 'white_area_check_failed', row[:reason_code]
    assert_match(/plain white shapes/, row[:detail])
    assert_match(/source-unit physical roots/, row[:detail])
    assert_equal true, row[:page_kept]
    line = IMP::ReportDialog.completion_status(
      :pages => 6, :edges => 10, :text => 2, :page_step_downs => stats[:page_step_downs]
    )
    assert_includes line, 'Simplified on page 6 (see the report).'
    report = IMP::QAReport.build_from_stats('fictional.pdf', { import_mode: 'auto' },
                                            :pages => 6, :edges => 10, :primitives => 10,
                                            :page_step_downs => stats[:page_step_downs])
    json = JSON.parse(JSON.generate(report))
    assert_equal true, json['fallback']['used']
    assert_equal 'page_items_stepped_down', json['fallback']['reason']
    assert_includes json['extra']['human_summary'], 'Simplified on page 6'
  end

  def test_white_area_stage_still_propagates_terminal_stops
    error = IRC::ImportCancelled.new([1], 2, {})
    raised = assert_raises(IRC::ImportCancelled) do
      IMP.keep_page_on_page_stage_failure({}, 2, 'white_areas', 'x', 'y') { raise error }
    end
    assert_same error, raised
  end

  def test_white_area_stage_and_late_marks_are_wrapped_in_run_pipeline
    pipeline = pipeline_source
    compose = pipeline.index('composition = compose_page_white_masks!(')
    refute_nil compose
    opener = pipeline.rindex('keep_page_on_page_stage_failure(', compose)
    refute_nil opener, 'the white-area stage steps down instead of failing the page'
    assert_operator compose - opener, :<, 400
    refute_match(/raise RepresentationFidelity::ContractError,\s*'final vector annotations require the complete page text inventory'/,
                 pipeline)
    annotation_context = pipeline.index('overlay_context = late_overlay_composition_context!(')
    refute_nil annotation_context
    annotation_guard = pipeline.rindex('keep_page_on_page_stage_failure(', annotation_context)
    refute_nil annotation_guard, 'incomplete annotation checks keep and report the page'
    assert_operator annotation_context - annotation_guard, :<, 400
    assert_match(/overlay_top = overlay_context \? overlay_context\[:highest_text_z\] : 0\.0/, pipeline)
  end

  # ---- report: fallback_used and human_summary ---------------------------

  def test_report_marks_fallback_used_and_says_what_was_not_delivered
    stats = { :pages => 2, :edges => 40, :text => 3, :primitives => 40,
              :text_delivery_failures => [
                { :page => 2, :source_span_id => 'text_span:2:0',
                  :reason => 'renderer_missing', :detail => 'x', :certified => false }
              ],
              :text_step_downs => [{ :page => 2, :reason_code => 'renderer_missing',
                                     :item_count => 1, :page_kept => true }] }
    report = IMP::QAReport.build_from_stats('fictional.pdf', { import_mode: 'auto' }, stats)
    json = JSON.parse(JSON.generate(report))
    assert_equal true, json['fallback']['used']
    assert_equal 'text_items_not_delivered', json['fallback']['reason']
    assert_equal 1, json['extra']['text_step_downs'].length
    summary = json['extra']['human_summary']
    assert_includes summary, '1 text item could not be delivered on page 2; ' \
                             'the rest of each page was kept (the free PDF text ' \
                             'helper could not run)'
    refute_includes summary, 'Raster or degraded fallback'
    clean = IMP::QAReport.build_from_stats('fictional.pdf', { import_mode: 'auto' },
                                           :pages => 1, :edges => 4, :primitives => 4)
    assert_equal false, JSON.parse(JSON.generate(clean))['fallback']['used']
  end

  # ---- the rule book states the owner's ruling ---------------------------

  def test_rule_book_states_deliver_step_down_report
    root = File.expand_path('..', __dir__)
    agents = File.read(File.join(root, 'AGENTS.md'), :encoding => 'UTF-8')
    rule = File.read(File.join(root, '.cursor', 'rules', 'text-mode-fidelity.mdc'),
                     :encoding => 'UTF-8')
    [agents, rule].each do |document|
      normalized = document.gsub(/\s+/, ' ')
      assert_includes normalized, 'deliver, step down, report'
      assert_match(/\*{0,2}never\*{0,2} a reason to stop the import or (?:to )?drop a page or a file/i, normalized)
      assert_includes normalized, 'BC_PDF_AUDIT=1'
      refute_match(/report the exact source-span failure, and stop the operation/, normalized)
      refute_match(/identify the exact source span, and stop\./, normalized)
    end
  end
end
