require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'

class CompoundFillClosedContourTest < Minitest::Test
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder
  Point = Struct.new(:x, :y, :z) do
    def distance(other)
      Math.sqrt((x-other.x)**2 + (y-other.y)**2 + (z-other.z)**2)
    end
  end

  def setup
    @builder = Builder.allocate
    @builder.instance_variable_set(:@merge_tol, 0.0005)
  end

  def points(values)
    values.map { |x,y| Point.new(x,y,0.0) }
  end

  def clean(loop)
    @builder.send(:compound_fill_loop, loop)
  end

  def test_explicit_closure_is_removed_without_changing_vertices_or_winding
    original = points([[0,0],[8,0],[8,4],[10,5],[8,6],[8,10],[0,10],[0,0]])
    before = original.map(&:dup)
    result = clean(original)
    assert_equal original[0...-1], result
    assert_equal before, original, 'source contours remain immutable'
    [[1,1],[9,5],[9,2]].each do |xy|
      point=Point.new(xy[0],xy[1],0)
      assert_equal Builder.contour_winding(point,[original]), Builder.contour_winding(point,[result])
    end
  end

  def test_near_closure_is_real_geometry_not_an_exact_duplicate
    loop=points([[0,0],[10,0],[10,10],[0,10],[0,0.00001]])
    assert_equal loop, clean(loop)
  end

  def test_repeated_interior_vertex_is_not_globally_deduplicated
    loop=points([[0,0],[10,0],[5,5],[10,10],[0,10],[5,5],[0,0]])
    assert_equal loop[0...-1], clean(loop)
    assert_equal 2, clean(loop).count { |p| p.x==5 && p.y==5 }
  end

  def test_open_contour_is_unchanged_and_returns_an_independent_array
    loop=points([[0,0],[10,0],[10,10],[0,10]])
    assert_equal loop,clean(loop)
    refute_same loop,clean(loop)
  end

  def test_clipping_roundoff_is_coalesced_even_with_zero_merge_tolerance
    @builder.instance_variable_set(:@merge_tol,0.0)
    [0.000001,1.0,1000000.0].each do |scale|
      values=[[37.686666666666675,31.374998888888882],
        [37.686666666666675,31.281666666666666],
        [38.66,31.28333333333333],[38.66,31.28333333333334],
        [38.568334444444446,31.374998888888882]]
      original=points(values.map { |x,y| [x*scale,y*scale] })
      before=original.map(&:dup)
      assert_equal original.values_at(0,1,2,4),clean(original)
      assert_equal before,original
    end
  end

  def test_roundoff_bound_does_not_become_a_host_geometry_tolerance
    @builder.instance_variable_set(:@merge_tol,0.0)
    [0.000001,1.0,1000000.0].each do |scale|
      original=points([[0,0],[38.66*scale,31.28333333333333*scale],
        [38.66*scale,(31.28333333333333+0.000000000001)*scale],[0,40*scale]])
      assert_equal original,clean(original)
    end
    near_origin=points([[0,0],[0.000000000000000001,0],[1,1]])
    assert_equal near_origin,clean(near_origin)
  end

  def test_nonfinite_coordinates_are_not_certified_as_numerical_duplicates
    [Float::INFINITY,-Float::INFINITY,Float::NAN].each do |value|
      refute @builder.send(:same_roundoff_point?,Point.new(value,0,0),Point.new(value,0,0))
    end
  end

  def test_clipped_apex_with_six_ulp_roundoff_is_coalesced
    @builder.instance_variable_set(:@merge_tol,0.0)
    loop=points([[0,0],[8,3.0],[8,3.000000000000003],[10,10]])
    assert_equal loop.values_at(0,1,3),clean(loop)
    real_edge=points([[0,0],[8,3.0],[8,3.00000000000002],[10,10]])
    assert_equal real_edge,clean(real_edge)
  end
end
