require 'minitest/autorun'
require 'digest'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/source_round_annotation_ink'

class SourceRoundAnnotationInkTest < Minitest::Test
  Ink = BlueCollarSystems::PDFVectorImporter::SourceRoundAnnotationInk
  class Parser
    attr_reader :objects, :streams, :page
    def initialize
      @data = 'fictional original source bytes'
      @page = { :media_box => [0, 0, 200, 200], :crop_box => [0, 0, 200, 200] }
      @objects = {
        '1 0 R' => { '/Subtype' => '/Ink', '/F' => '4', '/Rect' => [10, 20, 50, 60],
          '/BM' => '/Multiply', '/AP' => { '/N' => '2 0 R' } },
        '2 0 R' => { '/Subtype' => '/Form', '/BBox' => [10, 20, 50, 60],
          '/Matrix' => [1, 0, 0, 1, -10, -20], '/Resources' => {
            '/ExtGState' => { '/GS' => '4 0 R' }, '/XObject' => { '/Shape' => '3 0 R' } } },
        '3 0 R' => { '/Subtype' => '/Form', '/BBox' => [10, 20, 50, 60],
          '/Group' => { '/S' => '/Transparency' }, '/Resources' => {} },
        '4 0 R' => { '/CA' => '1', '/ca' => '1', '/BM' => '/Multiply' }
      }
      @streams = { 2 => '/GS gs /Shape Do',
        3 => '1 0.5 0.25 RG 4 w 1 J 1 j 30 40 m 30.014 40 l S' }
    end
    def page_data(_page); @page; end
    def pages; [@page]; end
    def find_inherited(dict, name); dict[name]; end
    def page_annotation_entries(_page); ['1 0 R']; end
    def resolve_object(value); @objects.fetch(value, value); end
    def to_dict(value); value if value.is_a?(Hash); end
    def get_stream_data(number); @streams[number]; end
    def source_sha; Digest::SHA256.hexdigest(@data); end
  end

  def setup
    @parser = Parser.new
  end

  def inventory
    Ink.inventory(@parser, 1, @parser.source_sha)
  end

  def rejected
    result = inventory
    assert_empty result[:records]
    assert_equal 1, result[:unsupported].length
    refute_empty result[:unsupported][0][:reason]
  end

  def test_original_microline_is_retained_without_normalization_or_edge_tolerance
    result = inventory
    assert_empty result[:unsupported]
    item = result[:records].fetch(0)
    assert_equal [30.0, 40.0], item[:start_pdf]
    assert_equal [30.014, 40.0], item[:end_pdf]
    assert_equal 2.0, item[:radius_pdf]
    assert_equal '/Multiply', item[:blend_mode]
    assert_equal 1.0, item[:stroke_alpha]
    assert_equal 2, item[:source_streams].length
    assert_equal Digest::SHA256.hexdigest(@parser.streams[3]), item[:source_streams][1][:sha256]
    assert item[:full_capsule_clip_verified]
    refute item[:original_composite_pixels_verified]
  end

  def test_annotation_placement_scales_and_translates_the_original_form_once
    @parser.objects['1 0 R']['/Rect'] = [20, 40, 100, 120]
    item = inventory[:records].fetch(0)
    assert_equal [60.0, 80.0], item[:start_pdf]
    assert_equal [60.028, 80.0], item[:end_pdf]
    assert_equal 4.0, item[:radius_pdf]
  end

  def test_reflected_form_preserves_radius_and_correct_source_endpoints
    @parser.objects['3 0 R']['/Matrix'] = [-1, 0, 0, 1, 60, 0]
    item = inventory[:records].fetch(0)
    assert_equal [30.0, 40.0], item[:start_pdf]
    assert_in_delta 29.986, item[:end_pdf][0], 1.0e-12
    assert_equal 2.0, item[:radius_pdf]
  end

  def test_original_page_and_form_clips_must_cover_the_complete_round_footprint
    @parser.page[:crop_box] = [29, 0, 200, 200]
    rejected
    @parser.page[:crop_box] = [0, 0, 200, 200]
    @parser.objects['3 0 R']['/BBox'] = [29, 20, 50, 60]
    rejected
  end

  def test_noncircular_affine_is_explicitly_unsupported
    @parser.objects['1 0 R']['/Rect'] = [20, 40, 100, 80]
    rejected
  end

  def test_source_hash_mutation_is_rejected_before_inventory
    assert_raises(Ink::Unproven) { Ink.inventory(@parser, 1, '0' * 64) }
  end

  def test_unknown_operator_dash_or_second_stroke_cannot_certify_one_capsule
    original = @parser.streams[3]
    [' 1 Tr', ' [2 2] 0 d', ' 20 30 m 22 30 l S'].each do |suffix|
      @parser.streams[3] = original + suffix
      rejected
    end
  end

  def test_nonunit_alpha_soft_mask_and_unknown_graphics_state_are_unproven
    original = @parser.objects['4 0 R'].dup
    [{ '/CA' => '0.5' }, { '/ca' => '0.5' }, { '/SMask' => '9 0 R' },
     { '/BM' => '/Screen' }, { '/LW' => '9' }].each do |change|
      @parser.objects['4 0 R'] = original.merge(change)
      rejected
    end
  end

  def test_resource_scope_cannot_fall_back_to_a_different_form_dictionary
    @parser.objects['3 0 R']['/Resources'] = { '/ExtGState' => {} }
    @parser.streams[3] = '/GS gs ' + @parser.streams[3]
    rejected
  end

  def test_hidden_and_knockout_source_appearances_do_not_qualify
    @parser.objects['1 0 R']['/F'] = '36'
    rejected
    @parser.objects['1 0 R']['/F'] = '4'
    @parser.objects['3 0 R']['/Group']['/K'] = 'true'
    rejected
  end

  def test_view_dependent_annotation_flags_and_user_unit_are_not_silently_ignored
    [-64, 8, 16].each do |flag|
      @parser.objects['1 0 R']['/F'] = flag.to_s
      rejected
    end
    @parser.objects['1 0 R']['/F'] = '4'
    @parser.page['/UserUnit'] = '2'
    assert_raises(Ink::Unproven) { inventory }
  end

  def test_cycles_unbalanced_state_and_incomplete_paths_fail_closed
    original = @parser.streams[2]
    @parser.objects['2 0 R']['/Resources']['/XObject']['/Shape'] = '2 0 R'
    rejected
    @parser.objects['2 0 R']['/Resources']['/XObject']['/Shape'] = '3 0 R'
    @parser.streams[2] = 'q ' + original
    rejected
    @parser.streams[2] = original
    @parser.streams[3] = '1 J 30 40 m'
    rejected
  end
end
