require_relative 'geometry_builder_lineweight_test'
require 'minitest/mock'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog'

# A dense drawing sheet can hold tens of thousands of separately q/cm/Q-wrapped
# round-cap (1 J 1 j) two-point lines. The dialog's default lineweight_mode
# had long been 'Preserve visually'; from v3.7.163 that default sent every such
# line to VectorStrokeFootprint (about 97 one-face groups per line plus Rational
# planning): tens of minutes of Ruby on one sheet before SketchUp's own cost.
# A default import keeps plain one-edge-per-line output for every non-raster
# dialog mode; width footprints stay an explicit choice, and an explicit
# choice on a sheet this dense falls back to centerlines at the cell budget.
class DefaultImportRoundCapSheetTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  LT = GeometryBuilderLineweightTest
  # Above GEOMETRY_STAGING_PATH_THRESHOLD, so the dense-page route is used.
  LINES = 600
  MEDIA_BOX = [0, 0, 3456, 2592]
  COLORS = ['0 0 0', '1 0 0', '0 0 1']

  def sheet_stream(lines = LINES)
    (0...lines).map do |i|
      "q 0.5 0 0 0.5 0 0 cm #{COLORS[i % COLORS.length]} RG 1 J 1 j 1.5 w " \
        "#{100 + i * 5} 400 m #{260 + i * 5} #{520 + (i % 11)} l S Q"
    end.join("\n")
  end

  def tree_counts(entities, acc = Hash.new(0))
    entities.to_a.each do |node|
      if node.respond_to?(:entities)
        acc[:groups] += 1
        tree_counts(node.entities, acc)
      elsif node.is_a?(GeometryBuilderStagingTest::Face)
        acc[:faces] += 1
      elsif node.is_a?(GeometryBuilderStagingTest::Edge)
        acc[:edges] += 1
      end
    end
    acc
  end

  # Builds the sheet with the switches main.rb passes for a page and counts
  # footprint planning. Planning is refused so a regression fails fast instead
  # of spending tens of milliseconds per line.
  def build_sheet(opts, lines = LINES)
    model = LT::Model.new
    paths = IMP::ContentStreamParser.new([sheet_stream(lines)], nil).parse
    assert_equal lines, paths.length
    assert paths.all? { |p| p.line_cap == 1 && p.line_join == 1 && p.source_stroke_style_proven }
    builder = IMP::GeometryBuilder.new(model, paths, [], MEDIA_BOX,
      :page_clip_box => MEDIA_BOX, :group_per_page => opts[:group_per_page],
      :group_by_color => opts[:group_by_color], :detect_arcs => false,
      :map_dashes => opts[:map_dashes], :import_fills => opts[:import_fills],
      :merge_tolerance => opts[:merge_tolerance], :lineweight_mode => opts[:lineweight_mode])
    plans = 0
    refuse = lambda do |*_args|
      plans += 1
      raise IMP::VectorStrokeFootprint::Unsupported, 'test refuses footprint planning'
    end
    result = IMP::VectorStrokeFootprint.stub(:plan, refuse) { builder.build }
    [model, result, plans]
  end

  %w[auto vector hybrid].each do |mode|
    define_method("test_default_#{mode}_import_keeps_round_cap_lines_as_plain_edges") do
      opts = IMP::ImportDialog.send(:build_opts, :import_mode => mode)
      model, result, plans = build_sheet(opts)
      tree = tree_counts(model.active_entities)
      assert_equal 0, plans, "default #{mode} import routed #{plans} round-cap lines to width footprints"
      assert_equal 0, result[:faces]
      assert_equal LINES, tree[:edges]
      assert_equal 0, tree[:faces]
      assert_operator tree[:groups], :<=, 10, 'native group count must not scale with line count'
    end
  end

  def explicit_preserve_visually_opts
    opts = IMP::ImportDialog.send(:build_opts, :import_mode => 'auto',
      :lineweight_mode => 'Preserve visually')
    assert_equal 'Preserve visually', opts[:lineweight_mode]
    opts
  end

  # 40 round-cap lines estimate about 3,900 cells, under the page budget, so
  # an explicit choice still plans a width footprint for every line.
  def test_explicit_preserve_visually_still_plans_width_footprints
    _model, result, plans = build_sheet(explicit_preserve_visually_opts, 40)
    assert_equal 40, plans
    refute result[:geometry_staging][:stroke_footprints][:simplified]
  end

  def test_explicit_preserve_visually_on_a_dense_sheet_falls_back_at_the_cell_budget
    _model, result, plans = build_sheet(explicit_preserve_visually_opts)
    footprints = result[:geometry_staging][:stroke_footprints]
    assert_equal 0, plans
    assert footprints[:simplified]
    assert_equal 'cell_budget', footprints[:simplify_trigger]
    assert_equal LINES, footprints[:simplified_path_count]
  end
end
