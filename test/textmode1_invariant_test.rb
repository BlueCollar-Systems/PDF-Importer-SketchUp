#!/usr/bin/env ruby
# TEXTMODE-1 production-path lock: generic API/helper failures and broken
# transforms cannot authorize a representation substitution.  Runtime either
# certifies the requested type or aborts the requested delivery explicitly.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/main'

class TextModeOwnedEntity
  attr_reader :persistent_id

  def initialize(id)
    @persistent_id = id
  end
end

class TextModeOwnedEntities
  attr_reader :erased

  def initialize(items = [])
    @items = items.dup
    @erased = []
  end

  def to_a
    @items.dup
  end

  def add(entity)
    @items << entity
    entity
  end

  def erase_entities(*items)
    items.flatten.each do |item|
      @items.delete(item)
      @erased << item
    end
  end
end

class TextModeOneInvariantTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def report_for(renderers)
    IMP::QAReport.build_from_stats('x.pdf', {}, {
      pages: 1,
      primitives: 1,
      edges: 1,
      text: 1,
      layers: [],
      elapsed_seconds: 0.1,
      text_renderers: renderers
    })
  end

  def assert_requested_equals_delivered_or_reported(report, requested, delivered)
    return assert_equal requested, delivered if requested == delivered

    text = report[:fallback][:text]
    refute_nil text, 'a substituted text mode must be loud in fallback.text'
    assert_equal requested, text[:requested]
    assert_equal delivered, text[:delivered]
    refute_empty text[:reason].to_s
  end

  def test_generic_text_failure_aborts_without_mutating_to_raster
    failures = [{
      source_span_id: 'text_span:1:0', requested: :text3d,
      reason: 'text3d_mesh_unavailable', count: 1,
      attempt_history: [
        { mode: :text3d, outcome: :failed, cleanup_outcome: :not_required }
      ]
    }]

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.enforce_requested_text_delivery!(1, :text3d, failures)
    end
    assert_match(/requested 3D Text representation was not certified/, error.message)
    assert_match(/no representation fallback is authorized/, error.message)

    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'), encoding: 'UTF-8'
    )
    refute_match(/promote_text_delivery_failures_to_raster!/, main)
    refute_match(/falling back to .*text \(degraded fidelity\)/, main)
  end

  def test_normal_native_label_delivery_needs_no_fallback_record
    stats = { text_renderers: [] }
    IMP.record_text_renderer(stats, 1,
      renderer: :labels,
      mode: :labels,
      requested_mode: :labels,
      degraded: false)

    report = report_for(stats[:text_renderers])
    assert_nil report[:fallback][:text]
    assert_requested_equals_delivered_or_reported(report, 'labels', 'labels')
  end

  def test_distinct_item_renderers_replace_the_old_missing_renderer_roadblock
    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'), encoding: 'UTF-8'
    )
    renderer = File.read(File.join(
      SRC_ROOT, 'bc_pdf_vector_importer',
      'svg_item_representation_renderer.rb'
    ), encoding: 'UTF-8')

    refute_match(/stop_unimplemented_item_fallback!/, main)
    assert_match(/SvgItemRepresentationRenderer\.render_svg/, main)
    assert_match(/build_glyph_groups!/, renderer)
    assert_match(/build_flat_geometry!/, renderer)
    assert_match(/cleanup_created_since/, renderer)
  end
end
