require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/planar_white_knockout'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z); @x, @y, @z = x.to_f, y.to_f, z.to_f; end
    def transform(t); t.point(self); end
  end
  class Transformation
    attr_reader :scale, :offset
    def initialize(scale = 1.0, offset = [0, 0, 0]); @scale, @offset = scale, offset; end
    def self.translation(p); new(1.0, [p.x, p.y, p.z]); end
    def self.scaling(s); new(s); end
    def *(other)
      Transformation.new(scale * other.scale, offset.each_with_index.map { |v, i| v + scale * other.offset[i] })
    end
    def inverse; Transformation.new(1.0 / scale, offset.map { |v| -v / scale }); end
    def point(p); Point3d.new(*[p.x, p.y, p.z].each_with_index.map { |v, i| v * scale + offset[i] }); end
  end
end

module Sketchup
  class Face
    PointInside = 1
    PointOnFace = 2
    PointOutside = 3
  end
end

class PlanarWhiteKnockoutTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::PlanarWhiteKnockout
  ContractError = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError
  Vertex = Struct.new(:position)
  Loop = Struct.new(:vertices)
  Bounds = Struct.new(:min, :max)
  Normal = Struct.new(:z)

  class Mesh
    def initialize(points); @points = points; end
    def polygons; [[1, 2, 3], [1, 3, 4]]; end
    def point_at(i); @points[i - 1]; end
  end

  class Face
    attr_accessor :material, :back_material, :layer, :attributes
    attr_reader :loops, :erased
    def initialize(loops)
      @loops = loops.map { |points| Loop.new(points.map { |p| Vertex.new(Geom::Point3d.new(*p)) }) }
      @material, @back_material = :white, :white
      @erased = false
      @attributes = {}
    end
    def typename; 'Face'; end
    def outer_loop; loops.first; end
    def valid?; !@erased; end
    def erase!; @erased = true; end
    def normal; Normal.new(1); end
    def get_attribute(_dict, key, default); attributes.fetch(key, default); end
    def reverse!; end
    def raw; loops.map { |l| l.vertices.map { |v| [v.position.x, v.position.y, v.position.z] } }; end
    def bounds
      points = raw.flatten(1)
      Bounds.new(Geom::Point3d.new(*[0, 1, 2].map { |i| points.map { |p| p[i] }.min }),
                 Geom::Point3d.new(*[0, 1, 2].map { |i| points.map { |p| p[i] }.max }))
    end
    def mesh(_flags); Mesh.new(outer_loop.vertices.map(&:position)); end
    def area; Subject.source_area([Subject.face_record(raw)]); end
    def classify_point(point)
      Subject.contains?(Subject.face_record(raw), [point.x, point.y, point.z]) ?
        Sketchup::Face::PointInside : Sketchup::Face::PointOutside
    end
  end

  class Entities
    attr_reader :items, :erased, :added_points, :stage, :intersections
    attr_accessor :fail_add, :stage_faces
    def initialize(items = []); @items, @erased, @added_points = items, [], []; end
    def to_a; items.reject { |e| e.respond_to?(:valid?) && !e.valid? }; end
    def add_group
      @stage = Group.new(Entities.new(stage_faces || []))
      @stage.entities.fail_add = fail_add
      items << @stage
      @stage
    end
    def add_face(points)
      raise 'host construction failed' if fail_add
      added_points << points
      items.first
    end
    def erase_entities(list)
      @erased.concat(list)
      list.each(&:erase!)
    end
    def intersect_with(*args); @intersections = args; []; end
  end

  class Group
    attr_reader :entities, :erased
    attr_accessor :transformation, :name, :owner, :attributes
    def initialize(entities)
      @entities = entities
      @transformation = Geom::Transformation.new
      @owner = false
      @attributes = {}
    end
    def typename; 'Group'; end
    def valid?; !@erased; end
    def erase!; @erased = true; end
    def get_attribute(_dict, key, default)
      return 'text_span:1:84' if owner && key == 'source_span_id'
      attributes.fetch(key, default)
    end
    def set_attribute(_dict, key, value); attributes[key] = value; end
  end

  class CascadingEdge
    attr_accessor :hidden, :on_erase, :on_find
    def initialize(attached = false); @valid, @attached = true, attached; end
    def valid?; @valid; end
    def invalidate!; @valid = false; end
    def typename
      raise TypeError, 'reference to deleted Entity' unless valid?
      'Edge'
    end
    def faces; @attached ? [:retained_face] : []; end
    def erase!; invalidate!; on_erase.call if on_erase; end
    def find_faces; on_find.call if on_find; end
  end

  class Affine
    def initialize(values); @values = values; end
    def to_a; @values; end
    def point(p)
      Geom::Point3d.new(*[0, 1, 2].map do |i|
        p.x * @values[i] + p.y * @values[4 + i] + p.z * @values[8 + i] + @values[12 + i]
      end)
    end
  end

  class Image
    attr_accessor :attributes, :transformation, :width, :height, :bounds
    def typename; 'Image'; end
    def get_attribute(_dictionary, key, default); attributes.fetch(key, default); end
  end

  def rect(x0, y0, x1, y1, z = 0)
    [[x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z]]
  end

  def record(*loops); Subject.face_record(loops); end

  def test_actual_face_counter_and_concavity_survive_boolean_classification
    white = [record(rect(0, 0, 4, 4))]
    letter = record(rect(1, 1, 3, 3), rect(1.5, 1.5, 2.5, 2.5))
    assert_equal :ink, Subject.region_at([1.2, 2, 0], white, [letter])
    assert_equal :white, Subject.region_at([2, 2, 0], white, [letter])
    assert_equal :white, Subject.region_at([0.5, 2, 0], white, [letter])
    assert_equal :outside, Subject.region_at([5, 2, 0], white, [letter])
    concave = record([[0, 0, 0], [3, 0, 0], [3, 1, 0], [1, 1, 0], [1, 3, 0], [0, 3, 0]])
    refute Subject.contains?(concave, [2, 2, 0])
    assert Subject.contains?(concave, [0.5, 2, 0])
  end

  def test_overlapping_ink_uses_union_without_filling_counter_unless_second_glyph_paints_it
    ring = record(rect(1, 1, 3, 3), rect(1.5, 1.5, 2.5, 2.5))
    bar = record(rect(1.9, 0, 2.1, 4))
    white = [record(rect(0, 0, 4, 4))]
    assert_equal :ink, Subject.region_at([2, 2, 0], white, [ring, bar])
    assert_equal :white, Subject.region_at([1.7, 2, 0], white, [ring, bar])
  end

  def test_paint_order_is_source_order_and_unknown_or_later_masks_remain
    ink = { :paint_order => [1, 80] }
    assert Subject.earlier_mask?({ :paint_order => [1, 79] }, ink)
    assert Subject.earlier_mask?({ :paint_order => [0, 900] }, ink)
    refute Subject.earlier_mask?({ :paint_order => [1, 80] }, ink)
    refute Subject.earlier_mask?({ :paint_order => [1, 81] }, ink)
    refute Subject.earlier_mask?({ :paint_order => [2, 0] }, ink)
    refute Subject.earlier_mask?({}, ink)
    refute Subject.earlier_mask?({ :paint_order => [0, 1] }, {})
    refute Subject.earlier_mask?({ :paint_order => ['0', 1] }, ink)
    assert Subject.earlier_mask?({ :before_text => true }, ink)
  end

  def test_spatial_index_agrees_with_direct_union_for_negative_coordinates_and_large_masks
    white = [record(rect(-100, -100, 100, 100))]
    ink = [record(rect(-1, -1, 0, 0)), record(rect(0.2, 0.2, 0.4, 0.4))]
    wi, ii = Subject.spatial_index(white), Subject.spatial_index(ink)
    (-20..20).each do |x|
      (-20..20).each do |y|
        p = [x * 0.067, y * 0.067, 0]
        assert_equal Subject.region_at(p, white, ink), Subject.region_at(p, wi, ii)
      end
    end
  end

  def fixture
    white_face = Face.new([rect(0, 0, 4, 4)])
    ink_face = Face.new([rect(1, 1, 3, 3), rect(1.5, 1.5, 2.5, 2.5)])
    white = Group.new(Entities.new([white_face]))
    text = Group.new(Entities.new([ink_face]))
    text.owner = true
    # The mock supplies a pre-partitioned grid. This tests the composition,
    # ownership, area and classification contracts, not SketchUp subdivision.
    # Real add_face topology must also pass the native host acceptance gate.
    cells = []
    8.times do |x|
      8.times do |y|
        cells << Face.new([rect((x * 0.5 - 2) * 1000, (y * 0.5 - 2) * 1000,
                               ((x + 1) * 0.5 - 2) * 1000, ((y + 1) * 0.5 - 2) * 1000)])
      end
    end
    white.entities.stage_faces = cells
    [white, text, white_face, ink_face]
  end

  def test_composition_keeps_counter_and_surrounding_white_without_mutating_text
    white, text, original, ink = fixture
    before = Marshal.dump(ink.raw)
    receipt = Subject.compose!([{ :group => white, :fill_rgb => [1, 1, 1], :paint_order => [0, 3] }],
                               [{ :group => text, :paint_order => [0, 4] }])
    assert_in_delta 3.0, receipt[:removed_area], 1.0e-10
    assert_equal 1, receipt[:composed_groups]
    assert original.erased
    refute ink.erased
    assert_equal before, Marshal.dump(ink.raw)
    stage = white.entities.stage
    assert_in_delta 0.001, stage.transformation.scale, 1.0e-12
    assert_equal [2.0, 2.0, 0.0], stage.transformation.offset
    assert_in_delta 13_000_000.0, stage.entities.to_a.inject(0.0) { |sum, f| sum + f.area }, 1.0e-6
    assert stage.entities.added_points.flatten.all? { |p| p.z == 0.0 }
    assert_equal false, stage.entities.intersections[0]
    assert_same stage.entities, stage.entities.intersections[2]
    assert_equal true, stage.entities.intersections[4]
    assert_in_delta 1.0, stage.entities.intersections[1].scale, 1.0e-12
  end

  def test_fully_covered_white_removes_only_its_generated_containers
    white, text, original, _ink = fixture
    covering = Face.new([rect(0, 0, 4, 4)])
    text.entities.items.replace([covering])
    receipt = Subject.compose!([{ :group => white, :fill_rgb => [1, 1, 1], :before_text => true }], [text])
    assert_in_delta 16.0, receipt[:removed_area], 1.0e-10
    assert white.entities.stage.erased
    assert white.erased
    assert original.erased
    refute text.erased
    refute covering.erased
  end

  def test_private_stage_cleanup_removes_empty_repair_groups_but_keeps_physical_faces
    face = Face.new([rect(0, 0, 1, 1)])
    retained = Group.new(Entities.new([face]))
    inner = Group.new(Entities.new([CascadingEdge.new]))
    empty = Group.new(Entities.new([inner]))
    stage = Entities.new([retained, empty])
    Subject.clean_partition_edges!(stage)
    assert inner.erased
    assert empty.erased
    refute retained.erased
    refute face.erased
    assert_equal [retained], stage.to_a
  end

  def test_generic_host_failure_leaves_original_white_and_text_and_raises_contract_error
    white, text, original, ink = fixture
    white.entities.fail_add = true
    error = assert_raises(ContractError) do
      Subject.compose!([{ :group => white, :fill_rgb => [1, 1, 1], :before_text => true }], [text])
    end
    assert_match(/native white-mask composition failed/, error.message)
    refute original.erased
    refute ink.erased
    assert white.entities.stage.erased
    assert_empty white.entities.erased
  end

  def test_later_unknown_translucent_and_colored_masks_do_not_change
    white, text, original, = fixture
    masks = [
      { :group => white, :fill_rgb => [1, 1, 1], :paint_order => [0, 9] },
      { :group => white, :fill_rgb => [1, 1, 1] },
      { :group => white, :fill_rgb => [1, 1, 1], :opacity => 0.5, :before_text => true },
      { :group => white, :fill_rgb => [1, 0.9, 1], :before_text => true }
    ]
    receipt = Subject.compose!(masks, [{ :group => text, :paint_order => [0, 4] }])
    assert_equal 0, receipt[:composed_groups]
    assert_equal 2, receipt[:skipped_nonwhite]
    assert_equal 2, receipt[:skipped_unproven_order]
    refute original.erased
    assert_nil white.entities.stage
  end

  def test_unowned_and_positive_depth_geometry_is_not_flat_text_ink
    unowned = Group.new(Entities.new([Face.new([rect(0, 0, 1, 1)])]))
    positive = Group.new(Entities.new([Face.new([rect(0, 0, 1, 1)]), Face.new([rect(0, 0, 1, 1, 0.1)])]))
    positive.owner = true
    assert_empty Subject.collect_text_faces([unowned, positive])
  end

  def test_missing_subdivision_is_rejected_instead_of_erasing_a_whole_white_mask
    white, text, original, = fixture
    white.entities.stage_faces = [Face.new([rect(-2000, -2000, 2000, 2000)])]
    assert_raises(ContractError) do
      Subject.compose!([{ :group => white, :fill_rgb => [1, 1, 1], :before_text => true }], [text])
    end
    refute original.erased
    assert white.entities.stage.erased
  end

  def image_fixture
    image = Image.new
    image.attributes = {
      'source_span_id' => 'text_span:1:84',
      'renderer' => 'pdftocairo_transparent_page_crop',
      'raster_alpha_verified' => true,
      'raster_transparent_background_verified' => true,
      'raster_page_render_once_verified' => true,
      'raster_visible_pixel_verified' => true,
      'raster_page_number' => 1,
      'raster_source_pdf_sha256' => 'a' * 64
    }
    unit = Math.sqrt(0.5)
    matrix = [2 * unit, 2 * unit, 0, 0, -3 * unit, 3 * unit, 0, 0,
              0, 0, 1, 0, 10, 20, 0, 1]
    image.transformation = Affine.new(matrix)
    image.width, image.height = 4.0, 3.0
    corners = rect(0, 0, 2, 1).map { |p| Geom::Point3d.new(*p).transform(image.transformation) }
    image.bounds = Bounds.new(Geom::Point3d.new(corners.map(&:x).min, corners.map(&:y).min, 0),
                              Geom::Point3d.new(corners.map(&:x).max, corners.map(&:y).max, 0))
    image
  end

  def test_rotated_nonuniform_scaled_image_uses_physical_quad_and_accumulated_transform
    image = image_fixture
    matrix = image.transformation.to_a.each_with_index.map do |v, i|
      if i < 12
        [3, 7, 11].include?(i) ? v : v * 2
      elsif i == 12
        v * 2 + 100
      elsif i == 13
        v * 2 + 200
      else
        v
      end
    end
    faces = Subject.collect_text_faces([{ :group => image, :transformation => Affine.new(matrix),
                                         :paint_order => [1, 500] }])
    assert_equal 1, faces.length
    assert_equal [1, 500], faces[0][:paint_order]
    assert_equal true, faces[0][:final_page_crop]
    assert_equal 'text_span:1:84', faces[0][:source_span_id]
    assert_equal 1, faces[0][:raster_page_number]
    assert_equal 'a' * 64, faces[0][:source_pdf_sha256]
    assert_in_delta 48.0, Subject.source_area(faces), 1.0e-9
    assert_equal [120.0, 240.0, 0.0], faces[0][:loops][0][0]
    box = faces[0][:bounds]
    refute Subject.contains?(faces[0], [box[0] + 0.01, box[1] + 0.01, 0])
  end

  def test_image_without_verified_page_composite_is_not_a_white_cutout
    image = image_fixture
    image.attributes['raster_page_render_once_verified'] = false
    assert_empty Subject.collect_text_faces([image])
  end

  def test_image_with_unproven_source_page_never_gets_final_composite_order_evidence
    image = image_fixture
    image.attributes['raster_page_number'] = 2
    refute Subject.image_snapshot(image, image.transformation)[:final_page_crop]
    image.attributes.delete('raster_page_number')
    refute Subject.image_snapshot(image, image.transformation)[:final_page_crop]
  end

  def test_prebound_faces_supply_proven_order_without_recollecting_roots
    white, text, original, = fixture
    faces = Subject.collect_text_faces([{ :group => text, :paint_order => [0, 10] }])
    receipt = Subject.compose!([{ :group => white, :fill_rgb => [1, 1, 1],
                                 :paint_order => [0, 9] }], [Object.new], :ink_faces => faces)
    assert_equal 1, receipt[:composed_groups]
    assert original.erased
    assert_in_delta 3.0, receipt[:removed_area], 1.0e-10
    assert_equal 0, Subject.compose!([], [Object.new], :ink_faces => [])[:ink_faces]
    assert_raises(ContractError) { Subject.compose!([], [], :ink_faces => nil) }
  end

  def test_image_bounds_mismatch_is_a_generic_failure_not_bbox_fallback
    image = image_fixture
    image.width *= 2
    assert_raises(ContractError) { Subject.collect_text_faces([image]) }
  end

  def test_translucent_ink_is_skipped_and_error_detail_is_bounded_without_paths
    _white, text, _original, ink = fixture
    ink.material = Struct.new(:alpha).new(0.5)
    assert_empty Subject.collect_text_faces([text])
    detail = Subject.safe_error_detail("Points not planar at C:\\private\\source.pdf\n" + 'x' * 400)
    refute_match(/private|source.pdf/, detail)
    assert_operator detail.length, :<=, 180
    assert_match(/Points not planar/, detail)
  end

  def test_zero_area_native_mesh_triangles_have_no_interior_but_thin_triangles_are_kept
    collinear = [[1, 1, 0], [1, 2, 0], [1, 3, 0]].map { |p| Geom::Point3d.new(*p) }
    assert Subject.degenerate_mesh_triangle?(collinear)
    diagonal = [[0, 0, 0], [1, 1, 0], [2, 2, 0]].map { |p| Geom::Point3d.new(*p) }
    assert Subject.degenerate_mesh_triangle?(diagonal)
    thin = [[0, 0, 0], [1, 0, 0], [1, 1.0e-20, 0]].map { |p| Geom::Point3d.new(*p) }
    refute Subject.degenerate_mesh_triangle?(thin)
  end

  def test_face_placement_identity_wins_over_inherited_glyph_and_root_indices
    first = Face.new([rect(0, 0, 1, 1)])
    second = Face.new([rect(2, 0, 3, 1)])
    first.attributes['source_placement_indices'] = '7'
    glyph = Group.new(Entities.new([first, second]))
    glyph.attributes['source_placement_indices'] = '2'
    root = Group.new(Entities.new([glyph]))
    root.owner = true
    root.attributes['source_placement_indices'] = '1,2'
    placements = [{ :placement_index => 2, :loops => [], :paint_order => [0, 3] }]
    faces = Subject.collect_text_faces([{ :group => root, :source_placements => placements }])
    assert_equal [[7], [2]], faces.map { |face| face[:source_placement_indices] }
    assert faces.all? { |face| face[:source_span_id] == 'text_span:1:84' }
    assert_same placements, faces[0][:source_placements]
    first.attributes['source_placement_indices'] = 'invalid'
    assert_empty Subject.source_indices_for(first, [2])
  end

  def test_only_exact_duplicate_native_loop_sets_are_removed
    outer, hole = rect(0, 0, 4, 4), rect(1, 1, 2, 2)
    original = Face.new([outer, hole])
    duplicate = Face.new([outer.reverse.rotate(2), hole.reverse.rotate(1)])
    filled_counter = Face.new([outer])
    near = Face.new([rect(0, 0, 4.000000001, 4), hole])
    Subject.remove_duplicate_faces!(Entities.new([original, duplicate, filled_counter, near]))
    refute original.erased
    assert duplicate.erased
    refute filled_counter.erased
    refute near.erased
  end

  def test_orphan_cleanup_ignores_only_snapshot_edges_invalidated_by_an_earlier_erase
    white, text, original, ink = fixture
    before = Marshal.dump(ink.raw)
    first, second, retained = CascadingEdge.new, CascadingEdge.new, CascadingEdge.new(true)
    first.on_erase = lambda { second.invalidate! }
    white.entities.stage_faces.concat([first, second, retained])
    receipt = Subject.compose!([{ :group => white, :fill_rgb => [1, 1, 1], :before_text => true }], [text])
    assert_in_delta 3.0, receipt[:removed_area], 1.0e-10
    assert original.erased
    assert_equal before, Marshal.dump(ink.raw)
    refute first.valid?
    refute second.valid?
    assert retained.valid?
    assert retained.hidden
  end

  def test_discovery_does_not_query_a_cached_edge_invalidated_by_previous_discovery
    first, second = CascadingEdge.new, CascadingEdge.new
    first.on_find = lambda { second.invalidate! }
    Subject.subdivide_native_boundaries!(Entities.new([first, second]))
    assert first.valid?
    refute second.valid?
  end

  def test_duplicate_cleanup_does_not_query_later_invalidated_snapshot_entities
    original = Face.new([rect(0, 0, 1, 1)])
    duplicate = Face.new([rect(0, 0, 1, 1)])
    disposable = CascadingEdge.new
    duplicate.define_singleton_method(:erase!) do
      @erased = true
      disposable.invalidate!
    end
    Subject.remove_duplicate_faces!(Entities.new([original, duplicate, disposable]))
    refute original.erased
    assert duplicate.erased
    refute disposable.valid?
  end

  def test_nested_and_external_native_holes_are_detected_without_changing_valid_counters
    outer, counter = rect(0, 0, 10, 10), rect(2, 2, 8, 8)
    refute Subject.invalid_native_holes?([outer, counter])
    refute Subject.invalid_native_holes?([outer, rect(1, 1, 2, 2), rect(7, 7, 9, 9)])
    assert Subject.invalid_native_holes?([outer, counter, rect(3, 3, 4, 4)])
    assert Subject.invalid_native_holes?([outer, rect(12, 2, 13, 3)])
    assert Subject.invalid_native_holes?([outer, rect(9, 2, 11, 3)])
    normalized = BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.normalize(
      [{ :loops => [outer, counter, rect(3, 3, 4, 4), rect(12, 2, 13, 3)] }], :native_union)
    assert_equal 2, normalized.length
    assert_in_delta 64.0, Subject.source_area([record(*normalized)]), 1.0e-12
    refute Subject.contains?(record(*normalized), [3.5, 3.5, 0])
  end

  def test_valid_native_counter_partition_keeps_original_faces_and_avoids_reconstruction
    face = Face.new([rect(0, 0, 10, 10), rect(2, 2, 8, 8)])
    entities = Entities.new([face])
    before = Marshal.dump(face.raw)
    Subject.repair_native_hole_topology!(entities)
    refute face.erased
    assert_nil entities.stage
    assert_equal before, Marshal.dump(face.raw)
  end

  def test_unproved_native_topology_is_not_accepted_by_changing_area_math
    face = Face.new([rect(0, 0, 10, 10), rect(12, 2, 13, 3)])
    entities = Entities.new([face])
    BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.stub(:normalize, nil) do
      assert_raises(ContractError) { Subject.repair_native_hole_topology!(entities) }
    end
    refute face.erased
    assert_nil entities.stage
  end

  def test_closed_bounds_rejection_preserves_exact_concave_loop_predicates
    loop = [[0, 0], [5, 0], [5, 1], [2, 1], [2, 5], [0, 5]].map { |p| p.map(&:to_r) }
    box = Subject.loop_bounds2(loop)
    (-2..12).each do |x|
      (-2..12).each do |y|
        point = [Rational(x, 2), Rational(y, 2)]
        assert_equal Subject.strict_loop_inside?(point, loop), Subject.strict_loop_inside?(point, loop, box)
      end
    end
    refute Subject.strict_loop_inside?([3.to_r, 3.to_r], loop, box)
    refute Subject.strict_loop_inside?([5.to_r, 0.to_r], loop, box)
    BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.stub(:winding, lambda { |*_args| raise 'unnecessary exact polygon walk' }) do
      refute Subject.strict_loop_inside?([6.to_r, 2.to_r], loop, box)
    end
  end
end
