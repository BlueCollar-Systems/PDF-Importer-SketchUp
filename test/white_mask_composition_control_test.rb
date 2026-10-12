require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

module Geom
  class Transformation
    def *(other); other; end
  end
end unless defined?(Geom::Transformation)

class WhiteMaskCompositionControlTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  SVG = '<svg xmlns="http://www.w3.org/2000/svg"><g/></svg>'.freeze
  Point = Struct.new(:z) do
    def transform(_transformation); self; end
  end
  Bounds = Struct.new(:z) do
    def corner(_index); Point.new(z); end
  end
  Root = Struct.new(:id, :attributes) do
    def entityID; id; end
    def valid?; true; end
    def typename; 'Group'; end
    def transformation; Geom::Transformation.new; end
    def bounds; Bounds.new(0); end
    def get_attribute(_dictionary, key, default); attributes.fetch(key, default); end
  end
  Entities = Struct.new(:rows) do
    def to_a; rows.dup; end
  end
  Page = Struct.new(:entities)
  Builder = Struct.new(:fill_only_groups, :page_group)

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

  def compose(opts = {})
    verify = lambda do |entity, row|
      @verified << [entity.id, row]
      true
    end
    inventory = { :white_paths => [], :opaque_paths => [], :glyphs => [] }
    bound = { :masks => [], :ink_faces => [], :binding => {} }
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
