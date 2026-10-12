require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/planar_region_partition'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class PlanarPartitionPerformanceTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
  Boundary = BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary
  Cancelled = BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled

  class Controller
    attr_reader :calls
    def initialize(error, stage, minimum)
      @error = error
      @stage = stage
      @minimum = minimum
      @calls = []
    end
    def checkpoint!(stage, detail)
      @calls << [stage, detail]
      raise @error if stage == @stage && detail[:completed] >= @minimum
    end
  end

  def rect(x0, y0, x1, y1)
    [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
  end

  def face(*loops); { :loops => loops }; end

  def area(cells, region)
    cells.select { |cell| cell[:region] == region }.inject(0.to_r) { |sum, cell| sum + cell[:area] }
  end

  def independent_hits(cells, point)
    cells.select do |cell|
      loop = cell[:loop]
      loop.each_index.all? do |index|
        a, b = loop[index], loop[(index + 1) % loop.length]
        (b[0]-a[0])*(point[1]-a[1]) - (b[1]-a[1])*(point[0]-a[0]) > 0
      end
    end
  end

  def test_ink_outside_white_is_not_sent_to_intersection_arrangement
    white = [face(rect(0, 0, 1, 1))]
    ink = (1..100).map do |i|
      face(rect(Rational(i, 101), 2, Rational(i, 101)+Rational(1, 10000), 3))
    end
    before = Marshal.dump([white, ink])
    original = Boundary.method(:split_edges)
    edge_counts = []
    Boundary.stub(:split_edges, lambda { |edges, opts = {}|
      edge_counts << edges.length
      original.arity == 1 ? original.call(edges) : original.call(edges, opts)
    }) do
      cells = Subject.partition(white, ink)
      assert_equal [4], edge_counts
      assert_equal 1, cells.length
      assert_equal 1, area(cells, :white)
      assert_equal 0, area(cells, :ink)
    end
    assert_equal before, Marshal.dump([white, ink])
  end

  def test_clipping_keeps_surrounding_ink_and_its_outside_counter_in_the_fill_oracle
    white = [face(rect(0, 0, 1, 1))]
    cells = Subject.partition(white, [face(rect(-10, -10, 10, 10))])
    assert_equal 1, cells.length
    assert_equal 1, area(cells, :ink)
    cells = Subject.partition(white, [face(rect(-10, -10, 10, 10), rect(-2, -2, 2, 2))])
    assert_equal 1, cells.length
    assert_equal 1, area(cells, :white)
    assert_equal 0, area(cells, :ink)
  end

  def test_exact_clip_retains_rational_intersections_and_arbitrarily_thin_source_sliver
    tiny = Rational(1, 10**30)
    edge = [[-1.to_r, -tiny], [2.to_r, tiny*2]]
    assert_equal [[0.to_r, 0.to_r], [1.to_r, tiny]],
                 Subject.clip_edge_to_bounds(edge, [0.to_r, 0.to_r, 1.to_r, 1.to_r])
    white = [face(rect(0, 0, 1, 1))]
    ink = [face([[-1, -tiny, 0], [2, tiny*2, 0], [2, tiny*4, 0], [-1, tiny, 0]])]
    cells = Subject.partition(white, ink)
    assert_equal 1-tiny*2, area(cells, :white)
    assert_equal tiny*2, area(cells, :ink)
    assert cells.all? { |cell| cell[:loop].flatten.all? { |v| v.is_a?(Rational) } }
  end

  def test_disjoint_glyph_boxes_retain_exact_area_and_independent_point_coverage
    white = [face(rect(0, 0, 80, 1))]
    ink = (0...45).map do |i|
      face(rect(Rational(i*3+1, 2), Rational(1,5), Rational(i*3+2, 2), Rational(4,5)))
    end
    before = Marshal.dump([white, ink])
    cells = Subject.partition(white, ink)
    assert_equal Rational(133, 2), area(cells, :white)
    assert_equal Rational(27, 2), area(cells, :ink)
    (0...80).each do |x|
      [Rational(1,10), Rational(3,10), Rational(7,10), Rational(9,10)].each do |y|
        point = [x+Rational(1,7), y]
        covered = ink.any? do |record|
          r = record[:loops][0]
          point[0] > r[0][0] && point[0] < r[1][0] && y > r[0][1] && y < r[2][1]
        end
        hits = independent_hits(cells, point)
        assert_equal 1, hits.length
        assert_equal covered ? :ink : :white, hits[0][:region]
      end
    end
    assert_equal before, Marshal.dump([white, ink])
  end

  def test_overlapping_glyph_boxes_coalesce_interior_seams_without_changing_the_ink_union
    white = [face(rect(0, 0, 80, 1))]
    ink = (0...45).map do |i|
      face(rect(Rational(i,100), Rational(1,5), 70+Rational(i,100), Rational(4,5)))
    end
    cells = Subject.partition(white, ink)
    assert_equal 4, cells.length
    assert_equal Rational(4717,125), area(cells, :white)
    assert_equal Rational(5283,125), area(cells, :ink)
    [[Rational(167,5), Rational(1,2), :ink], [75, Rational(1,2), :white],
     [1, Rational(1,10), :white], [1, Rational(9,10), :white]].each do |x, y, expected|
      hits = independent_hits(cells, [x, y])
      assert_equal 1, hits.length
      assert_equal expected, hits.first[:region]
    end
  end

  def test_adjacent_and_overlapping_white_face_ownership_boundaries_are_preserved
    cells = Subject.partition([face(rect(0, 0, 1, 1)), face(rect(1, 0, 2, 1))], [])
    assert_equal 2, cells.length
    assert_equal [[0.to_r, 1.to_r], [1.to_r, 2.to_r]],
                 cells.map { |cell| cell[:loop].map(&:first).minmax }
    cells = Subject.partition([face(rect(0, 0, 2, 1)), face(rect(1, 0, 3, 1))], [])
    assert_equal 2, cells.length
    assert_equal [[0.to_r, 2.to_r], [2.to_r, 3.to_r]],
                 cells.map { |cell| cell[:loop].map(&:first).minmax }
  end

  def test_clipping_does_not_waive_validation_or_original_input_edge_budget
    white = [face(rect(0, 0, 1, 1))]
    invalid = [face([[10,10,0], [11,10,0], [Float::NAN,11,0]])]
    assert_raises(Subject::Error) { Subject.partition(white, invalid) }
    outside = [face(rect(10, 10, 11, 11))]
    error = assert_raises(Subject::Error) { Subject.partition(white, outside, :input_edges => 7) }
    assert_match(/input-edge budget/, error.message)
  end

  def test_intersections_poll_during_pair_work_and_propagate_the_original_cancellation
    edges = (0...40).map { |i| [[i.to_r, 0.to_r], [i.to_r, 1.to_r]] }
    before = Marshal.dump(edges)
    error = Cancelled.new([1], 2, {})
    controller = Controller.new(error, :white_mask_intersections, 256)
    actual = assert_raises(Cancelled) do
      Boundary.split_edges(edges, :run_controller => controller, :page_number => 2)
    end
    assert_same error, actual
    assert_equal 256, controller.calls.last[1][:completed]
    assert_equal 2, controller.calls.last[1][:page]
    assert_equal before, Marshal.dump(edges)
  end

  def test_normalization_polls_during_boundary_work_and_keeps_cancellation_distinct
    source = (0...24).map { |i| face(rect(i*2, 0, i*2+1, 1)) }
    before = Marshal.dump(source)
    error = Cancelled.new([], 3, {})
    controller = Controller.new(error, :white_mask_boundaries, 64)
    actual = assert_raises(Cancelled) do
      Boundary.normalize(source, :native_union, :run_controller => controller, :page_number => 3)
    end
    assert_same error, actual
    assert_equal 64, controller.calls.last[1][:completed]
    assert_equal 3, controller.calls.last[1][:page]
    assert_equal before, Marshal.dump(source)
  end

  def test_partition_polls_inside_the_slab_walk_and_keeps_inputs_unchanged_on_cancellation
    white = [face(rect(0, 0, 80, 1))]
    ink = (0...24).map { |i| face(rect(i*3+1, Rational(1,5), i*3+2, Rational(4,5))) }
    before = Marshal.dump([white, ink])
    error = Cancelled.new([1], 2, {})
    controller = Controller.new(error, :white_mask_partition, 16)
    actual = assert_raises(Cancelled) do
      Subject.partition(white, ink, :run_controller => controller, :page_number => 2)
    end
    assert_same error, actual
    assert_equal 16, controller.calls.last[1][:completed]
    assert_equal 2, controller.calls.last[1][:page]
    assert_equal before, Marshal.dump([white, ink])
  end
end
