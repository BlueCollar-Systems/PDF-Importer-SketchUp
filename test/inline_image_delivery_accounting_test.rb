#!/usr/bin/env ruby
# A page that keeps its vectors and carries inline images is accounted
# AFTER placement (main.rb record_inline_image_delivery!): every detected
# instance ends in a placed composite (delivered, with entity + artifact
# proof) or in a recorded omission with its reason. A composite that never
# reached the model is an omission, a count with nothing extracted is an
# omission that names the import mode, and claiming more than was detected
# is a contract error. Composites also bypass the single-image paint-order
# proof (which would decode every source strip) and are recorded as
# unqualified instead.

require 'minitest/autorun'

class InlineImageDeliveryAccountingTest < Minitest::Test
  MAIN = File.read(File.expand_path(
    '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
  ))

  def method_source(name)
    src = MAIN[/^    def self\.#{Regexp.escape(name)}(?=[\s(]).*?^    end\n/m]
    refute_nil src, "#{name} not found in main.rb"
    src
  end

  module FakeLogger
    class << self
      def lines; @lines ||= []; end
      def info(ctx, msg); lines << [:info, ctx, msg]; end
      def warn(ctx, msg); lines << [:warn, ctx, msg]; end
    end
  end

  module FakeFidelity
    class ContractError < StandardError; end
    def self.stable_entity_id(entity)
      "persistent_id:#{entity.persistent_id}"
    end
  end

  Asset = Struct.new(:name, :placement_error, :inline_composite)
  Entity = Struct.new(:persistent_id)

  def build_scope
    FakeLogger.lines.clear
    scope = Module.new
    scope.const_set(:Logger, FakeLogger)
    scope.const_set(:RepresentationFidelity, FakeFidelity)
    scope.module_eval(method_source('record_inline_image_delivery!') +
                      method_source('inline_composite_asset?'), __FILE__, __LINE__)
    scope
  end

  def composite_record(asset, count)
    { :asset => asset, :kind => 'composite', :instance_count => count,
      :file_path => 'C:/assets/page_005_inline_composite_002.png', :sha256 => 'b' * 64,
      :pixel_width => 1979, :pixel_height => 622, :region_box_pts => [2720.5, 1393.1, 2934.3, 1467.7],
      :downsampled => false, :coverage => 0.388, :source_sha256 => 'c' * 64,
      :member_sequences => [1, count] }
  end

  def fresh_stats
    { :inline_image_composites => [], :inline_image_vector_retentions => [] }
  end

  def test_placed_composite_is_delivered_with_entity_and_artifact_proof
    scope = build_scope
    asset = Asset.new('inline_composite_2', nil, { :kind => 'composite' })
    stats = fresh_stats
    result = scope.record_inline_image_delivery!(
      stats, 5,
      { :count => 2175, :composites => [composite_record(asset, 2175)], :omissions => [], :vector_path_count => 15_012 },
      [{ :asset => asset, :image_entity => Entity.new(77) }]
    )
    assert_equal({ :composited => 2175, :omitted => 0 }, result)
    assert_empty stats[:inline_image_vector_retentions]
    record = stats[:inline_image_composites].first
    assert_equal 5, record[:page]
    assert_equal 2175, record[:inline_image_instance_count]
    assert_equal :inline_images_composited, record[:delivery]
    assert_equal true, record[:placed]
    assert_equal 1, record[:region_count]
    assert_equal ['persistent_id:77'], record[:resulting_entity_ids]
    assert_equal 'b' * 64, record[:artifacts].first[:sha256]
    assert_equal 2175, record[:artifacts].first[:instance_count]
    assert_equal 15_012, record[:vector_path_count]
    assert FakeLogger.lines.any? { |level, _, msg| level == :info && msg =~ /composited 2175 inline image/ }
    refute FakeLogger.lines.any? { |level, _, _| level == :warn }
  end

  def test_partly_composited_page_records_both_delivery_and_omission
    scope = build_scope
    asset = Asset.new('inline_composite_2', nil, { :kind => 'composite' })
    stats = fresh_stats
    result = scope.record_inline_image_delivery!(
      stats, 5,
      { :count => 2175, :composites => [composite_record(asset, 2000)],
        :omissions => [{ :count => 175, :reason => 'stencil mask (ImageMask) inline images are not composited' }],
        :vector_path_count => 15_012 },
      [{ :asset => asset, :image_entity => Entity.new(78) }]
    )
    assert_equal({ :composited => 2000, :omitted => 175 }, result)
    assert_equal 2000, stats[:inline_image_composites].first[:inline_image_instance_count]
    omission = stats[:inline_image_vector_retentions].first
    assert_equal 175, omission[:inline_image_instance_count]
    assert_equal :inline_images_omitted, omission[:delivery]
    assert_match(/175 x stencil mask/, omission[:reason])
    assert_equal [{ :count => 175, :reason => 'stencil mask (ImageMask) inline images are not composited' }], omission[:reasons]
    assert FakeLogger.lines.any? { |level, _, msg| level == :warn && msg =~ /175 of 2175/ }
  end

  def test_composite_that_never_reached_the_model_is_an_omission
    scope = build_scope
    asset = Asset.new('inline_composite_2', nil, { :kind => 'composite' })
    stats = fresh_stats
    result = scope.record_inline_image_delivery!(
      stats, 5,
      { :count => 2175, :composites => [composite_record(asset, 2175)], :omissions => [], :vector_path_count => 15_012 },
      []
    )
    assert_equal({ :composited => 0, :omitted => 2175 }, result)
    assert_empty stats[:inline_image_composites]
    assert_match(/no page group received the composite image/, stats[:inline_image_vector_retentions].first[:reason])
    refused = Asset.new('inline_composite_3', 'raw image conversion failed', { :kind => 'composite' })
    stats = fresh_stats
    scope.record_inline_image_delivery!(
      stats, 6,
      { :count => 10, :composites => [composite_record(refused, 10)], :omissions => [], :vector_path_count => 3 },
      [{ :asset => Asset.new('other', nil, nil), :image_entity => Entity.new(1) }]
    )
    assert_match(/raw image conversion failed/, stats[:inline_image_vector_retentions].first[:reason])
  end

  def test_counted_but_never_extracted_names_the_import_mode
    scope = build_scope
    stats = fresh_stats
    result = scope.record_inline_image_delivery!(
      stats, 2, { :count => 5, :composites => [], :omissions => [], :vector_path_count => 40 }, []
    )
    assert_equal({ :composited => 0, :omitted => 5 }, result)
    assert_match(/writes no image assets/, stats[:inline_image_vector_retentions].first[:reason])
  end

  def test_claiming_more_than_detected_is_a_contract_error
    scope = build_scope
    asset = Asset.new('inline_composite_2', nil, { :kind => 'composite' })
    assert_raises(FakeFidelity::ContractError) do
      scope.record_inline_image_delivery!(
        fresh_stats, 5,
        { :count => 12, :composites => [composite_record(asset, 10)],
          :omissions => [{ :count => 5, :reason => 'x' }], :vector_path_count => 1 },
        [{ :asset => asset, :image_entity => Entity.new(9) }]
      )
    end
  end

  def test_inline_composite_asset_predicate
    scope = build_scope
    assert scope.inline_composite_asset?(Asset.new('a', nil, { :kind => 'composite' }))
    refute scope.inline_composite_asset?(Asset.new('a', nil, nil))
    refute scope.inline_composite_asset?(Object.new)
  end

  def test_pipeline_accounts_after_placement_and_keeps_composites_out_of_the_paint_order_proof
    pipeline = MAIN[/^    def self\.run_pipeline\(model, path, opts\).*?^    def self\./m]
    refute_nil pipeline
    decision = pipeline.index('page_inline_accounting = {')
    placement = pipeline.index('placed = place_embedded_images(')
    accounting = pipeline.index('record_inline_image_delivery!(')
    plan = pipeline.index('prepare_embedded_image_display_plans(')
    refute_nil decision
    refute_nil placement
    refute_nil accounting
    refute_nil plan
    assert_operator decision, :<, placement
    assert_operator placement, :<, accounting
    assert_operator accounting, :<, plan
    assert_includes pipeline, 'if inline_composite_asset?(record[:asset])'
    assert_includes pipeline, 'builder.page_group, source_image_records, paint_svg_provider.call'
    refute_includes pipeline, "stats[:inline_image_vector_retentions] << {\n            :page => page_num,\n            :inline_image_instance_count => inline_image_count"
    assert_includes MAIN, ':inline_image_composites => [],'
    assert_includes MAIN, 'inline_image_composites: [],'
  end
end
