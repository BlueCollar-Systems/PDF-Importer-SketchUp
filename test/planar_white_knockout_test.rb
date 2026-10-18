require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'delegate'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/planar_white_knockout'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z); @x, @y, @z = x.to_f, y.to_f, z.to_f; end
    def transform(t); t.point(self); end
  end
  class Transformation
    attr_reader :scale, :offset, :weight
    def initialize(scale = 1.0, offset = [0, 0, 0], weight = 1.0); @scale, @offset, @weight = scale, offset, weight; end
    def self.translation(p); new(1.0, [p.x, p.y, p.z]); end
    def self.scaling(*values)
      raise 'test scaling must be uniform' unless [1, 3].include?(values.length) && values.uniq.length == 1
      new(values.first)
    end
    def *(other)
      Transformation.new(scale * other.scale,
        offset.each_with_index.map { |v, i| v * other.weight + scale * other.offset[i] }, weight * other.weight)
    end
    def inverse; Transformation.new(1.0 / scale, offset.map { |v| -v / (scale * weight) }, 1.0 / weight); end
    def point(p); Point3d.new(*[p.x, p.y, p.z].each_with_index.map { |v, i| (v * scale + offset[i]) / weight }); end
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

  def test_opaque_rgb_preserves_exact_real_channels_and_rejects_invalid_values
    [[0,1,0], [0.0,0.5,1.0], [Rational(0,1),Rational(1,3),Rational(1,1)]].each do |rgb|
      record={:group=>Object.new,:fill_rgb=>rgb.freeze,:opacity=>1.0}
      assert Subject.opaque_fill?(record)
      assert_same rgb,record[:fill_rgb]
    end
    tiny=Rational(1,10**400)
    [Float::NAN, Float::INFINITY, -Float::INFINITY, -1, 2, 10**400,
     Rational(10**400,1), -tiny, Rational(1,1)+tiny,
     Complex(0,0), Complex(1,1), true, false, nil, '1'].each do |value|
      refute Subject.opaque_fill?(:group=>Object.new,:fill_rgb=>[value,0,1])
    end
  end

  def test_integer_and_rational_rgb_work_without_modern_numeric_finite_api
    # Remove the modern API only in a child process, reproducing Ruby 2.2
    # without changing the numeric classes used by other tests.
    source=File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/planar_white_knockout.rb',File.dirname(__FILE__))
    program=<<'RUBY'
require ARGV.fetch(0)
[Integer,Rational].each do |type|
  type.class_eval { undef_method :finite? if method_defined?(:finite?) }
end
subject=BlueCollarSystems::PDFVectorImporter::PlanarWhiteKnockout
raise 'legacy RGB rejected' unless subject.opaque_fill?(:group=>Object.new,:fill_rgb=>[1,Rational(1,2),0])
raise 'float RGB rejected' unless subject.opaque_fill?(:group=>Object.new,:fill_rgb=>[1.0,0.5,0.0])
tiny=Rational(1,10**400)
[-tiny,Rational(1,1)+tiny,10**400,Float::INFINITY,Float::NAN,Complex(1,0)].each do |value|
  raise 'invalid RGB accepted' if subject.opaque_fill?(:group=>Object.new,:fill_rgb=>[value,0,1])
