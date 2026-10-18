require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

module Geom
  class Transformation
    attr_reader :offset_z
    def initialize(offset_z = 0.0); @offset_z = offset_z.to_f; end
    def *(other); self.class.new(offset_z + other.offset_z); end
  end
end unless defined?(Geom::Transformation)

class WhiteMaskCompositionControlTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  SVG = '<svg xmlns="http://www.w3.org/2000/svg"><g/></svg>'.freeze
  Point = Struct.new(:z) do
    def transform(transformation); self.class.new(z + transformation.offset_z); end
  end
  Bounds = Struct.new(:z) do
    def corner(_index); Point.new(z); end
  end
  Root = Struct.new(:id, :attributes) do
    def entityID; id; end
    def valid?; attributes.fetch('valid', true); end
    def typename; 'Group'; end
    def transformation; attributes.fetch('transformation', Geom::Transformation.new); end
    def bounds; Bounds.new(attributes.fetch('native_bounds_z', 0)); end
    def get_attribute(_dictionary, key, default); attributes.fetch(key, default); end
  end
  Entities = Struct.new(:rows) do
    def to_a; rows.dup; end
  end
  Page = Struct.new(:entities)
  Builder = Struct.new(:fill_only_groups, :page_group)
  Container = Struct.new(:entities, :transformation) do
    def typename; 'Group'; end
    def entityID; 1000; end
    def get_attribute(_dictionary, _key, default); default; end
  end

  def setup
    @svg_sha = Digest::SHA256.hexdigest(SVG)
    @units = 128.times.map do |index|
      { :source_unit_id => 'fictional-unit-' + index.to_s,
        :expected_evidence => { :source_identity => { :svg_sha256 => @svg_sha } } }
    end
    @roots = @units.each_with_index.map do |unit, index|
      Root.new(index + 1, 'source_unit_id' => unit[:source_unit_id])
    end
    @builder = Builder.new([], Page.new(Entities.new(@roots)))
    @verified = []
  end

  def compose(opts = {}, binding = nil)
    verify = lambda do |entity, row|
      @verified << [entity.id, row]
      true
    end
    inventory = { :white_paths => [], :opaque_paths => [], :glyphs => [] }
    bound = binding || { :masks => [], :ink_faces => [], :binding => {} }
    IMP.stub(:verify_composition_source_unit!, verify) do
      IMP::SvgPaintOrder.stub(:build, inventory) do
        IMP::SvgPaintBinding.stub(:prepare, bound) do
          IMP::PlanarWhiteKnockout.stub(:compose!, {}) do
            IMP.stub(:page_representation_transform, Geom::Transformation.new) do
              IMP.compose_page_white_masks!(@builder, [], [0,0,100,100],
                { :source_units => @units, :svg_provider => lambda { { :svg => SVG } } }.merge(opts))
            end
          end
        end
      end
    end
  end

  def collect(opts = {})
    verify = lambda do |entity, row|
      @verified << [entity.id, row]
      true
    end
    IMP.stub(:verify_composition_source_unit!, verify) do
      IMP.collect_page_composition_inventory!(@builder, [], { :source_units => @units }.merge(opts))
    end
  end

  def test_binding_failure_keeps_completed_height_and_verified_raster_crop_exclusion
    @roots.first.attributes['native_bounds_z'] = 2.0
    before = Marshal.dump(@roots.map(&:attributes))
    inventory = collect
    failure = lambda { |*_args| raise IMP::RepresentationFidelity::ContractError, 'unproved mask paint order' }
    IMP.stub(:collect_page_composition_inventory!, lambda { |*_args| raise 'unexpected second root scan' }) do
      error = assert_raises(IMP::RepresentationFidelity::ContractError) do
        compose({ :composition_inventory => inventory }, failure)
      end
      assert_equal 'unproved mask paint order', error.message
    end
    assert_equal 128, @verified.length
    crop = { :final_page_crop => true, :source_pdf_sha256 => 'a' * 64, :raster_page_number => 1 }
    controller, seen = Object.new, nil
    scan = lambda do |roots, opts|
      assert_same inventory[:roots], roots
      seen = opts
      [crop, { :final_page_crop => false }]
    end
    context = IMP::PlanarWhiteKnockout.stub(:collect_text_faces, scan) do
      IMP.late_overlay_composition_context!(nil, inventory,
        :run_controller => controller, :page_number => 1)
    end
    assert_equal 2.0, context[:highest_text_z]
    assert_equal [crop], context[:final_page_crops]
    assert_same crop, context[:final_page_crops].first
    assert_same controller, seen[:run_controller]
    assert_equal 1, seen[:page_number]
    assert_equal before, Marshal.dump(@roots.map(&:attributes))
  end

  def test_successful_composition_does_not_repeat_physical_face_inventory
    crops = [{ :final_page_crop => true }]
    composition = { :highest_text_z => 3.0, :final_page_crops => crops }
    context = IMP::PlanarWhiteKnockout.stub(:collect_text_faces,
      lambda { |*_args| raise 'unexpected repeated face scan' }) do
      IMP.late_overlay_composition_context!(composition, nil)
    end
    assert_equal 3.0, context[:highest_text_z]
    assert_same crops, context[:final_page_crops]
  end

  def test_cached_inventory_rejects_a_different_page_or_invalidated_native_root
    inventory = collect
    original_page = @builder.page_group
    @builder.page_group = Page.new(original_page.entities)
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      compose(:composition_inventory => inventory)
    end
    @builder.page_group = original_page
    @roots.first.attributes['valid'] = false
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      compose(:composition_inventory => inventory)
    end
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.late_overlay_composition_context!(nil, inventory)
    end
  end

  def test_failed_crop_inventory_remains_an_explicit_page_warning_and_terminal_stops_propagate
    inventory, stats, context = collect, {}, nil
    failure = lambda { |*_args| raise IMP::RepresentationFidelity::ContractError, 'physical raster corners disagree' }
    done = IMP::PlanarWhiteKnockout.stub(:collect_text_faces, failure) do
      IMP.keep_page_on_page_stage_failure(stats, 1, 'final_vector_annotations',
        'text_inventory_unavailable', 'Annotation checks were incomplete') do
        context = IMP.late_overlay_composition_context!(nil, inventory)
      end
    end
    assert_equal false, done
    assert_nil context
    assert_equal 'text_inventory_unavailable', stats[:page_step_downs].first[:reason_code]
    assert_includes stats[:page_step_downs].first[:detail], 'physical raster corners disagree'
    stop = IMP::ImportRunControl::ImportCancelled.new([1], 1, {})
    IMP::PlanarWhiteKnockout.stub(:collect_text_faces, lambda { |*_args| raise stop }) do
      actual = assert_raises(IMP::ImportRunControl::ImportCancelled) do
        IMP.keep_page_on_page_stage_failure({}, 1, 'final_vector_annotations', 'x', 'y') do
          IMP.late_overlay_composition_context!(nil, inventory)
        end
      end
      assert_same stop, actual
    end
  end

  def test_nested_native_height_uses_parent_transform_without_changing_placement
    @units = [@units.first]
    @roots = [@roots.first]
    @roots.first.attributes['native_bounds_z'] = 2.5
    before = Marshal.dump(@roots.first.attributes)
    transform = Geom::Transformation.new(3.25)
    @builder.page_group.entities.rows = [Container.new(Entities.new(@roots), transform)]
    inventory = collect
    assert_equal 5.75, inventory[:highest_text_z]
    assert_equal 3.25, inventory[:roots].first[:transformation].offset_z
    assert_equal 3.25, inventory[:roots].first[:parent_transform].offset_z
    assert_same transform, @builder.page_group.entities.rows.first.transformation
    assert_equal before, Marshal.dump(@roots.first.attributes)
    assert_equal 1, @verified.length
  end

  def test_incomplete_duplicate_or_nonfinite_inventory_cannot_supply_annotation_height
    @roots.last.attributes['source_unit_id'] = @units.first[:source_unit_id]
    inventory = nil
    assert_raises(IMP::RepresentationFidelity::ContractError) { inventory = collect }
    assert_nil inventory
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.late_overlay_composition_context!(nil, inventory)
    end
    @roots.last.attributes['source_unit_id'] = @units.last[:source_unit_id]
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |height|
      @roots.first.attributes['native_bounds_z'] = height
      error = assert_raises(IMP::RepresentationFidelity::ContractError) { collect }
      assert_match(/nonfinite height/, error.message)
    end
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      compose(:composition_inventory => { :roots => [], :highest_text_z => 2.0 })
    end
  end

  def test_one_document_digest_keeps_every_source_identity_comparison
    original = Digest::SHA256.method(:hexdigest)
    full_hashes = 0
    spy = lambda do |value|
      full_hashes += 1 if value == SVG
      original.call(value)
    end
    result = Digest::SHA256.stub(:hexdigest, spy) { compose }
    assert_equal 1, full_hashes
    assert_equal @svg_sha, result[:report][:source_svg_sha256]
    assert_equal @roots.map(&:id), @verified.map(&:first)
    @verified.each_with_index { |pair, index| assert_same @units[index], pair.last }
  end

  def test_source_unit_roots_do_not_rescan_all_units_per_root
    @units.define_singleton_method(:find) { |&_block| raise 'full source-unit scan is forbidden' }
    compose
    assert_equal 128, @verified.length
    assert_same @units.last, @verified.last.last
  end

  def test_different_svg_digest_still_rejects_a_source_unit
    @units.last[:expected_evidence][:source_identity][:svg_sha256] = 'f' * 64
    error = assert_raises(IMP::RepresentationFidelity::ContractError) { compose }
    assert_match(/different source SVG/, error.message)
  end

  def test_duplicate_unit_identifiers_and_duplicate_or_missing_roots_still_fail
    @units << @units.first.dup
    assert_raises(IMP::RepresentationFidelity::ContractError) { compose }
    @units.pop
    @roots[-1].attributes['source_unit_id'] = @units.first[:source_unit_id]
    assert_raises(IMP::RepresentationFidelity::ContractError) { compose }
    @roots.pop
    assert_raises(IMP::RepresentationFidelity::ContractError) { compose }
  end

  def test_real_controller_can_stop_read_only_root_scan_before_any_binding_or_composition
    controller = IMP::ImportRunControl::Controller.new(
      :pages => [1], :requested_mode => :glyphs, :cancel_probe => lambda { |snapshot|
        snapshot[:stage] == :white_mask_scan && @verified.length >= 63
      })
    error = assert_raises(IMP::ImportRunControl::ImportCancelled) do
      compose(:run_controller => controller, :page_number => 1)
    end
    assert_equal 1, error.next_page
    assert_equal 63, @verified.length
    assert_equal 128, @builder.page_group.entities.rows.length
  end

  def test_cancellation_during_svg_paint_inventory_is_not_an_empty_success
    controller = IMP::ImportRunControl::Controller.new(
      :pages => [1], :requested_mode => :glyphs, :cancel_probe => lambda { true })
    assert_raises(IMP::ImportRunControl::ImportCancelled) do
      IMP::SvgPaintOrder.build(SVG, [0,0,100,100],
        :run_controller => controller, :page_number => 1)
    end
  end
end
