require 'minitest/autorun'

module Geom
  Point3d = Struct.new(:x, :y, :z)
  Vector3d = Struct.new(:x, :y, :z)
  class Transformation
    IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1].freeze
    def initialize(values = IDENTITY)
      @values = values.map(&:to_f)
    end
    def to_a; @values.dup; end
    def *(other)
      right = other.to_a
      self.class.new(Array.new(16) do |index|
        row, column = index % 4, index / 4
        (0..3).inject(0.0) do |sum, k|
          sum + @values[k * 4 + row] * right[column * 4 + k]
        end
      end)
    end
    def self.axes(origin, xaxis, yaxis, zaxis)
      new([xaxis.x, xaxis.y, xaxis.z, 0,
           yaxis.x, yaxis.y, yaxis.z, 0,
           zaxis.x, zaxis.y, zaxis.z, 0,
           origin.x, origin.y, origin.z, 1])
    end
  end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class PageRepresentationTransformTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  class Group
    attr_accessor :transformation, :wrong_placement
    attr_reader :calls
    def initialize(values = Geom::Transformation::IDENTITY)
      @transformation = Geom::Transformation.new(values)
      @calls = 0
    end
    def transform!(value)
      @calls += 1
      @transformation = value * @transformation
      if @wrong_placement
        changed = @transformation.to_a
        changed[12] += 0.0001
        @transformation = Geom::Transformation.new(changed)
      end
    end
  end

  def geometry_evidence
    { :mode => :geometry, :source_extent => [2.5, 3.75, 5.0, 6.0],
      :source_construction_transformation =>
        [0.001, 0, 0, 0, 0, 0.001, 0, 0, 0, 0, 0.001, 0, 2.5, 3.75, 0, 1] }
  end

  def apply(group, evidence, rotation = 0, offset = 0)
    Importer.apply_and_verify_page_representation_transform(
      group, [0, 0, 3456, 2592], 2.0, rotation, offset, evidence
    )
  end

  def point(matrix, values)
    (0..2).map do |axis|
      values[0] * matrix[axis] + values[1] * matrix[axis + 4] +
        values[2] * matrix[axis + 8] + matrix[axis + 12]
    end
  end

  def test_safe_construction_preserves_source_points_under_all_page_rotations_and_stack_offsets
    expected = { 0 => [3.0, 4.0], 90 => [4.0, 93.0],
                 180 => [93.0, 68.0], 270 => [68.0, 3.0] }
    expected.each do |rotation, xy|
      evidence = geometry_evidence
      group = Group.new(evidence[:source_construction_transformation])
      assert apply(group, evidence, rotation, 7.0)
      world = point(group.transformation.to_a, [500, 250, 0])
      assert_in_delta xy[0], world[0], 1.0e-12
      assert_in_delta xy[1] + 7.0, world[1], 1.0e-12
      assert_in_delta 0.0, world[2], 1.0e-12
      # Bounds evidence acts on original source inches, not 1000x construction.
      source = point(evidence[:source_page_transformation], [3.0, 4.0, 0])
      assert_equal source, world
      assert evidence[:page_transform_verified]
    end
  end

  def test_ordinary_modes_still_require_identity_before_page_placement
    [:text, :labels, :text3d, :glyphs, :raster].each do |mode|
      evidence = { :mode => mode }
      assert apply(Group.new, evidence, 90, 12)
      wrong = Geom::Transformation::IDENTITY.dup
      wrong[12] = 0.01
      refute apply(Group.new(wrong), { :mode => mode }, 90, 12)
    end
  end

  def test_wrong_preexisting_geometry_transform_is_rejected_before_mutation
    evidence = geometry_evidence
    wrong = evidence[:source_construction_transformation].dup
    wrong[12] += 0.0001
    group = Group.new(wrong)
    refute apply(group, evidence)
    assert_equal 0, group.calls
    refute evidence[:page_transform_verified]
  end

  def test_unapproved_constructor_scale_mode_origin_and_nonfinite_values_are_rejected
    variants = []
    evidence = geometry_evidence
    evidence[:source_construction_transformation][0] = 0.002
    variants << evidence
    evidence = geometry_evidence
    evidence[:mode] = :glyphs
    variants << evidence
    evidence = geometry_evidence
    evidence[:source_extent][0] = 5.0
    variants << evidence
    evidence = geometry_evidence
    evidence[:source_construction_transformation][12] = Float::NAN
    variants << evidence
    variants.each do |candidate|
      group = Group.new(candidate[:source_construction_transformation])
      refute apply(group, candidate)
      assert_equal 0, group.calls
    end
  end

  def test_host_misplacement_after_transform_is_not_certified
    evidence = geometry_evidence
    group = Group.new(evidence[:source_construction_transformation])
    group.wrong_placement = true
    refute apply(group, evidence, 270, 7)
    refute evidence[:page_transform_verified]
  end
end