end
RUBY
    _stdout,stderr,status=Open3.capture3(RbConfig.ruby,'-e',program,source)
    assert status.success?,stderr
  end

  class Mesh
    def initialize(points); @points = points; end
    def polygons; (2..(@points.length - 1)).map { |i| [1, i, i + 1] }; end
    def point_at(i); @points[i - 1]; end
  end

  class Face
    attr_accessor :material, :back_material, :layer, :attributes, :hidden
    attr_reader :loops, :erased
    def initialize(loops)
      @loops = loops.map { |points| Loop.new(points.map { |p| Vertex.new(Geom::Point3d.new(*p)) }) }
      @material, @back_material = :white, :white
      @erased = false
      @attributes = {}
    end
    def typename; 'Face'; end
    def entityID; object_id; end
    def outer_loop; loops.first; end
    def valid?; !@erased; end
    def hidden?; hidden == true; end
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
    attr_accessor :transformation, :name, :owner, :attributes, :hidden
    def initialize(entities)
      @entities = entities
      @transformation = Geom::Transformation.new
      @owner = false
      @attributes = {}
    end
    def typename; 'Group'; end
    def valid?; !@erased; end
    def hidden?; @hidden == true; end
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

  def preserved_mask(loops, order = 0)
    face = Face.new(loops)
    face.material, face.back_material, face.layer = :source_front, :source_back, :source_layer
    source = Group.new(Entities.new([face]))
    source.attributes['source_fill_original'] = true
    wrapper = Group.new(Entities.new([source]))
    [{ :group => wrapper, :fill_rgb => [1,1,1], :before_text => true,
       :preserve_source => true, :pdf_paint_order => [0, 100 + order],
       :paint_order => [1, 200 + order] }, wrapper, source, face]
  end

  def test_exact_zero_ink_keeps_native_source_and_style_without_constructing_cells
    triangle = [[0,0,0],[3,0,0],[0,3,0]]
    cases = [
      [[triangle], [[[2,2,0],[3,2,0],[2,3,0]]]],
      [[triangle], [[[1.5,1.5,0],[2.5,1.5,0],[1.5,2.5,0]]]],
      [[triangle], [[[0,3,0],[3,0,0],[3,3,0]]]],
      [[rect(0,0,4,4), rect(1,1,3,3)], [rect(1.5,1.5,2.5,2.5)]]
    ]
    cases.each do |white_loops, ink_loops|
      mask, wrapper, source, original = preserved_mask(white_loops)
      ink = Face.new(ink_loops)
      text = Group.new(Entities.new([ink]));text.owner = true
      transform = Geom::Transformation.new(2.0, [5,7,0])
      wrapper.transformation = transform;text.transformation = transform
      before = Marshal.dump([original.raw, original.material, original.back_material,
        original.layer, source.attributes, source.hidden?, ink.raw])
      wrapper.entities.define_singleton_method(:add_group) { raise 'no-op constructed native geometry' }
      result = Subject.compose!([mask], [text])
      assert_equal 1, result[:unchanged_no_ink_groups]
      assert_equal 0, result[:composed_groups]
      assert_equal 0, result[:failed_groups]
      assert_equal 0.0, result[:removed_area]
      assert_nil wrapper.entities.stage
      assert source.valid? && original.valid? && ink.valid?
      assert_same transform, wrapper.transformation
      assert_same transform, text.transformation
      assert_equal before, Marshal.dump([original.raw, original.material, original.back_material,
        original.layer, source.attributes, source.hidden?, ink.raw])
    end
  end

  def test_direct_zero_ink_returns_explicit_nil_and_cancellation_does_not_count_success
    mask, wrapper, source, original = preserved_mask([rect(0,0,4,4), rect(1,1,3,3)])
    ink = [record(rect(1.5,1.5,2.5,2.5))]
    white = Subject.snapshots(wrapper, wrapper.transformation, false)
    assert_nil Subject.compose_group!(wrapper, wrapper.transformation, white, ink, :preserve_source => true)
    text = Group.new(Entities.new([Face.new([rect(1.5,1.5,2.5,2.5)])]));text.owner = true
    assert_raises(BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled) do
      Subject.compose!([mask], [text], :continue_mask_failures => true,
        :run_controller => cancelling_controller(:white_mask_verify), :page_number => 1)
    end
    assert_nil wrapper.entities.stage
    assert source.valid? && original.valid?
    refute source.hidden?
  end

  def test_no_op_requires_nonempty_positive_exact_area_consistent_with_source_and_owned_originals
    partition = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
    exact_loop = rect(0,0,4,4).map { |point| point.map(&:to_r) }
    [[], [{:region=>:white,:area=>0.to_r}], [{:region=>:white,:area=>16.0}],
      [{:region=>:white,:area=>1.to_r}], [{:region=>:white,:area=>16.to_r}],
      [{:region=>:white,:area=>16.to_r,:loop=>[]}],
      [{:region=>:white,:area=>16.to_r,:loop=>rect(0,0,2,2).map { |p| p.map(&:to_r) }}],
      [{:region=>:white,:area=>16.to_r,:loop=>exact_loop.map { |p| [p[0],p[1],1.to_r] }}],
      [{:region=>:white,:area=>16.to_r,:loop=>exact_loop.map { |p| [p[0].to_f,p[1],p[2]] }}],
      [{:region=>:white,:area=>16.to_r,:loop=>[[0,0,0],[5,0,0],[5,2,0],[2,2,0],[2,5,0],[0,5,0]].map { |p| p.map(&:to_r) }}],
      [{:region=>:white,:area=>16.to_r,:loop=>exact_loop+[exact_loop.first]}]
    ].each do |cells|
      white, text, original, ink = fixture
      partition.stub(:partition, cells) do
        assert_raises(ContractError) do
          Subject.compose!([{:group=>white,:fill_rgb=>[1,1,1],:before_text=>true}], [text])
        end
      end
      assert original.valid? && ink.valid?
      assert white.entities.stage.nil? || !white.entities.stage.valid?,
        'a rejected empty partition must not leave a live native stage'
    end
    mask, wrapper, source, original = preserved_mask([rect(0,0,4,4), rect(1,1,3,3)])
    source.attributes.delete('source_fill_original')
    text = Group.new(Entities.new([Face.new([rect(1.5,1.5,2.5,2.5)])]));text.owner = true
    error = assert_raises(ContractError) { Subject.compose!([mask], [text]) }
    assert_match(/separately owned/, error.message)
    assert source.valid? && original.valid?
    assert_nil wrapper.entities.stage
    white, text, original, = fixture
    zero_source = [record([[0,0,0],[1,0,0],[2,0,0]])]
    tiny_loop = [[0,0,0],[Rational(1,10**6),0,0],[0,Rational(1,10**6),0]].map { |p| p.map(&:to_r) }
    tiny_cell = {:region=>:white,:area=>Rational(1,2*10**12),:loop=>tiny_loop}
    partition.stub(:partition, [tiny_cell]) do
      assert_raises(ContractError) do
        Subject.compose_group!(white, white.transformation, zero_source,
          Subject.collect_text_faces([text]))
      end
    end
    assert original.valid?
    assert_nil white.entities.stage
  end

  def test_positive_tiny_ink_is_not_a_zero_area_shortcut
    white, text, original, = fixture
    text.entities.items.replace([Face.new([rect(0,0,2.0**-70,4)])])
    scale = Subject.method(:partition_construction_scale)
    attempts = 0
    Subject.stub(:partition_construction_scale, lambda { |cells|
      attempts += 1
      assert cells.any? { |cell| cell[:region] == :ink && cell[:area] > 0 }
      scale.call(cells)
    }) do
      assert_raises(ContractError) do
        Subject.compose!([{:group=>white,:fill_rgb=>[1,1,1],:before_text=>true}], [text])
      end
    end
    assert_operator attempts, :>, 0
    assert original.valid?
    assert_nil white.entities.stage
  end

  def test_opt_in_continues_only_after_local_cleanup_and_retains_earlier_and_later_success
    partition = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
    [:partition, :native].each do |failure_kind|
      masks = 3.times.map { |i| preserved_mask([rect(0,0,4,4)], i) }
      _white, text, _original, ink = fixture
      before = Marshal.dump([masks[1][3].raw, masks[1][3].material,
        masks[1][3].back_material, masks[1][3].layer, masks[1][2].attributes, ink.raw])
      masks[1][1].entities.fail_add = true if failure_kind == :native
      real_partition = partition.method(:partition)
      partitioner = lambda do |white, ink_rows, opts|
        if failure_kind == :partition && white.first[:entity_id] == masks[1][3].object_id
          raise partition::Error, 'fictional exact cell budget exceeded'
        end
        real_partition.call(white, ink_rows, opts)
      end
      result = partition.stub(:partition, partitioner) do
        Subject.compose!(masks.map(&:first), [text], :continue_mask_failures => true)
      end
      assert_equal 2, result[:composed_groups]
      assert_equal 1, result[:failed_groups]
      assert_equal 0, result[:unchanged_no_ink_groups]
      assert_in_delta 6.0, result[:removed_area], 1.0e-10
      assert masks[0][2].hidden? && masks[2][2].hidden?
      refute masks[1][2].hidden?
      assert masks[1][2].valid? && masks[1][3].valid?
      stage = masks[1][1].entities.stage
      failure_kind == :native ? assert(stage.erased) : assert_nil(stage)
      detail = result[:mask_failures].first
      assert_equal true, detail[:local_cleanup_verified]
      assert_equal 1, detail[:mask_index]
      assert_equal [0,101], detail[:pdf_paint_order]
      assert_equal [1,201], detail[:svg_paint_order]
      assert_equal [0.0,0.0,4.0,4.0], detail[:white_bbox]
      assert_equal ['text_span:1:84'], detail[:source_span_ids]
      assert_equal before, Marshal.dump([masks[1][3].raw, masks[1][3].material,
        masks[1][3].back_material, masks[1][3].layer, masks[1][2].attributes, ink.raw])
    end
  end

  def test_continuation_does_not_hide_terminal_errors_or_uncertain_stage_cleanup
    control = BlueCollarSystems::PDFVectorImporter::ImportRunControl
    [control::ImportCancelled.new([],1,{}), control::ResumeMismatch.new('changed journal'),
      control::RollbackFailure.new('uncertain rollback')].each do |stop|
      mask, wrapper, source, = preserved_mask([rect(0,0,4,4)])
      peer, later, = preserved_mask([rect(0,0,4,4)], 1)
      _white, text, = fixture
      wrapper.entities.fail_add = true
      creator = wrapper.entities.method(:add_group)
      wrapper.entities.define_singleton_method(:add_group) do
        stage = creator.call
        adder = stage.entities.method(:add_group)
        stage.entities.define_singleton_method(:add_group) do
          cell = adder.call
          cell.entities.define_singleton_method(:add_face) { |_points| raise stop }
          cell
        end
        stage
      end
      actual = assert_raises(stop.class) do
        Subject.compose!([mask,peer], [text], :continue_mask_failures => true)
      end
      assert_same stop, actual
      assert wrapper.entities.stage.erased
      refute source.hidden?
      assert_nil later.entities.stage
    end
    mask, wrapper, source, = preserved_mask([rect(0,0,4,4)])
    peer, later, = preserved_mask([rect(0,0,4,4)], 1)
    _white, text, = fixture
    wrapper.entities.fail_add = true
    creator = wrapper.entities.method(:add_group)
    wrapper.entities.define_singleton_method(:add_group) do
      stage = creator.call
      stage.define_singleton_method(:erase!) { false }
      stage
    end
    assert_raises(control::RollbackFailure) do
      Subject.compose!([mask,peer], [text], :continue_mask_failures => true)
    end
    assert wrapper.entities.stage.valid?
    refute source.hidden?
    assert_nil later.entities.stage
  end

  def test_failure_context_is_bounded_without_losing_total_failed_count
    partition = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
    count = Subject::MAX_MASK_FAILURE_DETAILS + 3
    masks = count.times.map { |i| preserved_mask([rect(0,0,4,4)], i) }
    _white, text, = fixture
    result = partition.stub(:partition, lambda { |*_args|
      raise partition::Error, 'fictional cell budget exceeded C:/private/shop/drawing.pdf ' + 'x' * 1000
    }) do
      Subject.compose!(masks.map(&:first), [text], :continue_mask_failures => true)
    end
    assert_equal count, result[:failed_groups]
    assert_equal Subject::MAX_MASK_FAILURE_DETAILS, result[:mask_failures].length
    assert_equal 3, result[:mask_failure_details_omitted]
    assert_equal 0, result[:composed_groups]
    assert_equal 0, result[:unchanged_no_ink_groups]
    result[:mask_failures].each do |row|
      assert_operator row[:detail].length, :<=, 180
      refute_includes row[:detail], 'private/shop'
      assert_match(/PlanarRegionPartition::Error/, row[:error_class])
    end
    masks.each do |_record, wrapper, source, original|
      assert_nil wrapper.entities.stage
      assert source.valid? && original.valid?
      refute source.hidden?
    end
  end

  def test_destroyed_mask_wrapper_is_never_a_restored_failure_or_an_unchanged_success
    control = BlueCollarSystems::PDFVectorImporter::ImportRunControl
    mask, wrapper, source, original = preserved_mask([rect(0,0,4,4)])
    peer, later, = preserved_mask([rect(0,0,4,4)], 1)
    _white, text, = fixture
    creator = wrapper.entities.method(:add_group)
    wrapper.entities.define_singleton_method(:add_group) do
      stage = creator.call
      adder = stage.entities.method(:add_group)
      stage.entities.define_singleton_method(:add_group) do
        cell = adder.call
        cell.entities.define_singleton_method(:add_face) do |_points|
          wrapper.erase!
          raise 'fictional owner invalidation while original definition children remain valid'
        end
        cell
      end
      stage
    end
    error = assert_raises(control::RollbackFailure) do
      Subject.compose!([mask,peer], [text], :continue_mask_failures => true)
    end
    assert_match(/owner was destroyed/, error.message)
    assert source.valid? && original.valid?
    assert wrapper.entities.stage.erased
    assert_nil later.entities.stage
    mask, wrapper, source, original = preserved_mask([rect(0,0,4,4),rect(1,1,3,3)])
    ink = [record(rect(1.5,1.5,2.5,2.5))]
    white = Subject.snapshots(wrapper, wrapper.transformation, false)
    wrapper.erase!
    assert_raises(control::RollbackFailure) do
      Subject.compose_group!(wrapper, wrapper.transformation, white, ink,
        :continue_mask_failures => true, :preserve_source => true)
    end
    assert source.valid? && original.valid?
    assert_nil wrapper.entities.stage
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

  def test_partition_cancellation_keeps_its_terminal_type_and_original_ownership
    white, text, original, ink = fixture
    error = BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled.new([1], 2, {})
    partition = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
    partition.stub(:partition, lambda { |*_args| raise error }) do
      raised = assert_raises(error.class) do
        Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
      end
      assert_same error, raised
    end
    assert_nil white.entities.stage
    refute original.erased
    refute ink.erased
    refute text.erased
    assert_empty white.entities.erased
  end

  def cancelling_controller(stage, after_work = false)
    BlueCollarSystems::PDFVectorImporter::ImportRunControl::Controller.new(
      :pages => [1], :requested_mode => :glyphs,
      :cancel_probe => lambda do |snapshot|
        snapshot[:stage] == stage && (!after_work || snapshot[:completed] > 0)
      end)
  end

  def test_real_controller_cancels_partial_native_cells_without_erasing_source_or_peer_text
    white, text, original, ink = fixture
    before = Marshal.dump(ink.raw)
    original.attributes['source_fill_original'] = true
    controller = cancelling_controller(:white_mask_cells, true)
    assert_raises(BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled) do
      Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true,
                          :preserve_source => true }], [text],
                       :run_controller => controller, :page_number => 1)
    end
    stage = white.entities.stage
    refute_nil stage
    assert stage.erased
    assert_operator stage.entities.items.length, :>, 0, 'some private cells were constructed before Esc'
    refute original.erased
    refute text.erased
    refute ink.erased
    assert_equal before, Marshal.dump(ink.raw)
    assert_empty white.entities.erased
    refute original.respond_to?(:hidden?) && original.hidden?
  end

  def test_real_controller_cancels_exact_partition_before_creating_native_stage
    white, text, original, ink = fixture
    controller = cancelling_controller(:white_mask_intersections)
    assert_raises(BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled) do
      Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }],
        [text], :run_controller => controller, :page_number => 1)
    end
    assert_nil white.entities.stage
    refute original.erased
    refute ink.erased
  end

  def test_cancelled_stage_that_host_does_not_erase_is_an_uncertain_rollback
    white, text, original, ink = fixture
    add_group = white.entities.method(:add_group)
    white.entities.define_singleton_method(:add_group) do
      stage = add_group.call
      stage.define_singleton_method(:erase!) { true }
      stage
    end
    controller = cancelling_controller(:white_mask_cells, true)
    error = assert_raises(BlueCollarSystems::PDFVectorImporter::ImportRunControl::RollbackFailure) do
      Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }],
        [text], :run_controller => controller, :page_number => 1)
    end
    assert_match(/cancelled white-mask rollback failed/, error.message)
    refute original.erased
    refute ink.erased
    assert white.entities.stage.valid?
  end

  def test_nested_mask_cancellation_reaches_page_boundary_without_a_step_down_warning
    require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'
    importer = BlueCollarSystems::PDFVectorImporter
    white, text, original, ink = fixture
    stats = {}
    error = assert_raises(importer::ImportRunControl::ImportCancelled) do
      importer.keep_page_on_page_stage_failure(stats, 1, 'white_areas', 'x', 'y') do
        Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }],
          [text], :run_controller => cancelling_controller(:white_mask_cells, true), :page_number => 1)
      end
    end
    assert_equal 1, error.next_page
    refute stats.key?(:page_step_downs)
    refute original.erased
    refute ink.erased
    assert white.entities.stage.erased
  end

  def test_top_level_composition_keeps_throwing_cleanup_terminal_at_the_page_boundary
    require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'
    importer = BlueCollarSystems::PDFVectorImporter
    white, text, original, ink = fixture
    add_group = white.entities.method(:add_group)
    white.entities.define_singleton_method(:add_group) do
      stage = add_group.call
      stage.define_singleton_method(:erase!) { raise 'fictional host erase failure' }
      stage
    end
    stats = {}
    error = assert_raises(importer::ImportRunControl::RollbackFailure) do
      importer.keep_page_on_page_stage_failure(stats, 1, 'white_areas', 'x', 'y') do
        Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }],
          [text], :run_controller => cancelling_controller(:white_mask_cells, true), :page_number => 1)
      end
    end
    assert_equal importer::ImportRunControl::RollbackFailure, error.class
    assert_match(/cancelled white-mask rollback failed: RuntimeError/, error.message)
    refute stats.key?(:page_step_downs)
    refute original.erased
    refute ink.erased
    refute text.erased
    assert white.entities.stage.valid?
  end

  # Production composition and page fallback boundaries; only native entity
  # mutation APIs fail here. The first real emitted private cell is retained
  # until rollback, so a live cleanup failure cannot pass as a clean fallback.
  def with_noncancel_failure(cleanup, late = false, visibility = :normal,
                            already_hidden = false, direct = false,
                            preserve_source = late, continue_failures = false)
    require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'
    importer = BlueCollarSystems::PDFVectorImporter
    white, text, original, ink = fixture
    owners = [original]
    if late
      canonical = Group.new(Entities.new([original]))
      canonical.material = :source_owner_colour if canonical.respond_to?(:material=)
      canonical.attributes['source_fill_original'] = true
      owners = [canonical]
      if already_hidden
        hidden = Group.new(Entities.new([Face.new([rect(8, 8, 9, 9)])]))
        hidden.hidden = true
        hidden.attributes['source_fill_original'] = true
        owners << hidden
      end
      white.entities.items.replace(owners)
      setter = canonical.method(:hidden=)
      canonical.define_singleton_method(:hidden=) do |value|
        if value == false && hidden? && visibility != :normal
          raise 'fictional source visibility restore failed' if visibility == :throwing
          next false
        end
        setter.call(value)
      end
    end
    original.material = :original_front_colour
    original.back_material = :original_back_colour
    original.layer = :original_source_layer
    original.attributes['source_owner_receipt'] = 'fictional-source-owner'
    source_before = Marshal.dump([original.raw, original.material,
      original.back_material, original.layer, original.attributes, ink.raw])
    original_hidden = owners.map(&:hidden?)
    native_error = RuntimeError.new(late ? 'fictional post-hide stage attribute failure' :
                                         'fictional second native cell construction failure')
    native_adds = 0
    creator = white.entities.method(:add_group)
    white.entities.define_singleton_method(:add_group) do
      stage = creator.call
      if cleanup == :silent
        stage.define_singleton_method(:erase!) { false }
      elsif cleanup == :throwing
        stage.define_singleton_method(:erase!) { raise 'fictional stage erase failed' }
      end
      if late
        attributes = stage.method(:set_attribute)
        stage.define_singleton_method(:set_attribute) do |dictionary, key, value|
          raise native_error if key == 'planar_white_knockout'
          attributes.call(dictionary, key, value)
        end
      else
        container_creator = stage.entities.method(:add_group)
        stage.entities.define_singleton_method(:add_group) do
          container = container_creator.call
          adder = container.entities.method(:add_face)
          container.entities.define_singleton_method(:add_face) do |points|
            native_adds += 1
            raise native_error if native_adds == 2
            adder.call(points)
          end
          container
        end
      end
      stage
    end
    opts = {:preserve_source => preserve_source, :continue_mask_failures => continue_failures}
    operation = lambda do
      if direct
        Subject.compose_group!(white, white.transformation,
          Subject.snapshots(white, white.transformation, false),
          Subject.collect_text_faces([text]), opts)
      else
        Subject.compose!([{:group => white, :fill_rgb => [1,1,1],
                          :before_text => true, :preserve_source => preserve_source}], [text],
                          :continue_mask_failures => continue_failures)
      end
    end
    yield importer, operation, {
      :white => white, :text => text, :original => original, :ink => ink,
      :owners => owners, :original_hidden => original_hidden,
      :source_before => source_before, :native_error => native_error,
      :native_adds => lambda { native_adds }
    }
  end

  def assert_uncertain_noncancel_cleanup(cleanup, late = false, visibility = :normal)
    with_noncancel_failure(cleanup, late, visibility) do |importer, operation, run|
      stats = {}
      error = assert_raises(importer::ImportRunControl::RollbackFailure) do
        importer.keep_page_on_page_stage_failure(stats, 1, 'white_areas', 'x', 'y') { operation.call }
      end
      assert_match(/white-mask rollback failed/, error.message)
      refute stats.key?(:page_step_downs), 'uncertain cleanup must stop at the page boundary'
      if cleanup == :success
        refute run[:white].entities.stage.valid?, 'private stage cleanup is still attempted'
      else
        assert run[:white].entities.stage.valid?
        assert_operator Subject.partition_faces(run[:white].entities.stage.entities).length, :>, 0
      end
      assert run[:original].valid?
      assert run[:ink].valid?
      assert run[:text].valid?
      assert_equal 2, run[:native_adds].call unless late
    end
  end

  def test_noncancel_second_cell_failure_with_silent_erase_stops_the_page
    assert_uncertain_noncancel_cleanup(:silent)
  end

  def test_noncancel_second_cell_failure_with_throwing_erase_stops_the_page
    assert_uncertain_noncancel_cleanup(:throwing)
  end

  def test_noncancel_successful_cleanup_preserves_the_original_error
    with_noncancel_failure(:success, false, :normal, false, true) do |_importer, operation, run|
      assert_same run[:native_error], assert_raises(RuntimeError) { operation.call }
      refute run[:white].entities.stage.valid?
      assert run[:original].valid?
      assert run[:ink].valid?
    end
  end

  def test_opt_in_post_hide_failure_restores_existing_visibility_before_continuing
    with_noncancel_failure(:success, true, :normal, true, false, true, true) do |_importer, operation, run|
      result = operation.call
      assert_equal 1, result[:failed_groups]
      assert_equal 0, result[:composed_groups]
      assert_equal run[:original_hidden], run[:owners].map(&:hidden?)
      assert run[:owners].all?(&:valid?)
      assert run[:white].entities.stage.erased
      assert_equal run[:source_before], Marshal.dump([run[:original].raw,
        run[:original].material, run[:original].back_material,
        run[:original].layer, run[:original].attributes, run[:ink].raw])
      assert_equal 'RuntimeError', result[:mask_failures].first[:error_class]
    end
    [[:silent,false,:normal], [:throwing,false,:normal],
     [:success,true,:silent], [:success,true,:throwing]].each do |cleanup, late, visibility|
      with_noncancel_failure(cleanup, late, visibility, false, false, late, true) do |importer, operation, _run|
        assert_raises(importer::ImportRunControl::RollbackFailure) { operation.call }
      end
    end
    with_noncancel_failure(:success, true, :normal, false, false, false, true) do |importer, operation, _run|
      assert_raises(importer::ImportRunControl::RollbackFailure) { operation.call }
    end
  end

  def test_noncancel_successful_cleanup_remains_eligible_for_page_fallback
    with_noncancel_failure(:success) do |importer, operation, run|
      stats = {}
      result = importer.keep_page_on_page_stage_failure(stats, 1, 'white_areas', 'x', 'y') { operation.call }
      assert_equal false, result
      assert_equal 1, stats[:page_step_downs].length
      refute run[:white].entities.stage.valid?
      assert run[:original].valid?
      assert run[:ink].valid?
      assert_equal run[:source_before], Marshal.dump([run[:original].raw,
        run[:original].material, run[:original].back_material,
        run[:original].layer, run[:original].attributes, run[:ink].raw])
    end
  end

  def test_noncancel_silent_source_visibility_restore_stops_the_page
    assert_uncertain_noncancel_cleanup(:success, true, :silent)
  end

  def test_noncancel_throwing_source_visibility_restore_stops_the_page
    assert_uncertain_noncancel_cleanup(:success, true, :throwing)
  end

  def test_noncancel_successful_rollback_keeps_preexisting_hidden_source_owner
    with_noncancel_failure(:success, true, :normal, true) do |importer, operation, run|
      stats = {}
      assert_equal false, importer.keep_page_on_page_stage_failure(stats, 1, 'white_areas', 'x', 'y') { operation.call }
      assert_equal [false, true], run[:original_hidden]
      assert_equal run[:original_hidden], run[:owners].map(&:hidden?)
      refute run[:white].entities.stage.valid?
      assert run[:owners].all?(&:valid?)
      assert_equal run[:source_before], Marshal.dump([run[:original].raw,
        run[:original].material, run[:original].back_material,
        run[:original].layer, run[:original].attributes, run[:ink].raw])
    end
  end

  def test_noncancel_nonpreserving_swap_failure_with_destroyed_original_stops_the_page
    with_noncancel_failure(:success, true, :normal, false, false, false) do |importer, operation, run|
      stats = {}
      error = assert_raises(importer::ImportRunControl::RollbackFailure) do
        importer.keep_page_on_page_stage_failure(stats, 1, 'white_areas', 'x', 'y') { operation.call }
      end
      assert_match(/white-mask rollback failed/, error.message)
      refute stats.key?(:page_step_downs)
      refute run[:white].entities.stage.valid?
      assert run[:owners].any? { |owner| !owner.valid? }, 'original ownership really was destroyed before failure'
      assert run[:ink].valid?
      assert run[:text].valid?
    end
  end

  def test_later_unknown_and_translucent_masks_do_not_change
    white, text, original, = fixture
    masks = [
      { :group => white, :fill_rgb => [1, 1, 1], :paint_order => [0, 9] },
      { :group => white, :fill_rgb => [1, 1, 1] },
      { :group => white, :fill_rgb => [1, 1, 1], :opacity => 0.5, :before_text => true }
    ]
    receipt = Subject.compose!(masks, [{ :group => text, :paint_order => [0, 4] }])
    assert_equal 0, receipt[:composed_groups]
    assert_equal 1, receipt[:skipped_nonwhite]
    assert_equal 2, receipt[:skipped_unproven_order]
    refute original.erased
    assert_nil white.entities.stage
  end

  def test_coloured_composition_preserves_exact_editable_source_and_ink_in_separate_owners
    white, text, original, ink = fixture
    original.material = original.back_material = :pale_source
    canonical = Group.new(Entities.new([original]))
    canonical.attributes['source_fill_original'] = true
    white.entities.items.replace([canonical])
    before = Marshal.dump([original.raw,ink.raw])
    receipt = Subject.compose!([{ :group=>white, :fill_rgb=>[1.0,1.0,252.0/255],
      :opacity=>1.0, :paint_order=>[0,2], :preserve_source=>true }],
      [{:group=>text,:paint_order=>[0,3]}])
    assert_equal 1, receipt[:composed_groups]
    assert_in_delta 3.0, receipt[:removed_area], 1.0e-10
    assert canonical.hidden?
    refute canonical.erased
    refute original.erased
    refute ink.erased
    assert_equal before, Marshal.dump([original.raw,ink.raw])
    visible = Subject.partition_faces(white.entities.stage.entities)
    assert visible.all? { |face| face.material == :pale_source && face.back_material == :pale_source }
    assert white.entities.stage.attributes['source_fill_composed_visible']
    # The source rectangle stays editable, but cannot cover text when the
    # final displayed mask census is read again after save/reopen.
    snapshots = Subject.snapshots(white,Geom::Transformation.new,false)
    assert_in_delta 13.0, Subject.source_area(snapshots), 1.0e-8
  end

  def test_failed_coloured_partition_preserves_visible_original_and_source_ink
    white, text, original, ink = fixture
    canonical = Group.new(Entities.new([original]))
    canonical.attributes['source_fill_original'] = true
    white.entities.items.replace([canonical])
    white.entities.fail_add = true
    assert_raises(ContractError) do
      Subject.compose!([{ :group=>white, :fill_rgb=>[1.0,0.8,0.6], :opacity=>1.0,
        :paint_order=>[0,2], :preserve_source=>true }],[{:group=>text,:paint_order=>[0,3]}])
    end
    refute canonical.hidden?
    refute canonical.erased
    refute original.erased
    refute ink.erased
    assert white.entities.stage.erased
  end

  def test_only_certified_nonsemantic_source_unit_roots_supply_flat_ink
    root = Group.new(Entities.new([Face.new([rect(0,0,1,1)])]))
    root.attributes['source_unit_id'] = 'svg_glyph_placements:page:1'
    root.attributes['source_placement_indices'] = [0,1,2]
    assert_empty Subject.collect_text_faces([root])
    faces = Subject.collect_text_faces([{:group=>root,:verified_source_unit=>true}])
    assert_equal 1, faces.length
    assert_nil faces.first[:source_span_id]
    assert_equal [0,1,2], faces.first[:source_placement_indices]
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

  def alternate_partition_fixture
    delta = 2.0**-52
    original = Face.new([rect(0, 0, 4, 4)])
    original.attributes['source_fill_original'] = true
    white = Group.new(Entities.new([original]))
    white.entities.native_tolerance = Subject::NATIVE_VERTEX_TOLERANCE
    ink = [Face.new([rect(1, 0.5, 2, 1.5)]), Face.new([rect(1 + delta, 2, 3, 3)])]
    text = Group.new(Entities.new(ink))
    text.owner = true
    [white, text, original, ink]
  end

  def test_exact_quarter_turn_removes_only_artificial_skinny_partition_seams
    white, text, original, ink = alternate_partition_fixture
    sources = Subject.snapshots(white, white.transformation, false)
    physical_ink = Subject.collect_text_faces([text])
    before = Marshal.dump([sources, physical_ink])
    cells = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition.partition(sources, physical_ink)
    assert_raises(Subject::ConstructionScaleBudgetError) { Subject.partition_construction_scale(cells) }
    restored = Subject.rotated_construction_partition(sources, physical_ink, cells)
    assert_equal Subject::CONSTRUCTION_SCALE, Subject.partition_construction_scale(restored)
    [:white, :ink].each do |kind|
      assert_equal cells.select { |cell| cell[:region] == kind }.inject(0) { |sum, cell| sum + cell[:area] },
                   restored.select { |cell| cell[:region] == kind }.inject(0) { |sum, cell| sum + cell[:area] }
    end
    restored.each do |cell|
      assert_equal cell[:area] * 2,
        BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.signed_area2(cell[:loop])
      assert cell[:loop].flatten.all? { |value| value.is_a?(Rational) }
    end
    assert_equal before, Marshal.dump([sources, physical_ink])
    source_geometry = Marshal.dump(ink.map(&:raw))
    result = Subject.compose!([{ :group => white, :fill_rgb => [1,1,1],
      :before_text => true, :preserve_source => true }], [text])
    assert_equal 1, result[:composed_groups]
    assert original.hidden?
    refute original.erased
    assert_equal source_geometry, Marshal.dump(ink.map(&:raw))
    stage = white.entities.stage
    retained = Subject.snapshots(stage, stage.transformation, false)
    assert retained.any? { |record| record[:loops].flatten(1).include?([1 + 2.0**-52, 2.0, 0.0]) },
      'the original one-ULP source boundary coordinate is retained, not snapped'
    refute retained.any? { |record| Subject.contains?(record, [1.5, 1, 0]) }
    assert retained.any? { |record| Subject.contains?(record, [1.5, 1.75, 0]) }
  end

  def test_ordinary_partition_does_not_use_an_alternate_projection
    white, text, original, _ink = fixture
    Subject.stub(:rotated_construction_partition, lambda { |*_args| raise 'unexpected alternate partition' }) do
      result = Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
      assert_equal 1, result[:composed_groups]
    end
    assert original.erased
  end

  def test_other_contract_failures_cannot_trigger_projection_even_with_the_same_message
    white, text, original, ink = alternate_partition_fixture
    error = nil
    Subject.stub(:partition_construction_scale, lambda { |_cells|
      raise ContractError, 'exact white-mask construction scale budget exceeded'
    }) do
      Subject.stub(:rotated_construction_partition, lambda { |*_args| raise 'unexpected alternate partition' }) do
        error = assert_raises(ContractError) do
          Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
        end
      end
    end
    assert_includes error.message, 'scale budget exceeded'
    refute original.erased
    assert ink.none?(&:erased)
    assert_nil white.entities.stage
  end

  def test_scale_exhaustion_tries_at_most_one_alternate_and_keeps_originals_on_failure
    white, text, original, ink = alternate_partition_fixture
    scale_calls, alternate_calls = 0, 0
    Subject.stub(:partition_construction_scale, lambda { |_cells|
      scale_calls += 1
      raise Subject::ConstructionScaleBudgetError, 'exact white-mask construction scale budget exceeded'
    }) do
      Subject.stub(:rotated_construction_partition, lambda { |_white, _ink, cells, _opts|
        alternate_calls += 1
        cells
      }) do
        assert_raises(ContractError) do
          Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
        end
      end
    end
    assert_equal 2, scale_calls
    assert_equal 1, alternate_calls
    refute original.erased
    assert ink.none?(&:erased)
    assert_nil white.entities.stage
  end

  def test_alternate_projection_does_not_discard_a_real_unconstructible_white_feature
    epsilon = 2.0**-70
    white = [record(rect(0,0,1,1))]
    ink = [record(rect(epsilon,0,1,1))]
    cells = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition.partition(white, ink)
    assert_raises(Subject::ConstructionScaleBudgetError) { Subject.partition_construction_scale(cells) }
    restored = Subject.rotated_construction_partition(white, ink, cells)
    assert_raises(Subject::ConstructionScaleBudgetError) { Subject.partition_construction_scale(restored) }
    assert_equal epsilon.to_r, restored.select { |cell| cell[:region] == :white }.inject(0) { |sum, cell| sum + cell[:area] }
    assert restored.any? { |cell| cell[:loop].any? { |point| point[0] == epsilon.to_r } }
  end

  def test_alternate_projection_cancellation_and_exact_coverage_failure_propagate
    white, text, _original, _ink = alternate_partition_fixture
    sources = Subject.snapshots(white, white.transformation, false)
    ink = Subject.collect_text_faces([text])
    partition = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
    cells = partition.partition(sources, ink)
    controller = BlueCollarSystems::PDFVectorImporter::ImportRunControl::Controller.new(
      :pages => [1], :requested_mode => :glyphs, :cancel_probe => lambda { true })
    assert_raises(BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled) do
      Subject.rotated_construction_partition(sources, ink, cells, :run_controller => controller, :page_number => 1)
    end
    restored = Subject.rotated_construction_partition(sources, ink, cells)
    rotated = restored.map do |cell|
      cell.merge(:loop => cell[:loop].map { |point| [point[1], -point[0], point[2]] })
    end
    partition.stub(:partition, rotated[0...-1]) do
      error = assert_raises(ContractError) { Subject.rotated_construction_partition(sources, ink, cells) }
      assert_includes error.message, 'changed exact source coverage'
    end
    reversed = rotated.map(&:dup)
    reversed.first[:loop] = reversed.first[:loop].reverse
    partition.stub(:partition, reversed) do
      error = assert_raises(ContractError) { Subject.rotated_construction_partition(sources, ink, cells) }
      assert_includes error.message, 'changed exact cell area or orientation'
    end
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

  def test_legacy_single_argument_scale_cannot_change_source_coordinates
    legacy_scaling = lambda do |*values|
      if values.length == 1
        # SketchUp2017 stores the reciprocal in the homogeneous matrix entry.
        Geom::Transformation.new(1.0, [0,0,0], 1.0 / values.first)
      else
        raise 'nonuniform test scale' unless values.length == 3 && values.uniq.length == 1
        Geom::Transformation.new(values.first)
      end
    end
    [0.0, 2.0**-35].each do |delta|
      original = Face.new([rect(2.1, 0.1, 6.1, 4.1)])
      white = Group.new(Entities.new([original]))
      parent = Geom::Transformation.new(1.0, [0,36,0])
      white.transformation = parent
      white.entities.native_tolerance = Subject::NATIVE_VERTEX_TOLERANCE
      text = Group.new(Entities.new([Face.new([rect(3.1,0.6,5.1,1.6)]),
                                    Face.new([rect(3.1 + delta,1.1,5.1,2.6)])]))
      text.owner = true
      text.transformation = parent
      sources = Subject.snapshots(white, parent, false)
      ink = Subject.collect_text_faces([text])
      cells = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition.partition(sources, ink)
      expected = cells.select { |cell| cell[:region] == :white }.flat_map do |cell|
        cell[:loop].map { |point| point.map(&:to_f) }
      end.uniq.sort
      Geom::Transformation.stub(:scaling, legacy_scaling) do
        Subject.compose!([{ :group => white, :fill_rgb => [1,1,1], :before_text => true }], [text])
      end
      stage = white.entities.stage
      actual = Subject.snapshots(stage, parent * stage.transformation, false).flat_map do |record|
        record[:loops].flatten(1)
      end.uniq.sort
      assert_equal expected, actual, 'native frame must recover every source vertex exactly'
      assert original.erased
    end
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
    error = assert_raises(Subject::ConstructionScaleBudgetError) { Subject.partition_construction_scale([too_thin]) }
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
    error = assert_raises(Subject::ConstructionFrameError) do
      Subject.verify_adaptive_page_points!(mapped, origin, scale, page, identity, changed)
    end
    assert_match(/changed the final page transform/, error.message)
    error = assert_raises(Subject::ConstructionFrameError) do
      Subject.verify_adaptive_page_points!(mapped, origin, scale, changed, identity, page)
    end
    assert_match(/restore exact page coordinates/, error.message)
  end

  def test_binary_zero_origin_frame_restores_source_when_centered_decimal_frame_rounds
    cell = exact_cell(rect(0.1, 0.2, 0.7, 0.200003))
    origin = [0.4, 0.2000015, 0.0]
    scale = Subject.partition_construction_scale([cell])
    mapped = Subject.partition_construction_points([cell], origin, scale)
    page = Geom::Transformation.translation(Geom::Point3d.new(*origin)) *
           Geom::Transformation.scaling(1.0 / scale, 1.0 / scale, 1.0 / scale)
    identity = Geom::Transformation.new
    assert_raises(Subject::ConstructionFrameError) do
      Subject.verify_adaptive_page_points!(mapped, origin, scale, page, identity, page)
    end
    stage = Group.new(Entities.new)
    actual_origin, actual_scale, actual = Subject.partition_construction_frame!(
      stage, [cell], origin, scale, identity)
    assert_equal [0.0, 0.0, 0.0], actual_origin
    assert_operator actual_scale, :>=, scale
    assert_equal 0.0, Math.log2(actual_scale) % 1
    actual.each do |source, native|
      assert_equal source.map(&:to_f), Subject.page_point(native, actual_origin, actual_scale)
      on_page = native.transform(stage.transformation)
      assert_equal source.map(&:to_f), [on_page.x, on_page.y, on_page.z]
    end
    assert_empty stage.entities.to_a, 'no faces are created while selecting the frame'
  end

  def test_alternate_frame_cannot_hide_wrong_native_stage_or_retry_topology_errors
    cell = exact_cell(rect(0.1, 0.2, 0.7, 0.200003))
    origin, scale = [0.4, 0.2000015, 0.0], Subject.partition_construction_scale([cell])
    stage = Group.new(Entities.new)
    assignments = []
    stage.define_singleton_method(:transformation=) do |value|
      assignments << value
      @transformation = Geom::Transformation.new(value.scale, [1.0e-12, 0, 0])
    end
    assert_raises(Subject::ConstructionFrameError) do
      Subject.partition_construction_frame!(stage, [cell], origin, scale, Geom::Transformation.new)
    end
    assert_equal 2, assignments.length, 'only the original and bounded binary frames are considered'
    assert_empty stage.entities.to_a
    assignments.clear
    Subject.stub(:partition_construction_points, lambda { |*_args| raise ContractError, 'bad topology' }) do
      error = assert_raises(ContractError) do
        Subject.partition_construction_frame!(stage, [cell], origin, scale, Geom::Transformation.new)
      end
      assert_equal 'bad topology', error.message
    end
    assert_empty assignments, 'a topology error never invokes an alternate frame'
  end

  def test_binary_alternate_frame_still_enforces_absolute_coordinate_budget
    far = exact_cell(rect(2**20 + 0.1, 0.2, 2**20 + 0.7, 0.200003))
    origin = [2**20 + 0.4, 0.2000015, 0.0]
    stage = Group.new(Entities.new)
    # Reject only the first roundtrip, as the host may do after normalizing its
    # native matrix. The zero-origin retry must run the ordinary budget guards.
    Subject.stub(:verify_adaptive_page_points!, lambda { |*_args| raise Subject::ConstructionFrameError, 'native frame' }) do
      error = assert_raises(ContractError) do
        Subject.partition_construction_frame!(stage, [far], origin, 2.0**30, Geom::Transformation.new)
      end
      assert_match(/coordinate budget/, error.message)
    end
    assert_empty stage.entities.to_a
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

