require 'minitest/autorun'
require 'matrix'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/item_raster_display'

module Geom
  Point3d = Struct.new(:x, :y, :z) unless const_defined?(:Point3d)
  class Transformation
    def initialize(values = nil)
      @values = values || BlueCollarSystems::PDFVectorImporter::ItemRasterDisplay::IDENTITY.dup
    end
    def self.translation(point)
      values = BlueCollarSystems::PDFVectorImporter::ItemRasterDisplay::IDENTITY.dup
      values[12, 3] = [point.x, point.y, point.z]
      new(values)
    end
    def to_a; @values.dup; end
    def *(other)
      self.class.new(BlueCollarSystems::PDFVectorImporter::ItemRasterDisplay.multiply(to_a, other.to_a))
    end
    def inverse
      rows = Array.new(4) { |row| Array.new(4) { |col| @values[col * 4 + row] } }
      inverted = Matrix.rows(rows).inverse
      self.class.new(Array.new(16) { |i| inverted[i % 4, i / 4] })
    end
  end
end

class ItemRasterDisplayTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::ItemRasterDisplay
  Error = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError
  Bounds = Struct.new(:min, :max)
  class Entities
    def initialize(items); @items = items; end
    def to_a; @items.dup; end
  end
  class Entity
    attr_accessor :transformation, :bounds, :width, :height
    attr_reader :entities, :persistent_id, :entityID, :typename, :attrs
    def initialize(id, kind, children = [], attrs = {})
      @persistent_id, @entityID, @typename = id, id + 1000, kind
      @entities, @attrs = Entities.new(children), attrs
      @transformation = Geom::Transformation.new
      @bounds = Bounds.new(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 0))
    end
    def valid?; true; end
    def get_attribute(_dictionary, key, default = nil); @attrs.fetch(key, default); end
  end

  def setup
    @context = { :page => 1, :media_box => [10.0, 20.0, 730.0, 740.0],
      :page_rotation => 0, :scale => 1.0, :page_y_offset => 4.0,
      :source_pdf_sha256 => 'a' * 64 }
    @stats = { :normalized_input_sha256 => 'a' * 64, :raster_delivery_records => [] }
    @crops = []
    @image = add_image(2, 1, [82.0, 92.0, 226.0, 164.0])
    @text = Entity.new(3, 'Group', [], 'source_span_id' => 'text_span:1:2')
    @text.bounds = Bounds.new(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(3, 2, 0.2))
    @page = Entity.new(1, 'Group', [@image, @text])
  end

  def add_image(id, span, box)
    sid = "text_span:1:#{span}"
    artifact = {
      :source_span_id => sid, :page_number => 1, :page_rotation => @context[:page_rotation],
      :source_pdf_sha256 => 'a' * 64, :source_box => box,
      :visual_pixel_sha256 => 'b' * 64, :page_render_content_sha256 => 'c' * 64
    }
    [:source_crop_binding_verified, :source_pdf_binding_verified, :page_binding_verified,
      :alpha_channel_verified, :transparent_background_verified, :visible_pixel_verified,
      :page_render_once_verified, :visual_pixel_binding_verified].each { |key| artifact[key] = true }
    record = { :page => 1, :source_span_ids => [sid], :delivery_scope => :item_raster,
      :resulting_entity_ids => ["persistent_id:#{id}"], :artifact_evidence => artifact }
    @stats[:raster_delivery_records] << record
    corners = Subject.source_corners(artifact, @context)
    image = Entity.new(id, 'Image', [], 'source_span_id' => sid,
      'renderer' => 'ghostscript_transparent_page_crop', 'raster_source_pdf_sha256' => 'a' * 64,
      'raster_page_number' => 1)
    image.transformation = Geom::Transformation.translation(Geom::Point3d.new(*corners.first))
    image.width, image.height = corners[1][0] - corners[0][0], corners[3][1] - corners[0][1]
    @crops << { :source_span_id => sid, :final_page_crop => true, :raster_page_number => 1,
      :source_pdf_sha256 => 'a' * 64, :loops => [corners] }
    image
  end

  def apply
    Subject.apply!(@page, @stats, @context.merge(:final_page_crops => @crops))
  end

  def row(entity)
    { 'persistent_id' => entity.persistent_id, 'entity_id' => entity.entityID,
      'typename' => entity.typename, 'transformation' => entity.transformation.to_a,
      'bounds' => { 'min' => entity.bounds.min.to_a, 'max' => entity.bounds.max.to_a },
      'representation_evidence' => { 'source_span_id' => entity.attrs['source_span_id'] },
      'content_evidence' => { 'display_width' => entity.width, 'display_height' => entity.height },
      'children' => entity.entities.to_a.map { |child| row(child) } }
  end

  def test_preserves_source_proof_pixels_and_peers_and_verifies_reopened_pose
    before = Marshal.dump(@stats[:raster_delivery_records])
    text_before = Marshal.dump(row(@text))
    proof = apply
    assert_in_delta 0.201, proof[:expected_display_z], 1.0e-15
    assert_equal before, Marshal.dump(@stats[:raster_delivery_records])
    assert_equal text_before, Marshal.dump(row(@text))
    assert_equal [1.0, 5.0, 0.201], @image.transformation.to_a[12, 3]
    assert Subject.verify_manifest!(@stats, [row(@page)])
    assert Subject.verify_manifest!(JSON.parse(JSON.generate(@stats)), JSON.parse(JSON.generate([row(@page)])))
  end

  def test_overlapping_pure_raster_crops_share_one_policy_depth
    other = add_image(4, 3, [100.0, 100.0, 240.0, 180.0])
    @page = Entity.new(1, 'Group', [@image, other])
    apply
    assert_equal [0.001, 0.001], [@image, other].map { |image| image.transformation.to_a[14] }
    assert Subject.verify_manifest!(@stats, [row(@page)])
  end

  def test_nested_parent_transform_does_not_change_source_xy
    transform = Geom::Transformation.new([0.0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 4, 0, 7, 9, 0, 1])
    @image.transformation = transform.inverse * @image.transformation
    @image.width, @image.height = 2.0 / 3.0, 1.0 / 2.0
    container = Entity.new(4, 'Group', [@image])
    container.transformation = transform
    @page = Entity.new(1, 'Group', [container, @text])
    apply
    assert Subject.verify_manifest!(@stats, [row(@page)])
    actual = Subject.image_corners(@image.transformation.to_a, transform.to_a, @image.width, @image.height)
    [[1.0, 5.0], [3.0, 5.0], [3.0, 6.0], [1.0, 6.0]].each_with_index do |xy, index|
      xy.each_with_index { |coordinate, axis| assert_in_delta coordinate, actual[index][axis], 1.0e-12 }
    end
  end

  def test_rotated_offset_media_box_source_coordinates
    [0, 90, 180, 270].each do |rotation|
      @context[:page_rotation] = rotation
      @stats[:raster_delivery_records] = []
      @crops = []
      @image = add_image(2, 1, [82.0, 92.0, 226.0, 164.0])
      @page = Entity.new(1, 'Group', [@image, @text])
      @stats.delete(:item_raster_display_placements)
      apply
      assert Subject.verify_manifest!(@stats, [row(@page)])
    end
  end

  def test_rejects_wrong_page_and_pdf_and_unproved_generic_image
    [lambda { @context[:page] = 2 }, lambda { @context[:source_pdf_sha256] = 'd' * 64 },
     lambda { @image.attrs['renderer'] = 'unverified_image' },
     lambda { @stats[:raster_delivery_records][0][:artifact_evidence][:page_render_once_verified] = false },
     lambda { @crops[0][:source_pdf_sha256] = 'e' * 64 }].each do |mutation|
      setup
      mutation.call
      # A mismatched caller page must not quietly certify a different page.
      if @context[:page] == 2
        @stats[:raster_delivery_records][0][:page] = 2
      end
      assert_raises(Error) { apply }
    end
  end

  def test_rejects_changed_xy_or_nonoriginal_plane_before_mutation
    [[0.01, 0, 0], [0, 0, 0.02]].each do |offset|
      setup
      @image.transformation = Geom::Transformation.translation(Geom::Point3d.new(*offset)) * @image.transformation
      before = @image.transformation.to_a
      assert_raises(Error) { apply }
      assert_equal before, @image.transformation.to_a
    end
  end

  def test_rejects_double_application
    apply
    assert_raises(Error) { apply }
  end

  def test_saved_evidence_rejects_arbitrary_z_xy_stale_top_and_missing_ledger
    apply
    original = JSON.parse(JSON.generate([row(@page)]))
    [12, 14].each do |axis|
      manifest = Marshal.load(Marshal.dump(original))
      manifest[0]['children'][0]['transformation'][axis] += 0.01
      assert_raises(Error) { Subject.verify_manifest!(@stats, manifest) }
    end
    manifest = Marshal.load(Marshal.dump(original))
    manifest[0]['children'][1]['bounds']['max'][2] += 0.02
    assert_raises(Error) { Subject.verify_manifest!(@stats, manifest) }
    stats = Marshal.load(Marshal.dump(@stats))
    stats[:item_raster_display_placements] = []
    assert_raises(Error) { Subject.verify_manifest!(stats, original) }
    stats.delete(:item_raster_display_placements)
    assert_raises(Error) { Subject.verify_manifest!(stats, original) }
  end

  def test_importer_claimed_offset_cannot_override_the_physical_policy
    apply
    proof = @stats[:item_raster_display_placements].first
    proof[:expected_display_z] += 0.5
    proof[:placements].first[:expected_display_corners].each { |p| p[2] += 0.5 }
    @image.transformation = Geom::Transformation.translation(Geom::Point3d.new(0, 0, 0.5)) * @image.transformation
    assert_raises(Error) { Subject.verify_manifest!(@stats, [row(@page)]) }
  end

  def test_legacy_homogeneous_affine_matrices_preserve_physical_points_and_axis_lengths
    affine = [0.0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 4, 0, 7, 9, 0, 1]
    legacy = affine.map { |value| value * 1000.0 }
    original = legacy.dup
    assert_equal Subject.transform([1, 2, 3], affine), Subject.transform([1, 2, 3], legacy)
    assert_equal Subject.multiply(affine, affine), Subject.multiply(legacy, legacy)
    assert_equal Subject.image_corners(affine, Subject::IDENTITY, 4.0, 3.0),
                 Subject.image_corners(legacy, Subject::IDENTITY, 4.0, 3.0)
    assert_equal original, legacy
    apply
    manifest = [row(@page)]
    manifest[0]['children'][0]['transformation'].map! { |value| value * 1000.0 }
    # A legacy background container is traversed but owns no source text.
    manifest[0]['children'] << { 'typename' => 'Group', 'transformation' => legacy,
      'representation_evidence' => {}, 'children' => [] }
    assert Subject.verify_manifest!(@stats, manifest)
  end

  def test_projective_zero_and_nonfinite_homogeneous_matrices_are_rejected
    [3, 7, 11, 15].each do |index|
      matrix = Subject::IDENTITY.dup
      matrix[index] = index == 15 ? 0.0 : 0.1
      assert_raises(Error) { Subject.transform([1, 2, 3], matrix) }
    end
    matrix = Subject::IDENTITY.dup
    matrix[15] = Float::INFINITY
    assert_raises(Error) { Subject.transform([1, 2, 3], matrix) }
  end
end
