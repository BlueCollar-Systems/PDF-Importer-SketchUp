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
    def polygons; (2..(@points.length - 1)).map { |i| [1, i, i + 1] }; end
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
    attr_accessor :fail_add, :stage_faces, :alter_points, :native_tolerance
    def initialize(items = []); @items, @erased, @added_points = items, [], []; end
    def to_a; items.reject { |e| e.respond_to?(:valid?) && !e.valid? }; end
    def add_group
      @stage = Group.new(Entities.new)
      @stage.entities.fail_add = fail_add
      @stage.entities.stage_faces = stage_faces
      @stage.entities.alter_points = alter_points
      @stage.entities.native_tolerance = native_tolerance
      items << @stage
      @stage
    end
    def add_face(points)
      raise 'host construction failed' if fail_add
      if native_tolerance
        points.each_with_index do |a, i|
          points.drop(i + 1).each do |b|
            if (a.x - b.x).abs < native_tolerance && (a.y - b.y).abs < native_tolerance
              raise ArgumentError, 'Duplicate points in array'
            end
          end
        end
      end
      added_points << points
      if stage_faces
        items.concat(stage_faces)
        stage_faces.first
      else
        actual = alter_points ? alter_points.call(points) : points
        face = Face.new([actual.map { |p| [p.x, p.y, p.z] }])
        items << face
        face
      end
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
    # add_face consumes the actual emitted source cells; no prebuilt partition
    # is supplied. Native tolerance/face behavior still requires host acceptance.
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
    faces = Subject.partition_faces(stage.entities)
    assert_in_delta 13_000_000.0, faces.inject(0.0) { |sum, f| sum + f.area }, 1.0e-6
    assert faces.flat_map(&:raw).flatten(1).all? { |p| p[2] == 0.0 }
    assert_nil stage.entities.intersections, 'source cells need no native intersection'
    assert stage.entities.to_a.all? { |g| g.typename == 'Group' && g.transformation.scale == 1.0 }
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

  def test_crossing_source_regions_build_physical_triangles_without_host_intersection
    original = Face.new([rect(0, 0, 4, 4)])
    white = Group.new(Entities.new([original]))
    left = Face.new([[[0,0,0], [4,0,0], [0,4,0]]])
    right = Face.new([[[0,0,0], [4,0,0], [4,4,0]]])
    text = Group.new(Entities.new([left, right]))
    text.owner = true
    before = Marshal.dump([left.raw, right.raw])
    receipt = Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
    assert_in_delta 12.0, receipt[:removed_area], 1.0e-10
    faces = Subject.partition_faces(white.entities.stage.entities)
    assert_in_delta 4_000_000.0, faces.inject(0.0) { |sum, face| sum + face.area }, 1.0e-8
    assert_equal before, Marshal.dump([left.raw, right.raw])
    assert original.erased
    assert_nil white.entities.stage.entities.intersections
  end

  def test_distinct_exact_vertices_that_collapse_as_host_floats_are_rejected
    x = 10**30
    cell = { :loop => [[x.to_r, 0.to_r, 0.to_r], [(x+1).to_r, 0.to_r, 0.to_r],
                       [(x+1).to_r, 1.to_r, 0.to_r], [x.to_r, 1.to_r, 0.to_r]] }
    error = assert_raises(ContractError) { Subject.partition_construction_points([cell], [0,0,0]) }
    assert_match(/collapse/, error.message)
  end

  def exact_cell(points)
    { :loop => points.map { |p| p.map(&:to_r) } }
  end

  def test_adaptive_scale_keeps_a_real_white_sliver_that_native_tolerance_would_merge
    delta = 2.0**-35
    original = Face.new([rect(0, 0, 4, 4)])
    white = Group.new(Entities.new([original]))
    white.entities.native_tolerance = Subject::NATIVE_VERTEX_TOLERANCE
    ink = [Face.new([rect(1, 0.5, 3, 1.5)]), Face.new([rect(1 + delta, 1, 3, 2.5)])]
    text = Group.new(Entities.new(ink))
    text.owner = true
    before = Marshal.dump(ink.map(&:raw))
    receipt = Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
    stage = white.entities.stage
    scale = 1.0 / stage.transformation.scale
    assert_operator scale, :>, Subject::CONSTRUCTION_SCALE
    assert_operator scale, :<=, Subject::CONSTRUCTION_SCALE * 2.0**Subject::MAX_CONSTRUCTION_SCALE_STEPS
    assert_equal 1, receipt[:composed_groups]
    assert original.erased
    assert_equal before, Marshal.dump(ink.map(&:raw))
    retained = Subject.snapshots(stage, stage.transformation, false)
    assert retained.any? { |r| Subject.contains?(r, [1 + delta / 2, 2, 0]) }, 'thin source-white strip is retained'
    assert retained.any? { |r| r[:loops].first.map { |p| p[0] }.minmax == [1.0, 1.0 + delta] }
    refute retained.any? { |r| Subject.contains?(r, [2, 2, 0]) }, 'physical ink remains uncovered'
  end

  def test_scale_selection_uses_corner_altitude_and_the_smallest_bounded_binary_step
    normal = exact_cell(rect(0,0,1,1))
    assert_equal Subject::CONSTRUCTION_SCALE, Subject.partition_construction_scale([normal])
    thin = exact_cell([[0,0,0], [2,0,0], [1,2.0**-35,0]])
    scale = Subject.partition_construction_scale([thin])
    clearance = Subject.partition_clearance_squared([thin])
    target = Subject::CONSTRUCTION_CLEARANCE.to_r**2
    assert_operator scale, :>, Subject::CONSTRUCTION_SCALE
    assert_operator clearance * scale.to_r**2, :>=, target
    assert_operator clearance * (scale / 2).to_r**2, :<, target
    assert_equal 0.0, Math.log2(scale / Subject::CONSTRUCTION_SCALE) % 1
    origin = [0,0,0]
    mapped = Subject.partition_construction_points([thin], origin, scale)
    page = Geom::Transformation.scaling(1.0 / scale)
    [Geom::Transformation.new, Geom::Transformation.new(2, [10,20,0]),
     Geom::Transformation.new(-2, [10,20,0])].each do |parent|
      Subject.verify_adaptive_page_points!(mapped, origin, scale, page, parent, parent.inverse * page)
    end
    mapped.each { |point, host| assert_equal point.map(&:to_f), Subject.page_point(host, origin, scale) }
  end

  def test_adaptive_scale_and_coordinate_budgets_fail_without_dropping_vertices
    assert_equal Subject::CONSTRUCTION_SCALE, Subject.partition_construction_scale([])
    assert_equal({}, Subject.partition_construction_points([], [0,0,0]))
    normal = exact_cell(rect(0,0,1,1))
    [1000, Rational(1000, 1)].each do |scale|
      assert_equal 4, Subject.partition_construction_points([normal], [0,0,0], scale).length
    end
    [nil, '1000', Complex(1000, 0), Float::NAN, -1000, 0].each do |scale|
      assert_raises(ContractError) { Subject.partition_construction_points([], [0,0,0], scale) }
    end
    too_thin = exact_cell(rect(0,0,2.0**-70,1))
    error = assert_raises(ContractError) { Subject.partition_construction_scale([too_thin]) }
    assert_match(/scale budget/, error.message)
    far = exact_cell(rect(2**20,0,2**20 + 1,1))
    error = assert_raises(ContractError) do
      Subject.partition_construction_points([far], [0,0,0], Subject::CONSTRUCTION_SCALE * 2.0**20)
    end
    assert_match(/coordinate budget/, error.message)
    assert_raises(ContractError) { Subject.partition_construction_points([far], [0,0,0], Float::INFINITY) }
    assert_raises(ContractError) do
      Subject.partition_construction_points([far], [0,0,0], Subject::CONSTRUCTION_SCALE * 2.0**31)
    end
  end

  def test_adaptive_page_roundtrip_and_parent_transform_changes_are_rejected_exactly
    cell = exact_cell(rect(0,0,1,1))
    scale, origin = Subject::CONSTRUCTION_SCALE * 2, [0,0,0]
    mapped = Subject.partition_construction_points([cell], origin, scale)
    page = Geom::Transformation.scaling(1.0 / scale)
    identity = Geom::Transformation.new
    changed = Geom::Transformation.new(1.0 / scale, [1.0e-12,0,0])
    error = assert_raises(ContractError) do
      Subject.verify_adaptive_page_points!(mapped, origin, scale, page, identity, changed)
    end
    assert_match(/changed the final page transform/, error.message)
    error = assert_raises(ContractError) do
      Subject.verify_adaptive_page_points!(mapped, origin, scale, changed, identity, page)
    end
    assert_match(/restore exact page coordinates/, error.message)
  end

  def test_host_boundary_change_below_aggregate_area_tolerance_is_still_rejected
    white, text, original, ink = fixture
    white.entities.alter_points = lambda do |points|
      points.each_with_index.map do |p, i|
        Geom::Point3d.new(p.x + (i == 0 ? 1.0e-8 : 0), p.y, p.z)
      end
    end
    error = assert_raises(ContractError) do
      Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
    end
    assert_match(/changed source boundary vertices/, error.message)
    refute original.erased
    refute ink.erased
    assert white.entities.stage.erased
  end

  def test_host_face_may_reverse_or_rotate_but_may_not_drop_a_corner_or_add_a_hole
    points = rect(0,0,4,4).map { |p| Geom::Point3d.new(*p) }
    Subject.verify_partition_face!(Face.new([rect(0,0,4,4).reverse.rotate(2)]), points)
    assert_raises(ContractError) { Subject.verify_partition_face!(Face.new([rect(0,0,4,4).first(3)]), points) }
    assert_raises(ContractError) do
      Subject.verify_partition_face!(Face.new([rect(0,0,4,4), rect(1,1,2,2)]), points)
    end
  end

  def test_opt_in_failure_diagnostic_copies_source_without_replacing_original_error
    white, text, original, ink = fixture
    white.entities.fail_add = true
    captured = []
    callback = lambda do |value|
      captured << value
      value[:white].first[:loops].first.first[0] = 999
      raise 'diagnostic writer failed'
    end
    error = assert_raises(ContractError) do
      Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }],
                       [text], :partition_diagnostic => callback)
    end
    assert_match(/host construction failed/, error.message)
    assert_equal 1, captured.length
    assert_equal 'bcs.planar_partition_diagnostic/1', captured.first[:schema]
    assert_equal [0.0,0.0,0.0], original.raw.first.first
    refute original.erased
    refute ink.erased
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

  def test_ghostscript_crop_requires_the_same_full_page_and_pixel_evidence
    image = image_fixture
    image.attributes['renderer'] = 'ghostscript_transparent_page_crop'
    assert Subject.image_snapshot(image, image.transformation)[:final_page_crop]
    image.attributes['raster_alpha_verified'] = false
    assert_nil Subject.image_snapshot(image, image.transformation)
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
    first, second, retained = CascadingEdge.new, CascadingEdge.new, CascadingEdge.new(true)
    first.on_erase = lambda { second.invalidate! }
    Subject.clean_partition_edges!(Entities.new([first, second, retained]))
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

  def crop_record(loop)
    record(loop).merge(:final_page_crop => true, :source_pdf_sha256 => 'a' * 64,
                       :raster_page_number => 1)
  end

  def test_overlapping_final_page_crops_construct_union_without_changing_physical_records
    crops = [crop_record(rect(0, 2, 8, 4)), crop_record(rect(0, 0, 7, 3))]
    before = Marshal.dump(crops)
    loops = Subject.construction_ink_loops(crops)
    assert_equal 1, loops.length
    assert_equal 8, loops.first.length
    assert_in_delta 30.0, Subject.loop_area(loops.first), 1.0e-12
    assert_equal before, Marshal.dump(crops)
    # The intermediate seam is absent, while the exact external step remains.
    assert_includes loops.first, [7.0, 0.0, 0.0]
    refute loops.first.each_index.any? { |i| [loops.first[i], loops.first[(i + 1) % loops.first.length]].sort ==
      [[0.0, 2.0, 0.0], [7.0, 2.0, 0.0]] }
  end

  def test_crop_union_keeps_nested_touching_disjoint_rotated_and_counter_regions_exact
    cases = [
      [rect(0, 0, 6, 6), rect(2, 2, 4, 4)],
      [rect(0, 0, 3, 3), rect(3, 0, 5, 3)],
      [rect(0, 0, 2, 2), rect(4, 0, 6, 2)],
      [rect(0, 0, 2, 2), rect(2, 2, 4, 4)],
      [[[0, 2, 0], [2, 0, 0], [4, 2, 0], [2, 4, 0]], rect(2, 1, 5, 3)],
      [rect(0, 0, 6, 1), rect(0, 5, 6, 6), rect(0, 1, 1, 5), rect(5, 1, 6, 5)]
    ]
    cases.each do |raw|
      crops = raw.map { |loop| crop_record(loop) }
      before = Marshal.dump(crops)
      loops = Subject.construction_ink_loops(crops)
      # Offset samples avoid coincident fixture edges, including diagonals.
      (-2..14).each do |x|
        (-2..14).each do |y|
          p = [Rational(x, 2) + Rational(1, 13), Rational(y, 2) + Rational(1, 17)]
          expected = crops.any? { |face| Subject.contains?(face, p) }
          actual = loops.inject(0) do |sum, loop|
            sum + BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.winding(p,
              loop.map { |v| v.first(2).map(&:to_r) })
          end != 0
          assert_equal expected, actual
        end
      end
      assert_equal before, Marshal.dump(crops)
    end
  end

  def test_unproved_mixed_or_different_page_inputs_preserve_original_construction
    first, second = crop_record(rect(0, 0, 3, 3)), crop_record(rect(1, 1, 4, 4))
    [:final_page_crop, :source_pdf_sha256, :raster_page_number].each do |key|
      unproved = second.dup
      unproved.delete(key)
      assert_equal [first[:loops].first, unproved[:loops].first],
                   Subject.construction_ink_loops([first, unproved])
    end
    other_page = second.merge(:raster_page_number => 2)
    assert_equal [first[:loops].first, other_page[:loops].first],
                 Subject.construction_ink_loops([first, other_page])
    assert_equal first[:loops], Subject.construction_ink_loops([first])
  end

  def test_same_page_source_ordered_glyphs_and_final_crop_construct_exact_union
    glyph = record(rect(0, 0, 4, 4), rect(1, 1, 3, 3)).merge(
      :source_span_id => 'text_span:1:1', :paint_order => [0, 20])
    nested = record(rect(3, 1, 4, 2)).merge(
      :source_span_id => 'text_span:1:1', :paint_order => [0, 21])
    crop = crop_record(rect(2, -1, 5, 5))
    ink = [glyph, nested, crop]
    before = Marshal.dump(ink)
    loops = Subject.construction_ink_loops(ink)
    assert_equal 2, loops.length, 'the remaining source counter stays open'
    (-2..12).each do |x|
      (-4..14).each do |y|
        point = [Rational(x, 2) + Rational(1, 13), Rational(y, 2) + Rational(1, 17)]
        expected = ink.any? { |face| Subject.contains?(face, point) }
        actual = loops.inject(0) do |sum, loop|
          sum + BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.winding(
            point, loop.map { |v| v.first(2).map(&:to_r) })
        end != 0
        assert_equal expected, actual
      end
    end
    assert_equal before, Marshal.dump(ink)
    refute_equal ink.flat_map { |face| face[:loops] }, loops
  end

  def test_mixed_union_requires_bound_same_page_glyph_order_and_keeps_pure_vectors
    crop = crop_record(rect(1, 0, 4, 3))
    glyph = record(rect(0, 0, 3, 3)).merge(
      :source_span_id => 'text_span:1:1', :paint_order => [0, 20])
    [glyph.merge(:paint_order => nil), glyph.merge(:source_span_id => 'text_span:2:1'),
     glyph.merge(:source_span_id => nil)].each do |unproved|
      assert_equal [crop, unproved].flat_map { |face| face[:loops] },
                   Subject.construction_ink_loops([crop, unproved])
    end
    vectors = [glyph, glyph.merge(:loops => [rect(2, 0, 5, 3)])]
    assert_equal vectors.flat_map { |face| face[:loops] }, Subject.construction_ink_loops(vectors)
  end

  # SketchUp's add_face raises "Duplicate points in array" for a closing
  # point that repeats the first and for consecutive points inside its
  # 0.001 in vertex tolerance (a title-block sheet did both and the whole
  # page failed). The loop keeps its shape; only the repeats go.
  def test_distinct_loop_points_drops_closing_and_sub_tolerance_repeats
    p = lambda { |x, y| Geom::Point3d.new(x, y, 0) }
    closed = [p[0, 0], p[10, 0], p[10, 10], p[0, 10], p[0, 0]]
    assert_equal [[0, 0], [10, 0], [10, 10], [0, 10]],
                 Subject.distinct_loop_points(closed).map { |q| [q.x, q.y] }
    jittered = [p[0, 0], p[0.0004, 0.0002], p[10, 0], p[10, 10], p[10, 10.0009], p[0, 10]]
    assert_equal [[0, 0], [10, 0], [10, 10], [0, 10]],
                 Subject.distinct_loop_points(jittered).map { |q| [q.x, q.y] }
    kept = [p[0, 0], p[0.002, 0], p[10, 0]]
    assert_equal 3, Subject.distinct_loop_points(kept).length, 'points beyond the tolerance stay'
    assert_equal 1, Subject.distinct_loop_points([p[1, 1], p[1, 1], p[1, 1]]).length
    assert_equal [], Subject.distinct_loop_points([])
  end
end
