require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/planar_region_partition'

class PlanarRegionPartitionTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
  Boundary = BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary

  def rect(x0, y0, x1, y1)
    [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
  end

  def face(*loops); { :loops => loops }; end

  def area(cells, region)
    cells.select { |cell| cell[:region] == region }.inject(0.to_r) { |sum, cell| sum + cell[:area] }
  end

  def assert_partition(white, ink, expected_white, expected_ink)
    before = Marshal.dump([white, ink])
    cells = Subject.partition(white, ink)
    assert_equal expected_white, area(cells, :white)
    assert_equal expected_ink, area(cells, :ink)
    assert_equal before, Marshal.dump([white, ink])
    cells.each do |cell|
      loop = cell[:loop]
      assert_includes [3, 4], loop.length
      assert_equal loop.length, loop.uniq.length
      assert loop.flatten.all? { |value| value.is_a?(Rational) }
      assert_operator cell[:area], :>, 0
      assert_equal cell[:area] * 2, Boundary.signed_area2(loop)
      # Convex cells have no reentrant corner and need no host subdivision.
      loop.each_index do |i|
        a, b, c = loop[i], loop[(i + 1) % loop.length], loop[(i + 2) % loop.length]
        cross = (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
        assert_operator cross, :>, 0
      end
    end
    cells
  end

  def test_vertical_boundaries_overlapping_ink_and_clipping_to_white
    white = [face(rect(0, 0, 4, 4))]
    ink = [face(rect(1, 1, 3, 3)), face(rect(2, 1, 5, 3))]
    assert_partition(white, ink, 10, 6)
  end

  def test_white_holes_and_ink_counters_remain_open
    white = [face(rect(0, 0, 6, 6), rect(2, 2, 4, 4))]
    ink = [face(rect(1, 1, 5, 5), rect(2, 2, 4, 4))]
    assert_partition(white, ink, 20, 12)
    assert_partition([face(rect(0, 0, 4, 4))],
                     [face(rect(1, 1, 3, 3), rect(Rational(3,2), Rational(3,2), Rational(5,2), Rational(5,2)))],
                     13, 3)
  end

  def test_concave_white_and_crossing_diagonals_add_nonvertex_x_cuts
    white = [face([[0,0,0], [4,0,0], [4,1,0], [1,1,0], [1,4,0], [0,4,0]])]
    assert_partition(white, [face(rect(Rational(1,2), Rational(1,2), 3, 3))],
                     Rational(19,4), Rational(9,4))
    # Two triangles cross at (2,2); 2 is not a source vertex x.
    white = [face(rect(0, 0, 4, 4))]
    ink = [face([[0,0,0], [4,0,0], [0,4,0]]),
           face([[0,0,0], [4,0,0], [4,4,0]])]
    cells = assert_partition(white, ink, 4, 12)
    assert_includes cells.flat_map { |cell| cell[:loop].map(&:first) }, 2.to_r
  end

  def test_coincident_partial_collinear_and_point_touching_edges
    white = [face(rect(0, 0, 2, 2)), face(rect(2, 2, 4, 4))]
    ink = [face(rect(0, 0, 1, 2)), face(rect(0, 0, 1, 2).reverse),
           face(rect(1, 0, 2, 1))]
    assert_partition(white, ink, 5, 3)
    assert_partition([face(rect(0, 0, 4, 4))], [face(rect(0, 0, 4, 4))], 0, 16)
  end

  def test_nonzero_near_parallel_sliver_is_never_discarded
    epsilon = Rational(1, 10**30)
    white = [face(rect(0, 0, 1, 1))]
    ink = [face([[0,0,0], [1,0,0], [1,epsilon*2,0], [0,epsilon,0]])]
    assert_partition(white, ink, 1-epsilon*Rational(3,2), epsilon*Rational(3,2))
  end

  def test_affine_shear_reflection_translation_and_loop_order_preserve_regions
    white = [face(rect(0, 0, 4, 4))]
    ink = [face(rect(1, 1, 3, 3), rect(Rational(3,2), Rational(3,2), Rational(5,2), Rational(5,2)))]
    # Determinant -7 changes winding, with neither axis aligned afterward.
    change = lambda do |records|
      records.reverse.map do |record|
        face(*record[:loops].map do |loop|
          loop.reverse.map { |p| [2*p[0]+p[1]+1000, p[0]-3*p[1]-2000, 0] }
        end)
      end
    end
    assert_partition(change.call(white), change.call(ink), 91, 21)
  end

  def test_classification_matches_analytic_l_shape_with_inset_rectangle
    white = [face([[0,0,0], [4,0,0], [4,1,0], [1,1,0], [1,4,0], [0,4,0]])]
    ink = [face(rect(Rational(1,2), Rational(1,2), 3, 3))]
    cells = Subject.partition(white, ink)
    (0...16).each do |x|
      (0...16).each do |y|
        point = [Rational(x,4)+Rational(1,31), Rational(y,4)+Rational(1,37)]
        in_white = point[0] < 1 || point[1] < 1
        in_ink = point[0] > Rational(1,2) && point[0] < 3 &&
                 point[1] > Rational(1,2) && point[1] < 3
        # An independent convex half-plane test checks both coverage and
        # interior disjointness; it does not reuse the production fill oracle.
        hits = cells.select do |cell|
          loop = cell[:loop]
          loop.each_index.all? do |i|
            a, b = loop[i], loop[(i+1)%loop.length]
            (b[0]-a[0])*(point[1]-a[1]) - (b[1]-a[1])*(point[0]-a[0]) > 0
          end
        end
        assert_equal(in_white ? 1 : 0, hits.length)
        assert_equal(in_ink ? :ink : :white, hits.first[:region]) if in_white
      end
    end
  end

  def test_every_budget_fails_explicitly_and_inputs_stay_unchanged
    white = [face(rect(0, 0, 4, 4))]
    ink = [face(rect(1, 1, 3, 3))]
    before = Marshal.dump([white, ink])
    [:input_edges, :atomic_edges, :slabs, :cells, :predicate_edges].each do |key|
      error = assert_raises(Subject::Error) { Subject.partition(white, ink, key => 1) }
      assert_match(/budget/, error.message)
    end
    assert_equal before, Marshal.dump([white, ink])
  end

  def test_invalid_nonfinite_and_nonplanar_contours_fail_closed
    [Float::NAN, Float::INFINITY, '1'].each do |bad|
      assert_raises(Subject::Error) { Subject.partition([face([[0,0,0], [bad,0,0], [0,1,0]])], []) }
    end
    assert_raises(Subject::Error) { Subject.partition([face([[0,0,1], [1,0,1], [0,1,1]])], []) }
    assert_raises(Subject::Error) { Subject.partition([face([[0,0,0], [1,0,0]])], []) }
  end
end

