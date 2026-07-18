# test/svg_text_collapse_test.rb
# Unit tests for SvgTextRenderer's missing-font / collapsed-glyph guard.
# Regression cover for the "Symbol font -> 296 glyphs piled at the page
# corner -> illegible blob" defect. Ruby 2.2 compatible (no &., #sum, #then).

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer'

class SvgTextCollapseTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer

  # n identical degenerate placements at the page corner, mimicking what
  # pdftocairo emits when it has "No display font for 'Symbol'".
  def collapsed(n)
    Array.new(n) do
      { glyph_id: 'glyph-0-1', x: 0.0, y: 0.0,
        matrix: [0.0, -0.12, -0.12, 0.0, 2592.0, 1728.0] }
    end
  end

  # n distinct, advancing placements (legitimate text run).
  def normal(n)
    (0...n).map do |i|
      { glyph_id: "glyph-0-#{i}", x: 0.0, y: 0.0,
        matrix: [0.12, 0.0, 0.0, -0.12, 100.0 + i * 7.0, 500.0] }
    end
  end

  def test_identical_transforms_share_signature
    a = collapsed(3)
    assert_equal R.placement_signature(a[0]), R.placement_signature(a[2])
  end

  def test_distinct_positions_have_distinct_signatures
    p = normal(2)
    refute_equal R.placement_signature(p[0]), R.placement_signature(p[1])
  end

  def test_x_y_offsets_fold_into_signature
    base = { glyph_id: 'g', x: 0.0, y: 0.0, matrix: [1.0, 0.0, 0.0, 1.0, 10.0, 20.0] }
    moved = { glyph_id: 'g', x: 5.0, y: 0.0, matrix: [1.0, 0.0, 0.0, 1.0, 5.0, 20.0] }
    # 5 (e) + 5 (x) == 10 (e) + 0 (x): same effective placement.
    assert_equal R.placement_signature(base), R.placement_signature(moved)
  end

  def test_exact_physical_deduplication_keeps_one_visible_outline
    base = {
      glyph_id: 'g', x: 0.0, y: 0.0,
      matrix: [1.0, 0.0, 0.0, 1.0, 10.0, 20.0]
    }
    same_effective = {
      glyph_id: 'g', x: 5.0, y: 0.0,
      matrix: [1.0, 0.0, 0.0, 1.0, 5.0, 20.0]
    }
    nearby = {
      glyph_id: 'g', x: 5.0000000004, y: 0.0,
      matrix: [1.0, 0.0, 0.0, 1.0, 5.0, 20.0]
    }

    unique, duplicates = R.deduplicate_exact_physical_placements(
      [base, same_effective, nearby]
    )

    assert_equal 2, unique.length
    assert_equal [0, 2], unique.map { |item| item[:source_placement_index] }
    assert_equal 1, duplicates.length
    assert_equal 0, duplicates[0][:retained_placement_index]
    assert_equal 1, duplicates[0][:duplicate_placement_index]
  end

  def test_transformed_source_ink_bbox_is_pdf_relative_and_finite
    points = [[
      DummyPoint.new(0.0, 0.0), DummyPoint.new(1.0, 0.0),
      DummyPoint.new(1.0, -2.0), DummyPoint.new(0.0, -2.0)
    ]]

    bbox = R.transformed_source_ink_bbox_pdf(
      points, 1.0, 0.0, 0.0, 1.0,
      12.0, 24.0, 1.0, 1.0, 3.0, 2.0, 4.0
    )

    assert_equal [10.0, 15.0, 11.0, 17.0], bbox
  end

  def test_detects_bulk_collapse_only
    placements = collapsed(296) + normal(20)
    keys = R.collapsed_signature_keys(placements)
    assert_equal 1, keys.length
    assert_includes keys, R.placement_signature(collapsed(1)[0])
  end

  def test_normal_text_is_not_flagged
    assert_empty R.collapsed_signature_keys(normal(50))
  end

  def test_threshold_boundary
    refute_includes R.collapsed_signature_keys(collapsed(11)),
                    R.placement_signature(collapsed(1)[0])
    assert_includes R.collapsed_signature_keys(collapsed(12)),
                    R.placement_signature(collapsed(1)[0])
  end

  def test_missing_display_fonts_parsing
    err = "Syntax Error: No display font for 'Symbol'\n" \
          "Syntax Error: No display font for 'ZapfDingbats'\n" \
          "Syntax Error: No display font for 'Symbol'\n"
    assert_equal ['Symbol', 'ZapfDingbats'], R.missing_display_fonts(err)
  end

  def test_missing_display_fonts_empty_inputs
    assert_empty R.missing_display_fonts('')
    assert_empty R.missing_display_fonts(nil)
  end

  def test_parses_mutool_font_path_ids_and_placements
    svg = '<svg viewBox="0 0 100 100"><defs>' \
          '<path id="font_7_38" d="M.1 0L.2 0Z"/>' \
          '</defs><use data-text="C" xlink:href="#font_7_38" ' \
          'transform="matrix(9,0,0,-9,10,20)"/></svg>'

    defs = R.parse_glyph_defs(svg)
    assert_equal 'M.1 0L.2 0Z', defs['font_7_38']

    placements = R.parse_use_placements(svg)
    assert_equal 1, placements.length
    assert_equal 'font_7_38', placements[0][:glyph_id]
    assert_equal [9.0, 0.0, 0.0, -9.0, 10.0, 20.0], placements[0][:matrix]
  end

  def test_svg_render_args_support_mutool
    renderer = { kind: :mutool, exe: 'mutool' }
    variants = R.svg_render_arg_variants(renderer, 'in.pdf', 'out.svg', 3, true)

    assert_equal ['mutool', 'draw', '-q', '-F', 'svg', '-b', 'CropBox',
                  '-o', 'out.svg', 'in.pdf', '3'], variants[0]
    assert_equal ['mutool', 'draw', '-q', '-F', 'svg',
                  '-o', 'out.svg', 'in.pdf', '3'], variants[1]
  end

  def test_temp_svg_path_is_extensionless_for_pdftocairo_multi_page_svg
    path = R.temp_svg_path
    refute_match(/\.svg\z/i, path)
  end

  def test_svg_path_distance_thresholds_are_numeric_not_host_fuzzy_lengths
    path = 'M 0 0 L 1 0 L 0.0001 0 Z'
    float_factory = lambda { |x, y, z| DummyPoint.new(x, y, z) }
    fuzzy_factory = lambda { |x, y, z| FuzzyPoint.new(x, y, z) }

    expected = R.svg_path_to_points(path, 1.0, 1.0, float_factory)
    actual = R.svg_path_to_points(path, 1.0, 1.0, fuzzy_factory)

    assert_equal expected.map(&:length), actual.map(&:length)
    assert_equal expected.flatten.map { |point| [point.x, point.y] },
                 actual.flatten.map { |point| [point.x, point.y] }
  end

  def test_svg_path_preserves_every_nonzero_source_segment_for_scaled_construction
    path = 'M 0 0 L 0.000217 0 L 1 0 L 1 1 Z'
    factory = lambda { |x, y, z| DummyPoint.new(x, y, z) }

    points = R.svg_path_to_points(path, 1.0, 1.0, factory).flatten

    assert points.any? { |point| (point.x.to_f - 0.000217).abs < 1.0e-12 },
           'nonzero source edge must reach tolerance-safe 3D construction'
  end

  def test_svg_path_moveto_additional_pairs_are_line_segments
    factory = lambda { |x, y, z| DummyPoint.new(x, y, z) }

    absolute = R.svg_path_to_points(
      'M 0 0 10 0 10 10 Z', 1.0, 1.0, factory
    )
    relative = R.svg_path_to_points(
      'm 1 1 2 0 0 2 z', 1.0, 1.0, factory
    )

    assert_equal [[0.0, -0.0], [10.0, -0.0], [10.0, -10.0], [0.0, -0.0]],
                 absolute[0].map { |point| [point.x, point.y] }
    assert_equal [[1.0, -1.0], [3.0, -1.0], [3.0, -3.0], [1.0, -1.0]],
                 relative[0].map { |point| [point.x, point.y] }
  end

  def test_svg_path_smooth_cubic_and_quadratic_commands_keep_curvature
    factory = lambda { |x, y, z| DummyPoint.new(x, y, z) }
    cubic = R.svg_path_to_points(
      'M 0 0 C 0 10 10 10 10 0 S 20 -10 20 0',
      1.0, 1.0, factory
    )[0]
    quadratic = R.svg_path_to_points(
      'M 0 0 Q 5 10 10 0 T 20 0', 1.0, 1.0, factory
    )[0]

    assert_equal 9, cubic.length
    assert_equal 9, quadratic.length
    refute_in_delta 0.0, cubic[-2].y, 1.0e-9
    refute_in_delta 0.0, quadratic[-2].y, 1.0e-9
    assert_in_delta 20.0, cubic[-1].x, 1.0e-9
    assert_in_delta 20.0, quadratic[-1].x, 1.0e-9
  end

  def test_svg_path_absolute_and_relative_arcs_preserve_curved_geometry
    factory = lambda { |x, y, z| DummyPoint.new(x, y, z) }
    absolute = R.svg_path_to_points(
      'M 10 0 A 10 10 0 0 1 0 10', 1.0, 1.0, factory
    )[0]
    relative = R.svg_path_to_points(
      'm 10 0 a 10 10 0 0 1 -10 10', 1.0, 1.0, factory
    )[0]

    assert_operator absolute.length, :>, 2
    assert_equal absolute.map { |point| [point.x, point.y] },
                 relative.map { |point| [point.x, point.y] }
    middle = absolute[absolute.length / 2]
    assert_in_delta 10.0,
                    Math.sqrt((middle.x * middle.x) + (middle.y * middle.y)),
                    1.0e-8
    assert_in_delta 0.0, absolute[-1].x, 1.0e-9
    assert_in_delta(-10.0, absolute[-1].y, 1.0e-9)
  end

  def test_glyph_component_flattening_defaults_on_with_escape_hatch
    old = ENV['BC_SU_KEEP_GLYPH_COMPONENTS']
    ENV.delete('BC_SU_KEEP_GLYPH_COMPONENTS')
    assert R.flatten_glyph_instances?({})
    refute R.flatten_glyph_instances?({}, 65_444)

    ENV['BC_SU_KEEP_GLYPH_COMPONENTS'] = '1'
    refute R.flatten_glyph_instances?({})
    refute R.flatten_glyph_instances?({ flatten_glyph_instances: false })
    assert R.flatten_glyph_instances?({ flatten_glyph_instances: true })
  ensure
    if old.nil?
      ENV.delete('BC_SU_KEEP_GLYPH_COMPONENTS')
    else
      ENV['BC_SU_KEEP_GLYPH_COMPONENTS'] = old
    end
  end

  def test_large_edge_counts_switch_to_component_strategy
    old_raw = ENV['BC_SU_GLYPH_RAW_EDGE_BUDGET']
    old_flatten = ENV['BC_SU_GLYPH_FLATTEN_EDGE_BUDGET']
    ENV.delete('BC_SU_GLYPH_RAW_EDGE_BUDGET')
    ENV.delete('BC_SU_GLYPH_FLATTEN_EDGE_BUDGET')

    assert R.raw_edge_glyphs?({}, 1_919, 3_000)
    refute R.raw_edge_glyphs?({}, 1_919, 10_000)
    refute R.raw_edge_glyphs?({}, 1_919, 65_444)
    assert R.flatten_glyph_instances?({}, 2_000)
    refute R.flatten_glyph_instances?({}, 10_000)
    refute R.flatten_glyph_instances?({}, 65_444)
  ensure
    if old_raw.nil?
      ENV.delete('BC_SU_GLYPH_RAW_EDGE_BUDGET')
    else
      ENV['BC_SU_GLYPH_RAW_EDGE_BUDGET'] = old_raw
    end
    if old_flatten.nil?
      ENV.delete('BC_SU_GLYPH_FLATTEN_EDGE_BUDGET')
    else
      ENV['BC_SU_GLYPH_FLATTEN_EDGE_BUDGET'] = old_flatten
    end
  end

  def test_raw_edge_glyphs_use_estimated_edge_budget
    old = ENV['BC_SU_GLYPH_RAW_EDGE_BUDGET']
    ENV['BC_SU_GLYPH_RAW_EDGE_BUDGET'] = '20000'

    assert R.raw_edge_glyphs?({}, 1_919, 12_000)
    refute R.raw_edge_glyphs?({}, 1_919, 65_444)
    refute R.raw_edge_glyphs?({}, 5_001, 12_000)
    assert R.raw_edge_glyphs?({ raw_edge_glyphs: true }, 1_919, 65_444)
    refute R.raw_edge_glyphs?({ raw_edge_glyphs: false }, 1_919, 12_000)
  ensure
    if old.nil?
      ENV.delete('BC_SU_GLYPH_RAW_EDGE_BUDGET')
    else
      ENV['BC_SU_GLYPH_RAW_EDGE_BUDGET'] = old
    end
  end

  def test_estimates_glyph_edges_from_reused_glyphs
    placements = [
      { glyph_id: 'glyph-a' },
      { glyph_id: 'glyph-b' },
      { glyph_id: 'glyph-a' },
      { glyph_id: 'missing' }
    ]
    counts = { 'glyph-a' => 12, 'glyph-b' => 3 }

    assert_equal 27, R.estimate_glyph_edge_count(placements, counts)
  end

  class DummyEdge
    attr_accessor :layer
    def typename
      'Edge'
    end
  end

  class DummyPoint
    attr_reader :x, :y, :z

    def initialize(x, y, z = 0.0)
      @x = x
      @y = y
      @z = z
    end

    def transform(_tr)
      self
    end

    def distance(other)
      dx = x.to_f - other.x.to_f
      dy = y.to_f - other.y.to_f
      dz = z.to_f - other.z.to_f
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
  end

  class FuzzyLength
    include Comparable
    def initialize(value); @value = value.to_f; end
    def to_f; @value; end
    def <=>(other)
      difference = @value - other.to_f
      return 0 if difference.abs < 0.001
      difference < 0.0 ? -1 : 1
    end
  end

  class FuzzyPoint < DummyPoint
    def distance(other)
      FuzzyLength.new(super)
    end
  end

  class DummyEntities
    attr_reader :add_edges_calls, :add_line_calls, :edges

    def initialize
      @add_edges_calls = 0
      @add_line_calls = 0
      @edges = []
    end

    def add_edges(points)
      @add_edges_calls += 1
      made = []
      points.each_cons(2) { made << DummyEdge.new }
      @edges.concat(made)
      made
    end

    def add_line(_a, _b)
      @add_line_calls += 1
      edge = DummyEdge.new
      @edges << edge
      edge
    end
  end

  class FailingBatchEntities < DummyEntities
    def add_edges(_points)
      @add_edges_calls += 1
      raise 'batch unavailable'
    end
  end

  class DummyInstance
    def initialize(exploded)
      @exploded = exploded
    end

    def explode
      @exploded
    end
  end

  def test_explode_glyph_instance_counts_edges_and_applies_layer
    edge = DummyEdge.new
    exploded_edges = R.explode_glyph_instance(DummyInstance.new([edge]), 'PDF Text')

    assert_equal 1, exploded_edges
    assert_equal 'PDF Text', edge.layer
  end

  def test_raw_glyph_edges_batch_each_subpath
    entities = DummyEntities.new
    paths = [
      [DummyPoint.new(0, 0), DummyPoint.new(1, 0), DummyPoint.new(1, 1)],
      [DummyPoint.new(2, 0), DummyPoint.new(2, 1)]
    ]

    count = R.add_transformed_glyph_edges(entities, paths, nil, 'PDF Text')

    assert_equal 3, count
    assert_equal 2, entities.add_edges_calls
    assert_equal 0, entities.add_line_calls
    assert_equal ['PDF Text'], entities.edges.map(&:layer).uniq
  end

  def test_raw_glyph_edges_fall_back_to_segments_when_batch_fails
    entities = FailingBatchEntities.new
    paths = [[DummyPoint.new(0, 0), DummyPoint.new(1, 0), DummyPoint.new(1, 1)]]

    count = R.add_transformed_glyph_edges(entities, paths, nil, 'PDF Text')

    assert_equal 2, count
    assert_equal 1, entities.add_edges_calls
    assert_equal 2, entities.add_line_calls
    assert_equal ['PDF Text'], entities.edges.map(&:layer).uniq
  end
end
