require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

module Geom
  Point3d = Struct.new(:x, :y, :z)
  Vector3d = Struct.new(:x, :y, :z)
  class BoundingBox
    def initialize; @points = []; end
    def add(value)
      @points.concat(value.is_a?(BoundingBox) ? [value.min, value.max] : [value])
    end
    def valid?; !@points.empty?; end
    def empty?; @points.empty?; end
    def min; Point3d.new(*[:x, :y, :z].map { |axis| @points.map { |p| p.send(axis) }.min }); end
    def max; Point3d.new(*[:x, :y, :z].map { |axis| @points.map { |p| p.send(axis) }.max }); end
    def center; Point3d.new((min.x+max.x)/2.0, (min.y+max.y)/2.0, (min.z+max.z)/2.0); end
  end
end
module Sketchup
  class Camera
    attr_reader :eye, :target, :up
    attr_accessor :perspective, :height
    def initialize(eye, target, up)
      @perspective = true
      set(eye, target, up)
    end
    def set(eye, target, up)
      @eye, @target, @up = eye.dup, target.dup, up.dup
    end
  end
end

class RetainedPageViewFitTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Group = Struct.new(:persistent_id) do
    def valid?; true; end
  end
  Model = Struct.new(:active_entities, :active_view)
  Controller = Struct.new(:journal)
  Parser = Struct.new(:pages) do
    def page_data(page); pages.fetch(page); end
  end
  class View
    attr_reader :camera, :native_camera, :replacement_count, :invalidations
    def initialize
      @camera = Sketchup::Camera.new(Geom::Point3d.new(10,20,30),
        Geom::Point3d.new(0,0,0), Geom::Vector3d.new(0,1,0))
      @native_camera = @camera
      @replacement_count = 0
      @invalidations = 0
    end
    # SU2017 can display an assigned camera while persisting the existing one.
    def camera=(camera)
      @replacement_count += 1
      @camera = camera
    end
    def vpwidth; 1600; end
    def vpheight; 900; end
    def invalidate; @invalidations += 1; end
    def refresh; end
  end

  def setup
    @view = View.new
    @model = Model.new([Group.new(11), Group.new(22), Group.new(99)], @view)
    @parser = Parser.new({1=>{:media_box=>[0,0,612,792]}, 2=>{:media_box=>[0,0,612,792]}})
    @controller = Controller.new({'pages'=>[
      {'page_number'=>1, 'group_persistent_id'=>11, 'next_y_offset'=>13.2},
      {'page_number'=>2, 'group_persistent_id'=>22, 'next_y_offset'=>26.4},
      {'page_number'=>3, 'group_persistent_id'=>99, 'next_y_offset'=>999.0}
    ]})
  end

  def fit(retained, options = {})
    IMP.fit_retained_pages(@model, @parser, @controller,
      {:retained_pages=>retained}, {:scale=>1.0}.merge(options))
  end

  def test_final_camera_is_orthographic_and_frames_both_retained_pages
    fit([1,2])
    camera = @view.camera
    refute_nil camera
    assert_equal false, camera.perspective
    assert_equal [0,1,0], camera.up.to_a
    assert_in_delta camera.target.x, camera.eye.x, 1e-10
    assert_in_delta camera.target.y, camera.eye.y, 1e-10
    assert_operator camera.eye.z, :>, camera.target.z
    assert_in_delta 12.1, camera.target.y, 1e-10
    assert_in_delta 24.64, camera.height, 1e-10
    assert_in_delta 4.25, camera.target.x, 1e-10
  end

  def test_resumed_pages_are_included_without_building_new_geometry
    original_entities = @model.active_entities.dup
    fit([1,2])
    assert_in_delta 24.64, @view.camera.height, 1e-10
    assert_equal original_entities, @model.active_entities
  end

  def test_fit_updates_the_existing_camera_that_native_save_will_persist
    native = @view.native_camera
    fit([1,2])
    assert_same native, @view.camera
    assert_equal 0, @view.replacement_count
    assert_equal 1, @view.invalidations
    saved = Marshal.load(Marshal.dump(@view.native_camera))
    assert_equal false, saved.perspective
    assert_equal [4.25,12.1,0.0], saved.target.to_a
    assert_equal [0,1,0], saved.up.to_a
    assert_in_delta 24.64, saved.height, 1e-10
  end

  def test_framing_does_not_mutate_source_bounds_or_existing_position_values
    original_positions = [@view.camera.eye, @view.camera.target, @view.camera.up]
    original_values = original_positions.map { |value| value.to_a }
    source = Marshal.dump([@parser.pages, @controller.journal])
    bounds = Geom::BoundingBox.new
    first, last = Geom::Point3d.new(2,3,4), Geom::Point3d.new(10,14,4)
    bounds.add(first)
    bounds.add(last)
    assert IMP.apply_camera_top_ortho(@view, bounds)
    assert_equal [2,3,4], first.to_a
    assert_equal [10,14,4], last.to_a
    assert_equal original_values, original_positions.map { |value| value.to_a }
    assert_equal source, Marshal.dump([@parser.pages, @controller.journal])
    assert_equal [6.0,8.5,4.0], @view.camera.target.to_a
  end

  def test_height_failure_does_not_report_a_complete_frame
    camera = @view.camera
    def camera.height=(_value); raise 'native height unavailable'; end
    bounds = Geom::BoundingBox.new
    bounds.add(Geom::Point3d.new(0,0,0))
    bounds.add(Geom::Point3d.new(8.5,11,0))
    refute IMP.apply_camera_top_ortho(@view, bounds)
    assert_same camera, @view.camera
    assert_equal false, camera.perspective
    assert_equal [4.25,5.5,0.0], camera.target.to_a
  end

  def test_failed_or_cancelled_tail_does_not_add_an_empty_page_to_fit
    fit([1])
    assert_in_delta 5.5, @view.camera.target.y, 1e-10
    assert_in_delta 11.44, @view.camera.height, 1e-10
  end

  def test_page_after_failure_uses_its_certified_offset_not_its_page_number
    @parser.pages[3] = {:media_box=>[0,0,612,792]}
    @controller.journal['pages'][2]['next_y_offset'] = 26.4
    fit([1,3])
    assert_in_delta 12.1, @view.camera.target.y, 1e-10
    assert_in_delta 24.64, @view.camera.height, 1e-10
  end

  def test_crop_rotation_scale_and_gap_use_the_same_page_layout_as_import
    @parser.pages[2] = {:media_box=>[0,0,612,792], :crop_box=>[72,72,540,720], :rotation=>90}
    # A rotated 6.5-by-9 inch crop is 13 inches high at scale 2; 25% gap.
    @controller.journal['pages'][1]['next_y_offset'] = 16.25
    fit([2], :scale=>2.0, :page_arrangement=>:compact, :page_gap_ratio=>0.25)
    expected = Geom::BoundingBox.new
    IMP.add_page_fit_bounds(expected, [0,0,612,792], [72,72,540,720], 2.0, 0.0, 90)
    assert_in_delta expected.center.y, @view.camera.target.y, 1e-10
    assert_in_delta expected.center.x, @view.camera.target.x, 1e-10
  end

  def test_no_retained_pages_preserves_existing_camera
    before = Object.new
    @view.camera = before
    fit([])
    assert_same before, @view.camera
  end

  def test_missing_retained_page_source_does_not_frame_only_the_remaining_page
    before = Object.new
    @view.camera = before
    @parser.pages[2] = nil
    fit([1,2])
    assert_same before, @view.camera
  end

  def test_only_exact_retained_groups_are_available_to_fallback_framing
    captured = nil
    IMP.stub(:apply_top_view_fit, lambda { |_model, _bounds, groups| captured = groups }) { fit([2]) }
    assert_equal [22], captured.map { |group| group.persistent_id }
  end
end