# Exact white-only construction still proves every discarded source-ink cell.
class PlanarWhiteKnockoutTest
  WhiteOnlyPartition = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
  WhiteOnlyControl = BlueCollarSystems::PDFVectorImporter::ImportRunControl

  def white_only_instrument_build(wrapper, &callback)
    observed = { :faces => [], :face_attempts => 0, :mesh_calls => 0 }
    stage_add = wrapper.entities.method(:add_group)
    wrapper.entities.define_singleton_method(:add_group) do
      stage = stage_add.call
      container_add = stage.entities.method(:add_group)
      stage.entities.define_singleton_method(:add_group) do
        container = container_add.call
        face_add = container.entities.method(:add_face)
        container.entities.define_singleton_method(:add_face) do |points|
          observed[:face_attempts] += 1
          face = face_add.call(points)
          if face
            observed[:faces] << face
            mesh = face.method(:mesh)
            face.define_singleton_method(:mesh) do |flags|
              observed[:mesh_calls] += 1
              mesh.call(flags)
            end
          end
          callback.call(face, container, stage, observed) if callback
          face
        end
        container
      end
      stage
    end
    observed
  end

  def white_only_physical_inputs(wrapper, text)
    [Subject.snapshots(wrapper, wrapper.transformation, false),
      Subject.collect_text_faces([text])]
  end

  def white_only_retained_geometry(wrapper)
    stage = wrapper.entities.stage
    return [] unless stage && stage.valid?
    Subject.snapshots(stage, wrapper.transformation * stage.transformation, false).map do |record|
      [record[:loops].map { |loop| Subject.canonical_loop(loop) },
       record[:material], record[:back_material], record[:layer]]
    end.sort_by { |row| row[0].inspect }
  end

  def assert_white_only_source_retained(wrapper, source, original, ink)
    assert wrapper.valid?
    assert source.valid?
    assert original.valid?
    assert ink.valid?
    refute source.hidden?
    assert wrapper.entities.stage.nil? || !wrapper.entities.stage.valid?
  end

  def test_white_only_retained_exact_geometry_requires_no_discarded_native_ink_cells
    white, text, original, ink = fixture
    counts = white_only_instrument_build(white)
    inputs = white_only_physical_inputs(white, text)
    cells = WhiteOnlyPartition.partition(*inputs)
    removed = Subject.compose_group!(white, white.transformation, *inputs)
    expected = cells.select { |cell| cell[:region] == :white }.map do |cell|
      [Subject.canonical_loop(cell[:loop].map { |point| point.map(&:to_f) })]
    end.sort_by(&:inspect)
    actual = white_only_retained_geometry(white).map(&:first).sort_by(&:inspect)
    assert_equal expected, actual
    assert_equal 3.0, removed
    assert_equal 9, cells.length
    assert_equal 5, counts[:face_attempts]
    assert_equal 5, counts[:mesh_calls]
    assert_equal cells.count { |cell| cell[:region] == :white }, counts[:face_attempts]
    assert_operator counts[:face_attempts], :<, cells.length
    assert original.erased && ink.valid?
  end

  def test_white_only_all_source_cells_still_enter_scale_and_frame_proofs
    white, text, = fixture
    inputs = white_only_physical_inputs(white, text)
    expected = WhiteOnlyPartition.partition(*inputs)
    seen_scale, seen_frame = [], []
    scale = Subject.method(:partition_construction_scale)
    frame = Subject.method(:partition_construction_frame!)
    Subject.stub(:partition_construction_scale, lambda { |cells|
      seen_scale << cells.map { |cell| [cell[:region], cell[:area], cell[:loop]] }
      scale.call(cells)
    }) do
      Subject.stub(:partition_construction_frame!, lambda { |stage, cells, *args|
        seen_frame << cells.map { |cell| [cell[:region], cell[:area], cell[:loop]] }
        frame.call(stage, cells, *args)
      }) { Subject.compose_group!(white, white.transformation, *inputs) }
    end
    canonical = expected.map { |cell| [cell[:region], cell[:area], cell[:loop]] }
    assert_equal [canonical], seen_scale
    assert_equal [canonical], seen_frame
    assert expected.any? { |cell| cell[:region] == :ink }
  end

  def test_white_only_fully_ink_covered_path_still_constructs_classifies_and_erases_native_cells
    white, text, original, = fixture
    text.entities.items.replace([Face.new([rect(0,0,4,4)])])
    counts = white_only_instrument_build(white)
    inputs = white_only_physical_inputs(white, text)
    cells = WhiteOnlyPartition.partition(*inputs)
    assert cells.all? { |cell| cell[:region] == :ink }
    value = Subject.compose_group!(white, white.transformation, *inputs)
    assert_equal 16.0, value
    assert_equal cells.length, counts[:face_attempts]
    assert_equal counts[:face_attempts], counts[:mesh_calls]
    assert_operator counts[:face_attempts], :>, 0
    assert white.entities.stage.erased && original.erased
    assert_empty white.entities.stage.entities.to_a
  end

  def test_white_only_numeric_removed_area_has_explicit_uniform_exact_source_basis
    white, text, = fixture
    text.entities.items.replace([Face.new([rect(0,0,4,4)])])
    counts = white_only_instrument_build(white) do |face, _container, _stage, _observed|
      native_area = face.area
      face.define_singleton_method(:area) { native_area + 0.25 }
    end
    report = Subject.compose!([{:group=>white,:fill_rgb=>[1,1,1],:before_text=>true}],[text])
    assert_operator counts[:face_attempts], :>, 0
    assert_equal 16.0, report[:removed_area]
    assert_kind_of Float, report[:removed_area]
    assert_equal 'exact_source_partition', report[:removed_area_basis]
    assert_equal 1, report[:composed_groups]
  end

  def test_white_only_total_source_area_mismatch_cannot_hide_in_omitted_ink
    white, text, original, ink = fixture
    inputs = white_only_physical_inputs(white, text)
    # Keep an ink cell, but remove another positive cell from the full proof.
    all = WhiteOnlyPartition.partition(*inputs)
    cells = all[0...-1]
    assert cells.any? { |cell| cell[:region] == :ink }
    WhiteOnlyPartition.stub(:partition, cells) do
      error = assert_raises(ContractError) { Subject.compose_group!(white, white.transformation, *inputs) }
      assert_match(/changed source white area/, error.message)
    end
    assert_nil white.entities.stage
    assert original.valid? && ink.valid?
  end

  def test_white_only_bad_exact_cell_class_area_and_orientation_are_rejected
    [:outside, :bad_area, :reversed].each do |kind|
      white, text, original, ink = fixture
      inputs = white_only_physical_inputs(white, text)
      cells = Marshal.load(Marshal.dump(WhiteOnlyPartition.partition(*inputs)))
      cell = cells.find { |entry| entry[:region] == :ink }
      case kind
      when :outside then cell[:region] = :outside
      when :bad_area then cell[:area] += 1.to_r
      when :reversed then cell[:loop].reverse!
      end
      WhiteOnlyPartition.stub(:partition, cells) do
        assert_raises(ContractError) { Subject.compose_group!(white, white.transformation, *inputs) }
      end
      assert_nil white.entities.stage
      assert original.valid? && ink.valid?
    end
  end

  def test_white_only_extra_native_face_even_tiny_is_rejected_and_rolled_back
    mask, wrapper, source, original = preserved_mask([rect(0,0,4,4)])
    ink = Face.new([rect(1,1,3,3)]);text = Group.new(Entities.new([ink]));text.owner=true
    white_only_instrument_build(wrapper) do |_face, container, _stage, observed|
      if observed[:face_attempts] == 1
        container.entities.items << Face.new([rect(0,0,0.000001,0.000001)])
      end
    end
    error = assert_raises(ContractError) { Subject.compose!([mask],[text]) }
    assert_match(/roster changed/, error.message)
    assert_white_only_source_retained(wrapper,source,original,ink)
  end

  def test_white_only_missing_tiny_white_cell_below_area_tolerance_is_rejected
    delta = Rational(1,2**24)
    mask, wrapper, source, original = preserved_mask([rect(0,0,4,4)])
    ink = Face.new([rect(2+delta,0,4,4)]);text=Group.new(Entities.new([ink]));text.owner=true
    white_inputs, ink_inputs = white_only_physical_inputs(wrapper,text)
    make_cell = lambda do |loop, region|
      loop = loop.map { |point| point.map(&:to_r) }
      {:loop=>loop,:region=>region,:area=>BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary.signed_area2(loop)/2}
    end
    # First constructed Face is a real source-white strip, not a no-op or a
    # numeric zero. Its area is below the pre-existing whole-mask area bound.
    cells = [make_cell.call(rect(2,0,2+delta,4),:white),
      make_cell.call(rect(0,0,2,4),:white),make_cell.call(rect(2+delta,0,4,4),:ink)]
    assert_operator cells.first[:area].to_f, :<, 16.0 * 1.0e-7
    white_only_instrument_build(wrapper) do |_face,_container,_stage,observed|
      observed[:faces].first.erase! if observed[:face_attempts] == 2
    end
    WhiteOnlyPartition.stub(:partition,cells) do
      error = assert_raises(ContractError) { Subject.compose_group!(wrapper,
        wrapper.transformation,white_inputs,ink_inputs,:preserve_source=>true) }
      assert_match(/roster changed/,error.message)
    end
    assert_white_only_source_retained(wrapper,source,original,ink)
  end

  def test_white_only_retained_native_cell_cannot_be_reclassified_or_erased_as_ink_or_outside
    [:ink,:outside,nil].each do |wrong|
      mask, wrapper, source, original = preserved_mask([rect(0,0,4,4)])
      ink = Face.new([rect(1,1,3,3)]);text=Group.new(Entities.new([ink]));text.owner=true
      classify = Subject.method(:classify_cells)
      Subject.stub(:classify_cells, lambda { |*args|
        plan=classify.call(*args);plan.first[:region]=wrong;plan
      }) do
        error=assert_raises(ContractError) { Subject.compose!([mask],[text]) }
        assert_match(/changed exact source class/,error.message)
      end
      assert_white_only_source_retained(wrapper,source,original,ink)
    end
  end

  def test_white_only_native_area_change_nonfinite_and_negative_are_rejected
    [:changed,:nan,:negative].each do |kind|
      mask,wrapper,source,original=preserved_mask([rect(0,0,4,4)])
      ink=Face.new([rect(1,1,3,3)]);text=Group.new(Entities.new([ink]));text.owner=true
      white_only_instrument_build(wrapper) do |face,_container,_stage,observed|
        if observed[:face_attempts]==1
          area=face.area
          face.define_singleton_method(:area) do
            kind==:changed ? area*2 : (kind==:nan ? Float::NAN : -area)
          end
        end
      end
      assert_raises(ContractError) { Subject.compose!([mask],[text]) }
      assert_white_only_source_retained(wrapper,source,original,ink)
    end
  end

  def test_white_only_subtolerance_boundary_change_is_still_rejected
    mask,wrapper,source,original=preserved_mask([rect(0,0,4,4)])
    ink=Face.new([rect(1,1,3,3)]);text=Group.new(Entities.new([ink]));text.owner=true
    wrapper.entities.alter_points=lambda do |points|
      copy=points.dup;point=copy.first;copy[0]=Geom::Point3d.new(point.x+1.0e-8,point.y,point.z);copy
    end
    error=assert_raises(ContractError) { Subject.compose!([mask],[text]) }
    assert_match(/changed source boundary vertices/,error.message)
    assert_white_only_source_retained(wrapper,source,original,ink)
  end

  def test_white_only_construction_failure_and_opt_in_counters_preserve_originals
    mask,wrapper,source,original=preserved_mask([rect(0,0,4,4)])
    ink=Face.new([rect(1,1,3,3)]);text=Group.new(Entities.new([ink]));text.owner=true
    wrapper.entities.fail_add=true
    report=Subject.compose!([mask],[text],:continue_mask_failures=>true)
    assert_equal 1,report[:failed_groups]
    assert_equal 0,report[:composed_groups]
    assert_equal 0,report[:unchanged_no_ink_groups]
    assert_equal 0.0,report[:removed_area]
    assert_equal 'exact_source_partition',report[:removed_area_basis]
    assert_equal true,report[:mask_failures].first[:local_cleanup_verified]
    assert_white_only_source_retained(wrapper,source,original,ink)
  end

  def test_white_only_all_original_ink_coverage_probes_remain_required
    white,text,original,ink=fixture
    expected=Subject.collect_text_faces([text])
    real=Subject.method(:verify_ink_samples!);seen=[]
    Subject.stub(:verify_ink_samples!,lambda { |*args|
      seen << args.first
      real.call(*args)
    }) do
      Subject.compose!([{:group=>white,:fill_rgb=>[1,1,1],:before_text=>true}],[text])
    end
    assert_equal 1,seen.length
    assert_equal expected.map { |entry| entry[:loops] },seen.first.map { |entry| entry[:loops] }
    assert original.erased && ink.valid?
    geometry=Subject.snapshots(white.entities.stage,white.entities.stage.transformation,false)
    assert geometry.any? { |entry| Subject.contains?(entry,[2,2,0]) }, 'glyph counter remains white'
    refute geometry.any? { |entry| Subject.contains?(entry,[1.2,2,0]) }, 'physical ink is uncovered'
  end

  def test_white_only_one_shot_cancel_during_full_source_area_guard_is_terminal
    mask,wrapper,source,original=preserved_mask([rect(0,0,4,4)])
    ink=Face.new([rect(1,1,3,3)]);text=Group.new(Entities.new([ink]));text.owner=true
    error=WhiteOnlyControl::ImportCancelled.new([1],1,{})
    controller=Object.new;fired=false
    controller.define_singleton_method(:checkpoint!) do |stage,_details|
      if stage==:white_mask_partition && !fired
        fired=true;raise error
      end
      false
    end
    # Precompute the real partition without a controller so this one-shot
    # stop is specifically delivered by the new exact class-area guard.
    inputs=white_only_physical_inputs(wrapper,text)
    cells=WhiteOnlyPartition.partition(*inputs)
    raised=WhiteOnlyPartition.stub(:partition,cells) do
      assert_raises(error.class) { Subject.compose!([mask],[text],:run_controller=>controller) }
    end
    assert_same error,raised
    assert fired
    assert_white_only_source_retained(wrapper,source,original,ink)
    assert_nil wrapper.entities.stage
  end

  def test_white_only_tiny_ink_omitted_from_native_still_enters_clearance_and_may_fail
    white,text,original,ink=fixture
    inputs=white_only_physical_inputs(white,text);seen=[]
    error=Subject::ConstructionScaleBudgetError.new('exact white-mask construction scale budget exceeded')
    Subject.stub(:partition_construction_scale,lambda { |cells|
      seen << cells.map { |cell| cell[:region] }
      raise error
    }) do
      # One exact alternate is still allowed; its clearance cannot be bypassed
      # simply because only white native geometry would ultimately be needed.
      raised = assert_raises(ContractError) do
        Subject.compose_group!(white,white.transformation,*inputs)
      end
      assert_match(/construction scale budget exceeded/,raised.message)
    end
    assert_equal 2,seen.length
    assert seen.all? { |regions| regions.include?(:ink) && regions.include?(:white) }
    assert_nil white.entities.stage
    assert original.valid? && ink.valid?
  end

  def test_white_only_fresh_wrappers_for_same_entity_pass_explicit_identity_roster
    white,text,original,ink=fixture
    real=Subject.method(:partition_faces);active=false
    Subject.stub(:partition_faces,lambda do |entities|
      if active
        real.call(entities)
      else
        begin
          active=true
          # Fresh wrappers compare to their real native entity, while their
          # own Ruby object hash/eql identity is deliberately different.
          real.call(entities).map { |face| SimpleDelegator.new(face) }
        ensure
          active=false
        end
      end
    end) do
      report=Subject.compose!([{:group=>white,:fill_rgb=>[1,1,1],:before_text=>true}],[text])
      assert_equal 1,report[:composed_groups]
      assert_equal 3.0,report[:removed_area]
    end
    assert original.erased && ink.valid?
  end

  def test_white_only_duplicate_or_missing_native_identity_is_rejected
    [:missing,:duplicate].each do |kind|
      mask,wrapper,source,original=preserved_mask([rect(0,0,4,4)])
      ink=Face.new([rect(1,1,3,3)]);text=Group.new(Entities.new([ink]));text.owner=true
      white_only_instrument_build(wrapper) do |face,_container,_stage,_observed|
        face.define_singleton_method(:entityID) { kind==:missing ? nil : 42 }
      end
      error=assert_raises(ContractError) { Subject.compose!([mask],[text]) }
      assert_match(/unique entity identity/,error.message)
      assert_white_only_source_retained(wrapper,source,original,ink)
    end
  end

end
