require_relative 'geometry_builder_staging_test'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/xobject_parser'

class StrokeClippingTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Clip = IMP::StrokeClipping
  Parser = IMP::ContentStreamParser
  Builder = IMP::GeometryBuilder
  class Entities < GeometryBuilderStagingTest::Entities
    def add_line(a,b)
      edge=GeometryBuilderStagingTest::Edge.new(a,b)
      @items << edge
      edge
    end
  end
  class Model < GeometryBuilderStagingTest::Model
    def initialize
      super
      @active_entities=Entities.new
    end
  end

  def parse(stream)
    Parser.new([stream],nil).parse
  end

  def build(stream, options={})
    model=Model.new
    paths=parse(stream)
    builder=Builder.new(model,paths,[],[0,0,100,80],
      { :group_per_page=>false, :detect_arcs=>false, :import_fills=>false, :merge_tolerance=>0 }.merge(options))
    result=builder.build
    [model.active_entities.to_a.grep(GeometryBuilderStagingTest::Edge).map do |edge|
       [edge.start_point,edge.end_point].map { |p| [(p.x*72).round(12),(p.y*72).round(12)] }
     end, result, paths]
  end

  def test_active_rectangle_snapshot_is_immutable_and_q_restores_state
    paths=parse('q 2 0 0 2 10 20 cm 0 0 10 10 re W n -1 5 m 11 5 l S Q 0 0 m 5 5 l S')
    assert_equal [[10,20,30,40]], paths[0].source_stroke_clip[:rectangles]
    assert_equal [], paths[1].source_stroke_clip[:rectangles]
    assert paths[0].source_stroke_clip.frozen?
    assert paths[0].source_stroke_clip[:rectangles][0].frozen?
  end

  def test_pending_clip_applies_after_current_paint
    paths=parse('0 0 10 10 re W S -2 5 m 20 5 l S')
    assert_equal [],paths[0].source_stroke_clip[:rectangles]
    assert_equal [[0,0,10,10]],paths[1].source_stroke_clip[:rectangles]
  end

  def test_bad_corner_order_retraced_and_compound_clips_are_not_rectangle_proofs
    ['0 0 m 10 10 l 10 0 l 0 10 l h',
     '0 0 m 10 0 l 0 0 l 0 10 l 10 10 l h',
     '0 0 10 10 re 2 2 4 4 re'].each do |shape|
      path=parse(shape+' W* n -5 5 m 20 5 l S')[0]
      assert path.source_stroke_clip[:unsupported]
    end
  end

  def test_empty_intersection_is_distinct_from_unknown_clip
    source=parse('0 0 10 10 re W n 20 20 10 10 re W n 0 5 m 40 5 l S')[0]
    assert_equal :empty,Clip.effective_bounds(source.source_stroke_clip,[0,0,100,80])
    edges,result=build('0 0 10 10 re W n 20 20 10 10 re W n 0 5 m 40 5 l S')
    assert_empty edges
    assert_equal 0,result[:geometry_staging][:stroke_clipping][:unresolved_subpaths]
  end

  def test_rectangle_crossing_preserves_direction_and_source_style
    edges,result,paths=build('20 20 20 20 re W n 6 w 1 J 2 j [3 4] 1 d 50 30 m 10 30 l S')
    assert_equal [[[40.0,30.0],[20.0,30.0]]],edges
    assert_equal [6,1,2,[[3,4],1]], [paths[0].line_width,paths[0].line_cap,paths[0].line_join,paths[0].dash_pattern]
    assert_equal [50,30],paths[0].subpaths[0].segments[0].points[0]
    assert_equal 1,result[:geometry_staging][:stroke_clipping][:clipped_subpaths]
  end

  def test_implicit_page_boundary_trims_crossing_not_only_wholly_outside
    edges,=build('1 w 1 J 1 j 50 70 m 50 80.48 l S')
    assert_equal [[[50.0,70.0],[50.0,80.0]]],edges
  end

  def test_crop_box_clips_without_rebasing_media_box_origin
    edges,=build('0 30 m 100 30 l S', :page_clip_box=>[20,10,60,70])
    assert_equal [[[20.0,30.0],[60.0,30.0]]],edges
    rotated,=build('0 30 m 100 30 l S', :page_clip_box=>[20,10,60,70],:page_rotation=>90)
    assert_equal [[[30.0,80.0],[30.0,40.0]]],rotated
  end

  def test_crop_box_cannot_extend_visibility_outside_media_box
    edges,=build('-5 30 m 105 30 l S',:page_clip_box=>[-10,-10,110,90])
    assert_equal [[[0.0,30.0],[100.0,30.0]]],edges
    edges,=build('-5 30 m 105 30 l S',:page_clip_box=>[-10,10,60,90])
    assert_equal [[[0.0,30.0],[60.0,30.0]]],edges
    edges,=build('1 30 m 90 30 l S',:page_clip_box=>[110,10,150,70])
    assert_empty edges
  end

  def test_closed_path_does_not_invent_clip_boundary_connector
    edges,=build('20 20 20 20 re W n 10 10 40 40 re S')
    assert_empty edges # All four original stroke centerlines are outside; no new rectangle.
    edges,=build('20 20 20 20 re W n 10 30 m 30 30 l 30 60 l 10 60 l h S')
    assert_equal 2,edges.length
    refute edges.any? { |a,b| a[1]==40 && b[1]==40 }
  end

  def test_source_dashes_keep_phase_across_clipped_prefix_and_corner
    result=Clip.visible_segments([[0,0],[8,0],[8,12]],false,[3,-1,9,20],[[5,5],2],[1,0,0,1,0,0])
    assert_equal [[[8,0],[8.0,5.0]],[[8.0,10.0],[8,12]]],result
    # Boundary phase exactly at the end of the ON interval starts in OFF.
    assert_equal [[[5.0,0.0],[10,0]]],Clip.visible_segments([[0,0],[10,0]],false,[-1,-1,11,1],[[5,5],5],[1,0,0,1,0,0])
  end

  def test_source_dashes_use_inverse_ctm_without_short_dash_enlargement
    result=Clip.visible_segments([[0,0],[20,0]],false,[1,-1,21,1],[[2,1],0],[2,0,0,1,0,0])
    assert_equal [[[1.0,0.0],[4.0,0.0]],[[6.0,0.0],[10.0,0.0]],[[12.0,0.0],[16.0,0.0]],[[18.0,0.0],[20,0]]],result
    assert_in_delta Math.sqrt(20),Clip.source_length([0,0],[10,6],[2,0,1,3,0,0]),1e-12
  end

  def test_clipped_native_dash_geometry_does_not_use_layer_dash_styles
    edges,=build('3 0 97 80 re W n [5 5] 2 d 0 20 m 8 20 l 8 32 l S',:map_dashes=>true)
    assert_equal [[[8.0,20.0],[8.0,25.0]],[[8.0,30.0],[8.0,32.0]]],edges
  end

  def test_cap_only_paint_is_retained_with_explicit_unresolved_evidence
    edges,result=build('0.6 w 1 J 1 j 20 80.2 m 40 80.2 l S')
    assert_equal 1,edges.length
    diagnostics=result[:geometry_staging][:stroke_clipping]
    assert_equal 1,diagnostics[:unresolved_subpaths]
    assert diagnostics[:unresolved_reasons].keys.first.include?('width/caps')
  end

  def test_mixed_visible_and_cap_only_segments_are_retained_with_warning
    edges,result=build('0 0 10 10 re W n 0.6 w 1 J 1 j 5 5 m 5 10.2 l 8 10.2 l S')
    assert_equal [[[5.0,5.0],[5.0,10.2]],[[5.0,10.2],[8.0,10.2]]],edges
    assert_equal 1,result[:geometry_staging][:stroke_clipping][:unresolved_subpaths]
  end

  def test_flat_dash_style_and_invalid_dash_metadata_are_handled_explicitly
    expected=Clip.visible_segments([[0,0],[20,0]],false,[1,-1,19,1],[[5,5],0],[1,0,0,1,0,0])
    assert_equal expected,Clip.visible_segments([[0,0],[20,0]],false,[1,-1,19,1],[5,5],[1,0,0,1,0,0])
    assert_raises(Clip::Unsupported) { Clip.visible_segments([[0,0],[20,0]],false,[1,-1,19,1],'invalid',[1,0,0,1,0,0]) }
  end

  def test_pathological_dash_count_is_reported_without_unbounded_subdivision
    assert_raises(Clip::Unsupported) do
      Clip.visible_segments([[0,0],[100,0]],false,[1,-1,99,1],[[1e-20,1e-20],0],[1,0,0,1,0,0])
    end
  end

  def test_unknown_clip_retains_source_geometry_and_reports_limit
    edges,result=build('0 0 m 40 0 l 20 40 l h W n 5 20 m 50 20 l S')
    assert_equal [[[5.0,20.0],[50.0,20.0]]],edges
    assert_equal 1,result[:geometry_staging][:stroke_clipping][:unresolved_subpaths]
  end

  def test_contained_path_can_still_use_arc_fitting_but_trimmed_path_cannot
    path=parse('0 20 m 20 21 l 40 22 l 60 21 l 110 20 l S')
    model=Model.new
    builder=Builder.new(model,path,[],[0,0,100,80],:group_per_page=>false,:detect_arcs=>true,:merge_tolerance=>0)
    def builder.draw_with_arc_detection(*_args); raise 'clipped path reached arc fitter'; end
    assert_equal 4,builder.build[:edges]
    inside=Builder.new(Model.new,parse('0 20 m 20 21 l 40 22 l 60 21 l 90 20 l S'),[],[0,0,100,80],:group_per_page=>false,:detect_arcs=>true)
    called=false
    inside.define_singleton_method(:draw_with_arc_detection) { |*_args| called=true }
    inside.build
    assert called
  end

  def test_form_transform_preserves_clip_and_composes_stroke_metric
    path=parse('2 0 0 3 0 0 cm 0 0 10 10 re W n -5 5 m 20 5 l S')[0]
    form=IMP::XObjectParser.new(nil)
    transformed=form.send(:transform_paths,[path],[0,1,-1,0,60,10])[0]
    assert_equal [[30,10,60,30]],transformed.source_stroke_clip[:rectangles]
    assert_equal [0,2,-3,0,60,10],transformed.ctm
    assert_equal true,transformed.source_stroke_style_proven
    assert_equal path.line_width,transformed.line_width
  end
end
