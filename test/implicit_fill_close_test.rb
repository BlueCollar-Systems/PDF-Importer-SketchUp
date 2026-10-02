#!/usr/bin/env ruby
# PDF fill operators close every open subpath before they paint (PDF 32000-1,
# 8.5.3.1): `f`, `F`, `f*`, `B`, `B*` fill a contour that never wrote `h`.
# The importer used to build a face only for explicitly closed subpaths, so
# solid hole discs, arrowheads and dimension dots written without `h` (and
# every fill of a Ghostscript-rewritten page) were dropped.
#
# The implied closing segment belongs to the FILL only. `B` on an open
# contour must keep exactly the stroked segments the PDF draws.
#
# Host-free, Ruby 2.2-safe. Fixtures are synthetic content streams.
require_relative 'geometry_builder_staging_test'
require 'bc_pdf_vector_importer/bezier'

class ImplicitFillCloseTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Parser = IMP::ContentStreamParser
  Builder = IMP::GeometryBuilder
  Host = GeometryBuilderStagingTest
  MEDIA_BOX = [0, 0, 200, 100].freeze

  # The shared fake host plus the two things these cases need from SketchUp:
  # add_line (clipped stroke pieces) and Group#typename (the builder removes
  # its own empty fill containers by walking real groups).
  class Entities < GeometryBuilderStagingTest::Entities
    def add_line(a, b)
      edge = GeometryBuilderStagingTest::Edge.new(a, b)
      @items << edge
      edge
    end

    def add_group
      group = Group.new(self)
      @items << group
      @groups_created += 1
      group
    end
  end

  class Group < GeometryBuilderStagingTest::Group
    def initialize(parent)
      super
      @entities = Entities.new(false)
    end

    def typename
      'Group'
    end
  end

  class Model < GeometryBuilderStagingTest::Model
    def initialize(reject_small_faces = false)
      super
      @active_entities = Entities.new(reject_small_faces)
    end
  end

  Built = Struct.new(:model, :builder, :result, :paths)

  TRIANGLE = '10 10 m 40 10 l 40 30 l'.freeze
  TRIANGLE_POINTS = [[10.0, 10.0], [40.0, 10.0], [40.0, 30.0]].freeze

  def build(stream, options = {})
    model = options.delete(:model) || Model.new
    paths = Parser.new([stream], nil).parse
    builder = Builder.new(
      model, paths, [], MEDIA_BOX,
      { :group_per_page => false, :detect_arcs => false,
        :import_fills => true }.merge(options)
    )
    Built.new(model, builder, builder.build, paths)
  end

  def pdf_xy(point)
    [(point.x * 72.0).round(6), (point.y * 72.0).round(6)]
  end

  # Every entity below a container, with the names of the groups above it.
  def walk(entities, trail = [], found = [])
    entities.to_a.each do |entity|
      found << [entity, trail]
      if entity.is_a?(Host::Group)
        walk(entity.entities, trail + [entity.name.to_s], found)
      elsif entity.is_a?(Host::ComponentInstance)
        walk(entity.definition.entities, trail + ['<instance>'], found)
      end
    end
    found
  end

  def faces(built)
    walk(built.model.active_entities).select { |entity, _| entity.is_a?(Host::Face) }
  end

  def face_loops(built)
    faces(built).map { |face, _| face.points.map { |point| pdf_xy(point) } }
  end

  # Real stroked edges: the fake face owns its boundary edges privately, so
  # every Edge held by an Entities collection was requested as a stroke.
  def stroked(built)
    walk(built.model.active_entities).select { |entity, _| entity.is_a?(Host::Edge) }
  end

  def stroked_segments(built)
    stroked(built).map do |edge, _|
      [pdf_xy(edge.start_point), pdf_xy(edge.end_point)]
    end
  end

  def groups(built)
    walk(built.model.active_entities).select { |entity, _| entity.is_a?(Host::Group) }
  end

  def assert_no_new_diagnostics
    warnings = IMP::Logger.warning_count
    errors = IMP::Logger.error_count
    yield
    assert_equal warnings, IMP::Logger.warning_count, IMP::Logger.warnings.last.to_s
    assert_equal errors, IMP::Logger.error_count, IMP::Logger.errors.last.to_s
  end

  def test_nonzero_fill_of_an_unclosed_triangle_builds_one_face
    ['f', 'F'].each do |operator|
      built = build("1 0 0 rg #{TRIANGLE} #{operator}")
      assert_equal false, built.paths[0].subpaths[0].closed,
                   'the parsed subpath keeps the source fact: no closepath was written'
      assert_equal 1, built.result[:faces], operator
      assert_equal 0, built.result[:edges], operator
      assert_equal [TRIANGLE_POINTS], face_loops(built), operator
      assert_empty stroked(built), 'a fill never paints a stroke'
    end
  end

  def test_even_odd_fill_of_an_unclosed_triangle_builds_one_face
    built = build("1 0 0 rg #{TRIANGLE} f*")
    assert_equal 1, built.result[:faces]
    assert_equal 0, built.result[:edges]
    assert_equal [TRIANGLE_POINTS], face_loops(built)
  end

  def test_implicitly_closed_fill_follows_the_existing_fill_conventions
    built = build("0.25 0.5 0.75 rg #{TRIANGLE} f")
    face, trail = faces(built).first
    assert_equal ['PDF Fill', 'PDF source fill'], trail,
                 'the fill lives in its own source-fill container like a closed one'
    assert_equal [64, 128, 191],
                 [face.material.color.red, face.material.color.green, face.material.color.blue]
    assert_same face.material, face.back_material
    assert face.edges.all?(&:hidden), 'a fill boundary is never a visible stroke'
    records = built.builder.fill_only_groups
    assert_equal 1, records.length
    assert_equal [0.25, 0.5, 0.75], records[0][:fill_rgb]
    assert_equal true, records[0][:preserve_source]
    assert_equal built.paths[0].source_paint_order, records[0][:paint_order]
  end

  def test_fill_and_stroke_of_an_unclosed_triangle_keeps_exactly_the_two_drawn_edges
    ['B', 'B*'].each do |operator|
      built = build("0 0 1 RG 1 0 0 rg #{TRIANGLE} #{operator}")
      assert_equal false, built.paths[0].subpaths[0].closed, operator
      assert_equal 1, built.result[:faces], operator
      assert_equal 2, built.result[:edges], operator
      assert_equal [[[10.0, 10.0], [40.0, 10.0]], [[40.0, 10.0], [40.0, 30.0]]],
                   stroked_segments(built), operator
      refute stroked_segments(built).any? { |segment| segment.sort == [[10.0, 10.0], [40.0, 30.0]] },
             'the implied closing segment belongs to the fill, not to the stroke'
      stroked(built).each do |edge, trail|
        refute_includes trail, 'PDF Fill', 'true strokes stay outside the fill container'
        assert_equal [0, 0, 255],
                     [edge.material.color.red, edge.material.color.green, edge.material.color.blue]
        refute edge.hidden
      end
      face, trail = faces(built).first
      assert_equal ['PDF Fill', 'PDF source fill'], trail, operator
      assert_equal TRIANGLE_POINTS, face.points.map { |point| pdf_xy(point) }
      assert_equal 3, face.edges.length, 'the fill owns its complete boundary'
      assert face.edges.all?(&:hidden), 'including the implied closing side, hidden'
      assert_equal 255, face.material.color.red
    end
  end

  def test_close_fill_and_stroke_still_strokes_the_closing_edge
    ['b', 'b*'].each do |operator|
      built = build("0 0 1 RG 1 0 0 rg #{TRIANGLE} #{operator}")
      assert_equal true, built.paths[0].subpaths[0].closed, operator
      assert_equal 1, built.result[:faces], operator
      assert_equal 3, built.result[:edges], operator
      assert_includes stroked_segments(built), [[40.0, 30.0], [10.0, 10.0]]
    end
  end

  def test_even_odd_fill_with_two_unclosed_subpaths_builds_both
    built = build("0 g #{TRIANGLE} 60 10 m 90 10 l 90 30 l f*")
    assert_equal 2, built.paths[0].subpaths.length
    assert_equal 2, built.result[:faces]
    assert_equal 0, built.result[:edges]
    assert_equal [TRIANGLE_POINTS, [[60.0, 10.0], [90.0, 10.0], [90.0, 30.0]]],
                 face_loops(built)
    assert_equal [['PDF Fill', 'PDF source fill']], faces(built).map(&:last).uniq,
                 'one paint occurrence keeps one source-fill container'
  end

  def test_unclosed_and_explicitly_closed_fills_build_the_same_faces
    shapes = {
      'triangle' => ['10 10 m 40 10 l 40 30 l', nil],
      'ring' => ['10 10 m 90 10 l 90 90 l 10 90 l', '30 30 m 30 70 l 70 70 l 70 30 l'],
      'repeated start' => ['10 10 m 40 10 l 40 30 l 10 10 l', nil]
    }
    ['f', 'F', 'f*'].each do |operator|
      shapes.each do |name, subpaths|
        open_stream = subpaths.compact.join(' ') + " #{operator}"
        closed_stream = subpaths.compact.map { |subpath| subpath + ' h' }.join(' ') + " #{operator}"
        open_built = build('0 g ' + open_stream)
        closed_built = build('0 g ' + closed_stream)
        assert_equal face_loops(closed_built), face_loops(open_built), "#{name} #{operator}"
        assert_equal closed_built.result[:faces], open_built.result[:faces], "#{name} #{operator}"
        assert_equal subpaths.compact.length, open_built.result[:faces], "#{name} #{operator}"
        assert_equal 0, open_built.result[:edges]
      end
    end
  end

  def test_explicitly_closed_behaviour_is_unchanged
    closed = build("0 0 1 RG 1 0 0 rg #{TRIANGLE} h f")
    assert_equal true, closed.paths[0].subpaths[0].closed
    assert_equal 1, closed.result[:faces]
    assert_equal 0, closed.result[:edges]
    assert_equal [TRIANGLE_POINTS], face_loops(closed)

    rectangle = build('0 g 10 10 30 20 re f')
    assert_equal 1, rectangle.result[:faces]
    assert_equal [[[10.0, 10.0], [40.0, 10.0], [40.0, 30.0], [10.0, 30.0]]], face_loops(rectangle)

    stroked_closed = build("0 0 1 RG #{TRIANGLE} s")
    assert_equal 0, stroked_closed.result[:faces]
    assert_equal 3, stroked_closed.result[:edges]
  end

  def test_stroke_only_open_path_is_unchanged
    built = build("0 0 1 RG 1 0 0 rg #{TRIANGLE} S")
    assert_equal 0, built.result[:faces]
    assert_equal 2, built.result[:edges]
    assert_empty faces(built)
    assert_empty groups(built), 'a stroke never creates a fill container'
  end

  def test_unclosed_curved_disc_builds_one_face_without_a_repeated_vertex
    k = 5.522847
    disc = "60 50 m 60 #{50 + k} #{50 + k} 60 50 60 c " \
           "#{50 - k} 60 40 #{50 + k} 40 50 c " \
           "40 #{50 - k} #{50 - k} 40 50 40 c " \
           "#{50 + k} 40 60 #{50 - k} 60 50 c"
    built = build("0 g #{disc} f", :detect_arcs => true)
    assert_equal false, built.paths[0].subpaths[0].closed
    assert_equal 1, built.result[:faces]
    assert_equal 0, built.result[:edges]
    assert_equal 0, built.result[:arcs], 'a filled boundary is never refitted to arcs'
    loop = face_loops(built).first
    assert_operator loop.length, :>, 8
    assert_equal loop.length, loop.uniq.length, 'the returning end point is not a second vertex'
    xs = loop.map(&:first)
    ys = loop.map(&:last)
    assert_in_delta 40.0, xs.min, 1.0e-3
    assert_in_delta 60.0, xs.max, 1.0e-3
    assert_in_delta 40.0, ys.min, 1.0e-3
    assert_in_delta 60.0, ys.max, 1.0e-3
  end

  def test_degenerate_fills_build_nothing_and_report_nothing
    {
      'two points' => '10 10 m 40 10 l f',
      'two points even-odd' => '10 10 m 40 10 l f*',
      'one point' => '10 10 m f',
      'collinear' => '10 10 m 40 10 l 70 10 l f',
      'out and back' => '10 10 m 40 10 l 10 10 l f',
      'repeated point' => '10 10 m 10 10 l 10 10 l F'
    }.each do |name, stream|
      assert_no_new_diagnostics do
        built = build('0 g ' + stream, :group_per_page => true)
        assert_equal 0, built.result[:faces], name
        assert_equal 0, built.result[:edges], name
        assert_empty faces(built), name
        assert_empty built.builder.fill_only_groups, "#{name}: no dead fill record"
        assert_empty groups(built).select { |group, trail| trail.include?('PDF Fill') || group.name == 'PDF Fill' },
                     "#{name}: no empty fill container survives the build"
      end
    end
  end

  def test_degenerate_fill_and_stroke_keeps_its_stroke_only
    assert_no_new_diagnostics do
      built = build('0 0 1 RG 1 0 0 rg 10 10 m 40 10 l B')
      assert_equal 0, built.result[:faces]
      assert_equal 1, built.result[:edges]
      assert_equal [[[10.0, 10.0], [40.0, 10.0]]], stroked_segments(built)
      assert_empty built.builder.fill_only_groups
    end
  end

  def test_a_degenerate_subpath_does_not_block_its_fillable_neighbour
    assert_no_new_diagnostics do
      built = build("0 g 100 10 m 130 10 l #{TRIANGLE} f")
      assert_equal 1, built.result[:faces]
      assert_equal [TRIANGLE_POINTS], face_loops(built)
    end
  end

  def test_import_fills_off_builds_no_face_for_an_unclosed_fill
    built = build("0 0 1 RG 1 0 0 rg #{TRIANGLE} B", :import_fills => false)
    assert_equal 0, built.result[:faces]
    assert_equal 2, built.result[:edges]
    assert_empty faces(built)
  end

  def test_clipped_stroke_of_an_unclosed_filled_contour_gains_no_closing_edge
    # The contour leaves the 100 pt high page: the stroke is trimmed to the
    # visible centerlines and the fill is still built from the source loop.
    built = build('0 0 1 RG 1 0 0 rg 10 10 m 40 10 l 40 130 l B', :merge_tolerance => 0)
    assert_equal 1, built.result[:faces]
    assert_equal [[[10.0, 10.0], [40.0, 10.0]], [[40.0, 10.0], [40.0, 100.0]]],
                 stroked_segments(built)
    assert_equal [[[10.0, 10.0], [40.0, 10.0], [40.0, 130.0]]], face_loops(built)
  end

  def test_sub_tolerance_unclosed_fill_uses_the_exact_scaled_instance_route
    built = build('0 g 10 10 m 10.12 10 l 10.12 10.12 l 10 10.12 l f',
                  :model => Model.new(true))
    assert_equal 1, built.result[:faces]
    assert_equal 1, built.model.definitions.items.length
    assert_equal 1, built.model.definitions.items.first.entities.faces_created
    assert built.model.definitions.items.first.entities.to_a.grep(Host::Face).
      flat_map(&:edges).all?(&:hidden)
  end

  def test_heavy_page_builds_every_unclosed_fill
    count = Builder::GEOMETRY_STAGING_PATH_THRESHOLD + 20
    stream = '0 g ' + count.times.map do |index|
      x = (index % 20) * 9
      y = (index / 20) * 3
      "#{x} #{y} m #{x + 6} #{y} l #{x + 6} #{y + 2} l f"
    end.join(' ')
    built = build(stream)
    assert_equal count, built.paths.length
    assert_equal true, built.result[:geometry_staging][:enabled]
    assert_equal count, built.result[:faces]
    assert_equal 0, built.result[:edges]
    assert_equal count, built.builder.fill_only_groups.length
  end
end
