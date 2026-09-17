require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'

class ContentStreamOpacityTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  TextParser = BlueCollarSystems::PDFVectorImporter::TextParser
  FILL = '1 g 0 0 10 10 re f'.freeze

  def parse(*streams); Parser.new(streams, nil).parse; end

  class ResourceParser
    attr_reader :pages
    def initialize(page_stream, page_resources, forms = {}, objects = {})
      @page_stream, @forms, @objects = page_stream, forms, objects
      @pages = [{ '/Contents' => page_stream, '/Resources' => page_resources }]
    end
    def resolve_object(value); @objects.fetch(value, value); end
    def get_stream_data(number); @forms[number]; end
    private
    def to_dict(value); value.is_a?(Hash) ? value : nil; end
    def find_inherited(dictionary, key); dictionary[key]; end
    def collect_content_streams(value); Array(value); end
  end

  def effects(*args); Parser.page_fill_opacity_effects(ResourceParser.new(*args), 1); end

  def parse_with_effects(stream, effect_map)
    Parser.new([stream], nil, {}, effect_map).parse.map(&:source_fill_opacity)
  end

  def test_pdf_initial_opacity_is_proven_and_does_not_change_struct_constructor
    path = parse(FILL).first
    assert_equal 1.0, path.source_fill_opacity
    assert_equal :clip_fill_rule, Parser::VectorPath.members.last
    assert_equal [1.0, 1.0, 1.0], path.fill_color
    assert_equal [0.0, 0.0], path.subpaths[0].segments[0].points[0]
  end

  def test_unresolved_extgstate_marks_opacity_unknown_until_matching_restore
    paths = parse("#{FILL} q /GSalpha gs #{FILL} q #{FILL} Q #{FILL} Q #{FILL}")
    assert_equal [1.0, nil, nil, nil, 1.0], paths.map(&:source_fill_opacity)
    assert paths.all? { |path| path.fill && !path.stroke }
  end

  def test_unknown_opacity_survives_stream_boundary_color_reset_and_inner_qQ
    paths = parse("/Unknown gs #{FILL}", "q 1 1 1 rg #{FILL} Q #{FILL}")
    assert_equal [nil, nil, nil], paths.map(&:source_fill_opacity)
    assert_equal [0, 1, 1], paths.map { |path| path.source_paint_order[0] }
  end

  def test_graphics_state_restore_across_content_streams_recovers_known_opacity
    paths = parse("q /GS1 gs #{FILL}", "Q #{FILL}")
    assert_equal [nil, 1.0], paths.map(&:source_fill_opacity)
  end

  def test_extgstate_names_in_strings_comments_and_inline_images_do_not_change_evidence
    stream = "% /Bogus gs\nBT /F1 10 Tf (q /GS gs Q) Tj ET #{FILL} " \
             "BI /W 1 /H 1 ID /Fake gs EI #{FILL}"
    assert_equal [1.0, 1.0], parse(stream).map(&:source_fill_opacity)
  end

  def test_clipped_fill_retains_source_opacity_and_paint_identity
    stream = 'q /Unresolved gs 2 2 m 8 2 l 5 8 l h W n 0 0 10 10 re f Q'
    path = parse(stream).first
    assert_equal :nonzero, path.clip_fill_rule
    assert_nil path.source_fill_opacity
    assert_equal [0, stream.index('f Q')], path.source_paint_order
  end

  def test_vector_and_text_paint_offsets_share_original_stream_byte_coordinates
    streams = [
      "% comment \xC3\xA9\n#{FILL} BT /F1 10 Tf 1 0 0 1 2 2 Tm (first f gs) Tj ET".force_encoding(Encoding::BINARY),
      "q /Unknown gs #{FILL} Q BT /F1 10 Tf 1 0 0 1 4 4 Tm [(second) -10 (run)] TJ ET #{FILL}"
    ]
    paths = Parser.new(streams, nil).parse
    text = TextParser.new(streams, nil, :strict_text_fidelity => true, :merge_text_runs => false).parse
    assert_equal [[0, streams[0].index('f BT')], [1, streams[1].index('f Q')],
                  [1, streams[1].rindex('f')]], paths.map(&:source_paint_order)
    assert_equal [[0, streams[0].index('Tj ET')], [1, streams[1].index('TJ ET')]],
                 text.map(&:source_paint_order)
    assert_equal [1.0, nil, 1.0], paths.map(&:source_fill_opacity)
    assert_equal ['first f gs', 'secondrun'], text.map(&:text)
    assert_equal(-1, paths[0].source_paint_order <=> text[0].source_paint_order)
  end

  def test_equivalent_page_and_form_effects_resolve_despite_distinct_resource_objects
    resource = { '/ExtGState' => { '/Same' => { '/SA' => false } }, '/XObject' => { '/Fm' => '9 0 R' } }
    form = { '/Subtype' => '/Form', '/Resources' => { '/ExtGState' => { '/Same' => { '/OP' => false } } } }
    proof = effects('/Same gs /Fm Do', resource, { 9 => '/Same gs' }, { '9 0 R' => form })
    assert_equal({ :alpha => :preserve, :stroke_alpha => :preserve,
                   :mask_clear => :preserve, :blend_normal => :preserve,
                   :stroke_style_proven => :preserve }, proof['/Same'])
    assert_equal [1.0], parse_with_effects("/Same gs #{FILL}", proof)
  end

  def test_conflicting_form_opacity_or_undefined_scoped_name_stays_unknown
    resource = { '/ExtGState' => { '/Same' => {} }, '/XObject' => { '/Fm' => '9 0 R' } }
    form = { '/Subtype' => '/Form', '/Resources' => { '/ExtGState' => { '/Same' => { '/ca' => '.3' } } } }
    proof = effects('/Same gs /Fm Do', resource, { 9 => '/Same gs' }, { '9 0 R' => form })
    assert_nil proof['/Same']
    assert_equal [nil], parse_with_effects("/Same gs #{FILL}", proof)
    form['/Resources'] = {}
    assert_nil effects('/Same gs /Fm Do', resource, { 9 => '/Same gs' }, { '9 0 R' => form })['/Same']
  end

  def test_unused_form_resource_does_not_poison_actual_page_state
    resource = { '/ExtGState' => { '/Same' => {} }, '/XObject' => { '/Unused' => '9 0 R' } }
    form = { '/Subtype' => '/Form', '/Resources' => { '/ExtGState' => { '/Same' => { '/ca' => '.3' } } } }
    proof = effects('/Same gs', resource, { 9 => '/Same gs' }, { '9 0 R' => form })
    assert_equal [1.0], parse_with_effects("/Same gs #{FILL}", proof)
  end

  def test_omitted_alpha_preserves_translucency_and_qQ_restores_all_evidence
    states = { '/Half' => { '/ca' => 0.5 }, '/NoAlpha' => { '/SA' => false } }
    proof = effects('/Half gs /NoAlpha gs', { '/ExtGState' => states })
    stream = "#{FILL} q /Half gs #{FILL} /NoAlpha gs #{FILL} Q #{FILL}"
    assert_equal [1.0, 0.5, 0.5, 1.0], parse_with_effects(stream, proof)
  end

  def test_mask_and_blend_evidence_cannot_be_cleared_by_alpha_alone
    states = {
      '/Mask' => { '/SMask' => { '/S' => '/Luminosity' } },
      '/Opaque' => { '/ca' => 1 }, '/Clear' => { '/SMask' => '/None' },
      '/Blend' => { '/BM' => '/Multiply' }, '/Normal' => { '/BM' => '/Normal' }
    }
    proof = effects(states.keys.map { |key| "#{key} gs" }.join(' '), { '/ExtGState' => states })
    stream = "/Mask gs #{FILL} /Opaque gs #{FILL} /Clear gs #{FILL} " \
             "/Blend gs #{FILL} /Opaque gs #{FILL} /Normal gs #{FILL}"
    assert_equal [nil, nil, 1.0, nil, nil, 1.0], parse_with_effects(stream, proof)
    assert_equal [nil], parse_with_effects("/Missing gs /Opaque gs #{FILL}", proof)
  end

  def test_invalid_numeric_alpha_and_missing_resources_are_unknown
    ['NaN', '-.1', '1.01', '1 2 R'].each do |invalid|
      proof = effects('/Bad gs', { '/ExtGState' => { '/Bad' => { '/ca' => invalid } } })
      assert_nil proof['/Bad']
    end
    assert_nil effects('/Missing gs', {})['/Missing']
  end

  def test_stroke_alpha_is_separate_from_fill_and_qQ_preserves_both
    states = { '/Fill' => { '/ca' => 0.3 }, '/Stroke' => { '/CA' => 0.5 }, '/NoAlpha' => {} }
    proof = effects(states.keys.map { |key| "#{key} gs" }.join(' '), { '/ExtGState' => states })
    stream = "#{FILL} q /Fill gs #{FILL} /Stroke gs #{FILL} /NoAlpha gs #{FILL} Q #{FILL}"
    paths = Parser.new([stream], nil, {}, proof).parse
    assert_equal [1.0, 0.3, 0.3, 0.3, 1.0], paths.map(&:source_fill_opacity)
    assert_equal [1.0, 1.0, 0.5, 0.5, 1.0], paths.map(&:source_stroke_opacity)
    assert_nil parse("/Unknown gs #{FILL}").first.source_stroke_opacity
  end

  def test_clip_and_miter_evidence_survive_nested_graphics_state
    paths = parse("#{FILL} q 1 M 0 0 20 20 re W n #{FILL} Q #{FILL}")
    assert_equal [true, false, true], paths.map(&:source_clip_clear)
    assert_equal [10.0, 1.0, 10.0], paths.map(&:source_miter_limit)
    proof = effects('/Style gs', { '/ExtGState' => { '/Style' => { '/LW' => 2 } } })
    styled = Parser.new(["#{FILL} q /Style gs #{FILL} Q #{FILL}"], nil, {}, proof).parse
    assert_equal [true, false, true], styled.map(&:source_stroke_style_proven)
  end

  def test_nonpath_paint_barriers_use_the_same_raw_stream_order_and_skip_strings_and_binary_data
    streams = ["% /False Do\nBT (Do BI sh) Tj ET /Image Do #{FILL}",
               "BI /W 1 /H 1 ID /Fake Do sh EI /Shade sh /Next Do #{FILL}"]
    parser = Parser.new(streams, nil)
    paths = parser.parse
    assert_equal [[0, streams[0].index('Do 1 g')], [1, 0],
                  [1, streams[1].index('sh /Next')], [1, streams[1].index('Do 1 g')]],
                 parser.nonpath_paint_orders
    assert_equal 2, paths.length
    assert_equal 5, parser.other_paint_orders.length
    assert_includes parser.other_paint_orders, [0, streams[0].index('Tj ET')]
    assert parser.nonpath_paint_orders.all? { |order| (order <=> paths[-1].source_paint_order) == -1 }
  end

  def test_malformed_inline_image_makes_final_suffix_proof_unknown
    parser = Parser.new(["BI /W 1 /H 1 ID no_end_marker #{FILL}"], nil)
    parser.parse
    assert_includes parser.nonpath_paint_orders, nil
    assert_includes parser.other_paint_orders, nil
  end

  def test_every_text_show_operator_is_a_final_overlay_paint_barrier
    stream = "BT (one) Tj [(two)] TJ (three) ' 1 2 (four) \" ET #{FILL}"
    parser = Parser.new([stream], nil)
    parser.parse
    assert_equal ['Tj', 'TJ', "'", '"'].map { |op| [0, stream.index(op)] }, parser.other_paint_orders
  end

  def test_text_clipping_render_modes_exclude_late_paint_and_qQ_restores_clip
    (0..7).each do |mode|
      paths = parse("#{FILL} q BT #{mode} Tr (glyph) Tj ET #{FILL} Q #{FILL}")
      assert_equal [true, mode < 4, true], paths.map(&:source_clip_clear)
    end
  end

  def test_later_nonclipping_text_does_not_clear_existing_text_clip
    paths = parse("BT 7 Tr [(clip)] TJ ET #{FILL} BT 0 Tr (plain) Tj ET #{FILL}")
    assert_equal [false, false], paths.map(&:source_clip_clear)
    assert_equal [1.0, 1.0], paths.map(&:source_fill_opacity)
    # An unused clipping mode adds no glyphs to the clip.
    assert parse("BT 7 Tr ET #{FILL}").first.source_clip_clear
  end
end
