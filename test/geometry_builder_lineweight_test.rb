require_relative 'stroke_color_preservation_test'

class GeometryBuilderLineweightTest < Minitest::Test
  IMP=BlueCollarSystems::PDFVectorImporter
  Subject=IMP::GeometryBuilder
  class Group < GeometryBuilderStagingTest::Group
    def initialize(parent)
      super(parent)
      @entities=Entities.new
      @attributes={}
    end
    def set_attribute(dictionary,key,value); @attributes[[dictionary,key]]=value; end
    def get_attribute(dictionary,key,default); @attributes.fetch([dictionary,key],default); end
  end
  class Entities < StrokeColorPreservationTest::Entities
    def add_group
      group=Group.new(self)
      @items << group
      @groups_created += 1
      group
    end
  end
  class Model < StrokeColorPreservationTest::Model
    def initialize
      super
      @active_entities=Entities.new
    end
  end
  def build(stream,mode,stub_native=false)
    model=Model.new
    paths=IMP::ContentStreamParser.new([stream],nil).parse
    builder=Subject.new(model,paths,[],[0,0,100,80],:group_per_page=>false,:detect_arcs=>false,
      :import_fills=>false,:lineweight_mode=>mode)
    plans=[]
    replacement=lambda do |owner,plan,mapper,material,layer|
      plans << plan
      {:group=>Object.new,:face_count=>plan[:polygons].length,:edge_count=>4}
    end
    result=if stub_native
             IMP::VectorStrokeFootprint.stub(:build!,replacement) { builder.build }
           else
             builder.build
           end
    [model,result,plans]
  end
  def test_explicit_preserve_calls_bounded_width_builder_and_does_not_redraw_visible_centerlines
    model,result,plans=build('2 w 10 20 30 40 re S','Preserve visually',true)
    assert_equal 1,plans.length
    assert_equal 4,result[:faces]
    assert_empty model.active_entities.to_a
    proof=result[:geometry_staging][:stroke_footprints]
    assert_equal true,proof[:all_source_widths_represented]
    assert_equal 2,proof[:records].first[:source_width_pdf_points]
    assert_equal false,proof[:records].first[:whole_page_visual_fidelity_claimed]
  end
  def test_ignore_keeps_existing_edges_and_does_not_create_width_faces
    model,result,plans=build('2 w 10 20 m 30 20 l S','Ignore',true)
    assert_empty plans
    assert_equal 1,model.active_entities.to_a.length
    assert_equal 0,result[:faces]
    assert_equal false,result[:geometry_staging][:stroke_footprints][:all_source_widths_represented]
  end
  def test_unsupported_selected_styles_retain_editable_centerlines_with_reason_and_false_coverage
    ['0 w 10 20 m 30 20 l S','[2 1] 0 d 2 w 10 20 m 30 20 l S',
     '2 w 10 20 m 30 20 l 30 30 l S'].each do |stream|
      model,result,plans=build(stream,'Preserve visually',true)
      assert_empty plans
      refute_empty model.active_entities.to_a
      proof=result[:geometry_staging][:stroke_footprints]
      assert_equal 1,proof[:unresolved_path_count]
      assert_equal false,proof[:all_source_widths_represented]
      refute_empty proof[:records].first[:reason]
    end
  end
  def test_valid_peer_stroke_is_not_omitted_when_another_has_unsupported_hairline
    model,result,plans=build('0 w 10 20 m 30 20 l S 2 w 10 30 m 30 30 l S','Preserve visually',true)
    assert_equal 1,plans.length
    assert_equal 1,model.active_entities.to_a.length
    proof=result[:geometry_staging][:stroke_footprints]
    assert_equal [2,1,1],[proof[:stroke_path_count],proof[:represented_path_count],proof[:unresolved_path_count]]
    assert_equal false,proof[:all_source_widths_represented]
  end
  def test_combined_fill_and_stroke_retains_original_paints_without_coplanar_footprint_cells
    model=Model.new
    paths=IMP::ContentStreamParser.new(['0 1 0 rg 1 0 0 RG 2 w 10 20 30 40 re B'],nil).parse
    builder=Subject.new(model,paths,[],[0,0,100,80],:group_per_page=>false,:detect_arcs=>false,
      :import_fills=>true,:lineweight_mode=>'Preserve visually')
    result=IMP::VectorStrokeFootprint.stub(:build!,lambda { |*args| raise 'must not build overlapping width cells' }) { builder.build }
    assert_equal 1,result[:faces]
    edges=model.active_entities.to_a.grep(GeometryBuilderStagingTest::Edge)
    assert_equal 4,edges.length
    assert_equal [[255,0,0]],edges.map { |e| c=e.material.color; [c.red,c.green,c.blue] }.uniq
    proof=result[:geometry_staging][:stroke_footprints]
    assert_equal false,proof[:all_source_widths_represented]
    assert_equal 1,proof[:unresolved_path_count]
    assert_match(/combined fill\/stroke/,proof[:records].first[:reason])
  end
  def test_pattern_path_keeps_existing_centerline_and_reports_unproven_solid_color
    model,result,plans=build('/Pattern CS /P0 SCN 2 w 10 20 m 30 20 l S','Preserve visually',true)
    assert_empty plans
    assert_equal 1,model.active_entities.to_a.length
    proof=result[:geometry_staging][:stroke_footprints]
    assert_equal false,proof[:all_source_widths_represented]
    assert_match(/solid stroke color is unproven/,proof[:records].first[:reason])
  end
  def test_dense_sheet_width_strokes_stay_inside_bounded_batches
    count = Subject::GEOMETRY_STAGING_PATH_THRESHOLD + 40
    stream = count.times.map { |index| "2 w 0 #{index} m 12 #{index} l S" }.join(' ')
    model = Model.new
    paths = IMP::ContentStreamParser.new([stream], nil).parse
    builder = Subject.new(model, paths, [], [0, 0, 400, count + 10],
      :group_per_page => false, :detect_arcs => false, :import_fills => false,
      :lineweight_mode => 'Preserve visually')
    owners = Hash.new(0)
    result = IMP::VectorStrokeFootprint.stub(:build!, lambda { |owner, plan, *_rest|
      owners[owner.object_id] += 1
      { :group => Object.new, :face_count => plan[:polygons].length, :edge_count => 4 }
    }) { builder.build }
    assert_equal count, owners.values.inject(0) { |sum, value| sum + value }
    assert owners.length > 1
    assert owners.values.max <= Subject::GEOMETRY_STAGING_CHUNK_PATHS
    assert_equal true, result[:geometry_staging][:enabled]
    assert_equal true, result[:geometry_staging][:stroke_footprints][:all_source_widths_represented]
  end
  def test_width_footprints_report_page_path_progress
    snapshots=[]
    controller=IMP::ImportRunControl::Controller.new(:pages=>[3],:requested_mode=>:geometry,
      :cancel_probe=>lambda { false },:clock=>lambda { 0.0 },:status_sink=>lambda { |s| snapshots << s })
    paths=IMP::ContentStreamParser.new(['2 w 10 20 m 30 20 l S 2 w 10 30 m 30 30 l S'],nil).parse
    builder=Subject.new(Model.new,paths,[],[0,0,100,80],:group_per_page=>false,:detect_arcs=>false,
      :import_fills=>false,:lineweight_mode=>'Preserve visually',:page_number=>3,:run_controller=>controller)
    IMP::VectorStrokeFootprint.stub(:build!,lambda { |_owner,plan,*_rest|
      {:group=>Object.new,:face_count=>plan[:polygons].length,:edge_count=>4} }) { builder.build }
    footprint=snapshots.select { |s| s[:stage] == :stroke_footprint }
    assert_equal [[0,2,3],[1,2,3]],footprint.map { |s| [s[:completed],s[:total],s[:page]] }
    assert_equal 50.0,footprint.last[:percentage]
  end

  def test_unknown_lineweight_mode_fails_explicitly
    assert_raises(ArgumentError) { build('10 20 m 30 20 l S','invented') }
  end
  def test_declared_width_groups_are_real_and_reuse_equal_width_without_averaging_ctm
    stream='2 w 10 20 m 30 20 l S 3 w 10 30 m 30 30 l S 2 0 0 3 0 0 cm 2 w 10 15 m 30 15 l S'
    model,result,plans=build(stream,'Group by lineweight',true)
    assert_empty plans
    groups=model.active_entities.to_a.grep(Group)
    assert_equal ['PDF lineweight 2.0 pt','PDF lineweight 3.0 pt'],groups.map(&:name)
    assert_equal [2,1],groups.map { |g| g.entities.to_a.length }
    assert_equal [2.0,3.0],groups.map { |g| g.get_attribute('BC_PDF_Importer','declared_source_lineweight_pt',nil) }
    proof=result[:geometry_staging][:lineweight_organization]
    assert_equal 3,proof[:organized_path_count]
    assert_equal 2,proof[:group_count]
    assert_equal false,proof[:physical_width_preservation_claimed]
    assert_equal 0,result[:geometry_staging][:stroke_footprints][:unresolved_path_count]
  end
  def test_tags_assign_actual_edges_keep_source_colors_and_take_priority_over_dash_tags
    stream='0 1 0 RG 2 w [3 2] 0 d 10 20 m 30 20 l S 1 0 0 RG 0 w 10 30 m 30 30 l S'
    model=Model.new
    builder=Subject.new(model,IMP::ContentStreamParser.new([stream],nil).parse,[],[0,0,100,80],
      :group_per_page=>false,:detect_arcs=>false,:map_dashes=>true,:lineweight_mode=>'Map to tags')
    result=builder.build
    edges=model.active_entities.to_a
    assert edges.length > 2
    names=edges.map { |e| e.layer.name }.uniq
    assert_equal ['PDF Import: Lineweight 2.0 pt','PDF Import: Lineweight 0.0 pt'],names
    assert_equal [[0,255,0],[255,0,0]],edges.map { |e| c=e.material.color; [c.red,c.green,c.blue] }.uniq
    assert_equal names,result[:geometry_staging][:lineweight_organization][:tag_names]
    assert_equal false,result[:geometry_staging][:lineweight_organization][:physical_width_preservation_claimed]
  end
end
