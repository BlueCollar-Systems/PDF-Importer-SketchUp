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
end
