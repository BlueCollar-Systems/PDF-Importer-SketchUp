#!/usr/bin/env ruby
# Reuse the established native geometry doubles and exercise the real renderer.
require_relative 'svg_text_3d_renderer_test'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_display_container'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class ReservedTextEntities < Svg3DEntities
  def add_group
    group = ReservedTextGroup.new(self, next_id, @options)
    @items << group
    @groups << group
    group
  end
end

class ReservedTextGroup < Svg3DGroup
  def initialize(owner, id, options)
    super
    @layer = options[:active_layer]
    @material = :unexpected_material if options[:unexpected_container_material]
  end

  def hidden?; @options[:hidden_container] == true; end

  def layer=(value)
    @layer = value unless @options[:ignore_container_layer]
  end

  def transformation
    values = BlueCollarSystems::PDFVectorImporter::TextDisplayContainer::IDENTITY.dup
    values[12] = 1.0 if @options[:wrong_container_transform]
    Struct.new(:to_a).new(values)
  end

  def set_attribute(dictionary, key, value)
    return if @options[:ignore_container_attribute] && key == 'decorative_text_container'
    super
  end
end

class TextDisplayContainerTest < Minitest::Test
  CONTAINER = BlueCollarSystems::PDFVectorImporter::TextDisplayContainer
  RENDERER = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  FIDELITY = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity

  def render(entities, options = {})
    fixture = SvgText3DRendererTest.new('unused_fixture')
    RENDERER.render_svg(entities, fixture.square_svg,
      SvgText3DRendererTest::MEDIA_BOX, [fixture.span],
      { :depth => 0.05, :decorative_text_containers => true }.merge(options))
  end

  def test_container_precedes_unchanged_source_claim_and_is_not_an_active_wrapper
    plain_entities, reserved_entities = Svg3DEntities.new, ReservedTextEntities.new
    plain = render(plain_entities, :decorative_text_containers => false)
    result = render(reserved_entities)
    assert plain[:ok], plain[:failures].inspect
    assert result[:ok], result[:failures].inspect
    wrapper = reserved_entities.to_a.fetch(0)
    claim = result[:span_results].fetch(0).fetch(:group)
    assert_equal [claim], wrapper.entities.to_a
    refute_equal wrapper, claim
    assert_equal CONTAINER::IDENTITY, wrapper.transformation.to_a
    assert_equal true, wrapper.get_attribute(CONTAINER::DICTIONARY, 'decorative_text_container')
    assert_equal false, wrapper.get_attribute(CONTAINER::DICTIONARY, 'decorative_text_wrapper', false)
    assert_nil wrapper.get_attribute(CONTAINER::DICTIONARY, 'source_span_id')
    assert_equal 'text_span:1:0', claim.get_attribute(CONTAINER::DICTIONARY, 'source_span_id')
    assert_equal '0', claim.get_attribute(CONTAINER::DICTIONARY, 'source_placement_indices')
    plain_row, actual = plain[:span_results].first, result[:span_results].first
    [:width, :height, :depth, :face_count, :extruded_face_count,
     :placement_verified, :rotation_verified, :size_verified, :depth_verified].each do |key|
      assert_equal plain_row[key], actual[key], key.to_s
    end
    assert_equal FIDELITY.entity_bounds_payload(plain_row[:group]), FIDELITY.entity_bounds_payload(claim)
  end

  def test_partial_native_failure_cleans_whole_owned_container_and_keeps_peer
    entities = ReservedTextEntities.new(:fail_add_face => true)
    peer = entities.add_group
    result = render(entities)
    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_equal [peer], entities.to_a
    assert result[:failures].any? { |failure| failure[:cleanup_outcome] == :verified }, result[:failures].inspect
  end

  def test_ignored_identity_tag_and_unexpected_transform_are_runtime_failures
    [:ignore_container_attribute, :wrong_container_transform].each do |fault|
      entities = ReservedTextEntities.new(fault => true)
      result = render(entities)
      refute result[:ok], fault.to_s
      assert_empty result[:transition_proofs]
      assert_empty entities.to_a
    end
  end

  def test_native_alias_of_existing_group_is_rejected_without_erasing_it
    entities = ReservedTextEntities.new
    existing = entities.add_group
    entities.define_singleton_method(:add_group) { existing }
    assert_raises(FIDELITY::ContractError) { CONTAINER.create!(entities, 'text_span:1:0') }
    assert_equal [existing], entities.to_a
  end

  def test_container_uses_claim_layer_without_changing_hidden_user_active_layer
    layer = Struct.new(:name, :visible)
    active, intended = layer.new('user active', false), layer.new('PDF text', true)
    entities = ReservedTextEntities.new(:active_layer => active)
    result = render(entities, :layer => intended)
    assert result[:ok], result[:failures].inspect
    wrapper = entities.to_a.first
    claim = result[:span_results].first[:group]
    assert_equal intended, wrapper.layer
    assert_equal intended, claim.layer
    assert_equal false, active.visible
    assert_equal false, wrapper.hidden?
    assert_nil wrapper.material
    ignored = ReservedTextEntities.new(:active_layer => active, :ignore_container_layer => true)
    failure = render(ignored, :layer => intended)
    refute failure[:ok]
    assert_empty failure[:transition_proofs]
    assert_empty ignored.to_a
  end

  def test_non_neutral_container_cannot_hide_or_tint_original_claim
    [:hidden_container, :unexpected_container_material].each do |fault|
      entities = ReservedTextEntities.new(fault => true)
      result = render(entities)
      refute result[:ok]
      assert_empty entities.to_a
    end
  end

  def test_source_only_glyph_claim_also_starts_inside_its_own_empty_parent
    fixture = SvgText3DRendererTest.new('unused_fixture')
    entities = ReservedTextEntities.new
    result = RENDERER.render_svg(entities, fixture.square_svg,
      SvgText3DRendererTest::MEDIA_BOX, [],
      :depth => 0.05, :decorative_text_containers => true, :page_number => 1)
    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:unmatched_source_results].length
    claim = result[:unmatched_source_results].first[:group]
    assert_equal [claim], entities.to_a.first.entities.to_a
    assert CONTAINER.verify_claim!(entities.to_a.first, claim)
  end

  def test_container_may_never_adopt_an_existing_claim_or_share_two_claims
    entities = ReservedTextEntities.new
    wrapper = CONTAINER.create!(entities, 'text_span:1:0')
    first = wrapper.entities.add_group
    first.set_attribute(CONTAINER::DICTIONARY, 'source_span_id', 'text_span:1:0')
    assert CONTAINER.verify_claim!(wrapper, first)
    first.set_attribute(CONTAINER::DICTIONARY, 'source_span_id', 'text_span:1:1')
    assert_raises(FIDELITY::ContractError) { CONTAINER.verify_claim!(wrapper, first) }
    first.set_attribute(CONTAINER::DICTIONARY, 'source_span_id', 'text_span:1:0')
    wrapper.entities.add_group
    assert_raises(FIDELITY::ContractError) { CONTAINER.verify_claim!(wrapper, first) }
    assert_equal 2, wrapper.entities.to_a.length
  end

  def item_ladder(entities)
    importer = BlueCollarSystems::PDFVectorImporter
    fixture = SvgText3DRendererTest.new('unused_fixture')
    importer.complete_item_representation_ladder!({}, nil, entities,
      'fictional-source.pdf', 1, fixture.span, :geometry,
      FIDELITY::FallbackController.new(:geometry, 'text_span:1:0'), [],
      SvgText3DRendererTest::MEDIA_BOX, SvgText3DRendererTest::MEDIA_BOX, 0,
      { :decorative_text_containers => true }, Time.now, 0.0, {})
  end

  def test_item_ladder_creates_container_before_original_geometry_claim
    importer = BlueCollarSystems::PDFVectorImporter
    renderer = importer::SvgItemRepresentationRenderer
    entities = ReservedTextEntities.new
    delivered = nil
    create = lambda do |target, *_args|
      assert_equal 1, entities.to_a.length
      wrapper = entities.to_a.first
      assert_equal target, wrapper.entities
      assert CONTAINER.verify_identity!(wrapper)
      claim = target.add_group
      claim.set_attribute(CONTAINER::DICTIONARY, 'source_span_id', 'text_span:1:0')
      delivered = claim
      { :ok => true, :failures => [], :group => claim }
    end
    renderer.stub(:render_svg, create) do
      renderer.stub(:verify_transformed_delivery!, true) do
        renderer.stub(:finalize_source_evidence!, true) do
          importer.stub(:apply_and_verify_page_representation_transform, true) do
            importer.stub(:record_item_vector_delivery!, :recorded_original_claim) do
              assert_equal :recorded_original_claim, item_ladder(entities)
            end
          end
        end
      end
    end
    assert_equal [delivered], entities.to_a.first.entities.to_a
  end

  def test_item_runtime_failure_removes_container_and_never_advances_to_raster
    importer = BlueCollarSystems::PDFVectorImporter
    renderer = importer::SvgItemRepresentationRenderer
    entities = ReservedTextEntities.new
    peer = entities.add_group
    fail_render = lambda do |target, *_args|
      target.add_group
      raise 'native source geometry creation failed'
    end
    renderer.stub(:render_svg, fail_render) do
      importer.stub(:verified_item_raster_entity!, lambda { |*_args| flunk 'runtime error reached Raster' }) do
        error = assert_raises(RuntimeError) { item_ladder(entities) }
        assert_equal 'native source geometry creation failed', error.message
      end
    end
    assert_equal [peer], entities.to_a
  end
end
