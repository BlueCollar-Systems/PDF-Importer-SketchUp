#!/usr/bin/env ruby
# The white-mask pass returns early when every text root is solid 3D text.
#
# compose_page_white_masks! ran on every page: it re-parsed the page SVG and
# walked every face of every text root even when all of them were
# positive-depth 3D Text, which collect_text_faces then dropped whole. With
# no flat text left, no page fill can be cut, whatever its colour.
#
# All entities here are made-up stand-ins for SketchUp objects.

require 'minitest/autorun'
require 'minitest/mock'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0); @x, @y, @z = x.to_f, y.to_f, z.to_f; end
    def transform(t); t.point(self); end
  end
  class Transformation
    attr_reader :dz
    def initialize(dz = 0.0); @dz = dz.to_f; end
    def *(other); Transformation.new(dz + other.dz); end
    def point(p); Point3d.new(p.x, p.y, p.z + dz); end
  end
end unless defined?(Geom::Transformation)

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class WhiteMaskSolidTextSkipTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  PWK = IMP::PlanarWhiteKnockout

  class Reads
    attr_accessor :count
    def initialize; @count = 0; end
  end

  class Vertex
    def initialize(point, reads); @point, @reads = point, reads; end
    def position; @reads.count += 1; @point; end
  end
  Loop = Struct.new(:vertices)

  class Face
    attr_reader :loops
    def initialize(points, reads)
      @loops = [Loop.new(points.map { |p| Vertex.new(Geom::Point3d.new(*p), reads) })]
    end
    def typename; 'Face'; end
    def valid?; true; end
    def outer_loop; @loops.first; end
    def material; nil; end
    def back_material; nil; end
    def layer; nil; end
    def get_attribute(_d, _k, default); default; end
  end

  class Group
    attr_reader :entities, :transformation
    def initialize(children, attributes = {}, transformation = Geom::Transformation.new)
      @entities, @attributes, @transformation = children, attributes, transformation
    end
    def typename; 'Group'; end
    def valid?; true; end
    def entityID; object_id; end
    def material; nil; end
    def get_attribute(_d, key, default); @attributes.fetch(key, default); end
  end

  class Image
    def typename; 'Image'; end
    def valid?; true; end
    def transformation; Geom::Transformation.new; end
    def get_attribute(_d, _k, default); default; end
  end

  Builder = Struct.new(:fill_only_groups, :page_group)

  def square(z, size = 1.0)
    [[0, 0, z], [size, 0, z], [size, size, z], [0, size, z]]
  end

  # One 3D text span: bottom on the page, top at depth, four sides.
  def solid_span(reads, depth = 0.05)
    faces = [Face.new(square(0.0), reads), Face.new(square(depth), reads)]
    4.times { faces << Face.new([[0, 0, 0], [1, 0, 0], [1, 0, depth], [0, 0, depth]], reads) }
    glyph = Group.new(faces)
    Group.new([glyph], 'source_span_id' => 'text_span:1:0')
  end

  def flat_span(reads)
    Group.new([Face.new(square(0.0), reads)], 'source_span_id' => 'text_span:1:1')
  end

  def context_for(builder, roots)
    { :page_group => builder.page_group, :masks => builder.fill_only_groups,
      :highest_text_z => 0.05,
      :roots => roots.map { |group| { :group => group, :transformation => group.transformation,
                                      :parent_transform => Geom::Transformation.new,
                                      :verified_source_unit => false } } }
  end

  def compose(roots, masks = [])
    builder = Builder.new(masks, Group.new([]))
    svg_reads = 0
    provider = lambda { svg_reads += 1; { :svg => '<svg viewBox="0 0 10 10"></svg>' } }
    inventory = { :white_paths => [], :opaque_paths => [], :glyphs => [] }
    result = IMP::SvgPaintOrder.stub(:build, inventory) do
      IMP.stub(:page_representation_transform, Geom::Transformation.new) do
        IMP.compose_page_white_masks!(builder, [], [0, 0, 720, 720],
          :composition_inventory => context_for(builder, roots), :svg_provider => provider,
          :source_units => [], :page_number => 1)
      end
    end
    [result, svg_reads]
  end

  def test_all_solid_text_returns_without_reading_the_svg_or_walking_every_face
    reads = Reads.new
    roots = Array.new(20) { solid_span(reads) }
    total_vertices = 20 * 6 * 4
    result, svg_reads = compose(roots, [{ :group => Group.new([]), :fill_rgb => [0, 0, 0] }])
    assert_equal 0, svg_reads, 'the page SVG must not be parsed again'
    assert_operator reads.count, :<=, 20 * 8, 'only the first off-plane face of each span is read'
    assert_operator reads.count, :<, total_vertices
    assert_equal [], result[:final_page_crops]
    assert_equal 0.05, result[:highest_text_z]
    report = result[:report]
    assert_equal 'no_flat_text', report[:skipped]
    assert_equal 20, report[:solid_text_roots]
    assert_equal [0, 0, 0], report.values_at(:composed_groups, :failed_groups, :ink_faces)
    assert_equal PWK.empty_result(0).keys.sort, (report.keys - [:skipped, :solid_text_roots, :source_masks]).sort
  end

  def test_flat_text_still_gets_the_full_pass
    reads = Reads.new
    _result, svg_reads = compose([solid_span(reads), flat_span(reads)])
    assert_equal 1, svg_reads, 'flat glyph text still needs the source paint order'
  end

  def test_picture_roots_still_get_the_pass_without_the_svg
    reads = Reads.new
    calls = 0
    prepare = lambda do |masks, roots, inventory, _opts|
      calls += 1
      assert_equal 1, roots.length, 'solid text is left out of the face walk'
      assert_equal 'Image', roots.first[:group].typename
      assert_empty inventory[:glyphs]
      { :masks => [], :ink_faces => [], :binding => {} }
    end
    result, svg_reads = IMP::SvgPaintBinding.stub(:prepare, prepare) do
      compose([solid_span(reads), Image.new])
    end
    assert_equal 1, calls
    assert_equal 0, svg_reads
    assert_equal 1, result[:report][:solid_text_roots]
  end

  def test_solid_root_detection
    reads = Reads.new
    assert PWK.solid_text_root?(:group => solid_span(reads))
    refute PWK.solid_text_root?(:group => flat_span(reads))
    refute PWK.solid_text_root?(:group => Image.new)
    unowned = Group.new([Face.new(square(0.3), reads)])
    refute PWK.solid_text_root?(:group => unowned), 'unowned faces are not text ink'
    assert PWK.solid_text_root?(:group => unowned, :verified_source_unit => true)
    lifted = Group.new([Face.new(square(0.0), reads)], { 'source_span_id' => 'text_span:1:2' },
                       Geom::Transformation.new(0.2))
    assert PWK.solid_text_root?(:group => lifted), 'the root transform is applied'
    refute PWK.solid_text_root?(:group => Object.new)
  end
end
