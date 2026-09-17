require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_region_boundary'

class SvgRegionBoundaryTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary
  def rect(x0, y0, x1, y1)
    [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
  end
  def svg(loops, rule = :nonzero)
    Subject.normalize([{ :loops => loops, :fill_rule => rule }], :svg)
  end
  def areas(loops)
    loops.map { |loop| Subject.signed_area2(loop) * 0.5 }
  end
  def native(*faces)
    Subject.normalize(faces.map { |loops| { :loops => loops } }, :native_union)
  end

  def test_adjacent_rectangles_cancel_only_shared_seam_into_one_stepped_boundary
    lower, upper = rect(0, 0, 4, 2), rect(1, 2, 3, 3)
    source = svg([lower.reverse, upper.reverse])
    physical = native([[[0, 0, 0], [4, 0, 0], [4, 2, 0], [3, 2, 0],
                        [3, 3, 0], [1, 3, 0], [1, 2, 0], [0, 2, 0]]])
    assert_equal physical, source
    assert_equal [10.0], areas(source)
    assert_equal 8, source[0].length
  end

  def test_nonzero_nested_same_direction_is_full_but_opposite_direction_is_hole
    outer, inner = rect(0, 0, 4, 4), rect(1, 1, 3, 3)
    assert_equal [16.0], areas(svg([outer, inner]))
    assert_equal [16.0, -4.0], areas(svg([outer, inner.reverse]))
    assert_equal [16.0, -4.0], areas(svg([outer, inner], :evenodd))
    assert_equal [16.0, -4.0], areas(svg([outer, inner.reverse], :evenodd))
  end

  def test_native_holes_ignore_winding_and_face_union_can_fill_a_counter
    outer, inner = rect(0, 0, 4, 4), rect(1, 1, 3, 3)
    assert_equal [16.0, -4.0], areas(native([outer.reverse, inner.reverse]))
    assert_equal [16.0], areas(native([outer, inner], [inner]))
  end

  def test_crossing_nonzero_rectangles_are_union_and_evenodd_preserves_overlap_exclusion
    first, second = rect(0, 0, 3, 2), rect(2, -1, 4, 3)
    assert_equal [12.0], areas(svg([first, second]))
    # This XOR arrangement has point-touching components; reject the branching
    # graph rather than inventing how loops should be joined at those vertices.
    assert_nil svg([first, second], :evenodd)
  end

  def test_duplicate_source_contours_keep_winding_multiplicity_before_boundary_deduplication
    loop = rect(0, 0, 2, 2)
    assert_equal [4.0], areas(svg([loop, loop]))
    assert_equal [], svg([loop, loop], :evenodd)
    assert_equal [], svg([loop, loop.reverse])
  end

  def test_tiny_counter_is_preserved_without_geometry_tolerance
    outer = rect(0.0, 0.0, 1.0, 1.0)
    inner = rect(0.25, 0.25, 0.25000000001, 0.25000000002)
    boundary = svg([outer, inner.reverse])
    assert_equal 2, boundary.length
    assert_operator Subject.signed_area2(boundary[1]), :<, 0
    assert_equal inner.map(&:first).uniq.sort, boundary[1].map(&:first).uniq.sort
  end

  def test_disjoint_components_and_hole_count_remain_distinct
    result = svg([rect(0, 0, 5, 5), rect(1, 1, 2, 2).reverse, rect(8, 0, 9, 1)])
    assert_equal [25.0, 1.0, -1.0], areas(result)
    assert_nil svg([rect(0, 0, 1, 1), rect(1, 1, 2, 2)])
  end

  def test_diagonal_intersections_use_exact_predicates_and_preserve_area
    triangle = [[0, 0, 0], [4, 0, 0], [0, 4, 0]]
    result = svg([triangle, rect(1, 1, 3, 3)])
    assert_equal 1, result.length
    assert_in_delta 10.0, areas(result)[0], 1.0e-12
  end

  def test_normalization_does_not_mutate_source_coordinates
    loop = rect(0.02, 0.01, 8.04, 0.51)
    upper = rect(1.01, 0.51, 7.03, 0.58)
    regions = [{ :loops => [loop, upper], :fill_rule => :nonzero }]
    before = Marshal.dump(regions)
    result = Subject.normalize(regions, :svg)
    assert_equal before, Marshal.dump(regions)
    assert_equal 1, result.length
    assert_in_delta 4.4314, areas(result)[0], 1.0e-12
  end

  def test_unknown_rule_nonplanar_or_malformed_points_fail_closed
    assert_nil svg([rect(0, 0, 1, 1)], :unknown)
    assert_nil Subject.normalize([{ :loops => [[[0, 0, 1], [1, 0, 1], [0, 1, 1]]] }], :native_union)
    assert_nil svg([[[0, 0, 0], [Float::NAN, 0, 0], [1, 1, 0]]])
    assert_nil svg([[[0, 0, 0], [1, 1, 0]]])
  end
end
