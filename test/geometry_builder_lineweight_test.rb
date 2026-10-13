require 'timeout'
require_relative 'stroke_color_preservation_test'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

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
  def test_dense_preserved_width_strokes_keep_source_plans_and_bounded_live_parents
    count = Subject::GEOMETRY_STAGING_PATH_THRESHOLD + 41
    stream = count.times.map { |i| "2 w 0 #{i} m 12 #{i} l S" }.join(' ')
    model = Model.new
    paths = IMP::ContentStreamParser.new([stream], nil).parse
    builder = Subject.new(model, paths, [], [0, 0, 400, count + 10],
      :group_per_page => false, :detect_arcs => false, :import_fills => false,
      :lineweight_mode => 'Preserve visually')
    owners = Hash.new(0)
    plans = []
    result = IMP::VectorStrokeFootprint.stub(:build!, lambda { |owner, plan, *_rest|
      owners[owner.object_id] += 1
      plans << plan
      owner.add_group # The native builder owns a separate editable stroke group.
      { :group => Object.new, :face_count => plan[:polygons].length, :edge_count => 4 }
    }) { builder.build }
    assert_equal count, plans.length
    assert_equal count, owners.values.inject(0) { |sum, n| sum + n }
    assert_equal [250, 250, 41], owners.values
    assert_equal (0...count).to_a, plans.map { |plan| plan[:source_path_index] }
    assert_equal [2.0], plans.map { |plan| plan[:source_width_pdf_points] }.uniq
    assert_equal count, result[:geometry_staging][:stroke_footprints][:represented_path_count]
    assert_equal true, result[:geometry_staging][:stroke_footprints][:all_source_widths_represented]
    assert_equal 3, result[:geometry_staging][:retained_group_count]
    assert_equal 0, result[:geometry_staging][:explode_count]
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

  def footprint_progress_run(cancel_at = nil)
    stream = '2 w 10 10 m 20 10 l S ' \
             '2 w 10 20 m 20 20 l 10 25 m 20 25 l S ' \
             '2 w 10 30 m 20 30 l S'
    paths = IMP::ContentStreamParser.new([stream], nil).parse
    snapshots, probed, details, status, built = [], [], [], [], []
    now = 0.0
    stroke_probes = 0
    controller = nil
    result, cancelled = nil, nil
    IMP::BatchHostPolicy.stub(:noninteractive?, false) do
      Process.stub(:clock_gettime, lambda { |_kind| now }) do
        Sketchup.stub(:status_text=, lambda { |text| status << text }) do
          gui_sink = IMP.import_status_sink({})
          controller = IMP::ImportRunControl::Controller.new(
            :pages => [7], :requested_mode => :geometry,
            :clock => lambda { now },
            :status_sink => lambda { |snapshot|
              snapshots << snapshot
              now += 2.0
              gui_sink.call(snapshot)
            },
            :cancel_probe => lambda { |snapshot|
              probed << snapshot
              stroke_probes += 1 if snapshot[:stage] == :stroke_footprint
              !cancel_at.nil? && stroke_probes == cancel_at
            }
          )
          checkpoint = controller.method(:checkpoint!)
          builder = Subject.new(Model.new, paths, [], [0, 0, 100, 80],
            :group_per_page => false, :detect_arcs => false, :import_fills => false,
            :lineweight_mode => 'Preserve visually', :page_number => 7,
            :run_controller => controller)
          # These fake two-second status pulses isolate progress/cancellation;
          # the real three-second native-work threshold is covered below.
          builder.define_singleton_method(:footprint_time_budget_seconds) { 60.0 }
          controller.stub(:checkpoint!, lambda { |stage, detail|
            details << [stage, detail.dup]
            checkpoint.call(stage, detail)
          }) do
            IMP::VectorStrokeFootprint.stub(:build!, lambda { |_owner, plan, *_|
              built << plan
              {:group => Object.new, :face_count => 1, :edge_count => 4}
            }) do
              begin
                result = builder.build
              rescue IMP::ImportRunControl::ImportCancelled => error
                cancelled = error
              end
            end
          end
        end
      end
    end
    {:snapshots => snapshots, :probed => probed, :details => details,
     :status => status, :built => built, :result => result, :cancelled => cancelled}
  end

  def test_source_width_work_reports_real_zero_based_path_progress_and_page
    run = footprint_progress_run
    assert_nil run[:cancelled]
    footprints = run[:snapshots].select { |snapshot| snapshot[:stage] == :stroke_footprint }
    assert_equal [0, 1, 1, 2], footprints.map { |snapshot| snapshot[:completed] }
    assert_equal [3, 3, 3, 3], footprints.map { |snapshot| snapshot[:total] }
    assert_equal [7, 7, 7, 7], footprints.map { |snapshot| snapshot[:page] }
    assert_in_delta 100.0 / 3.0, footprints[1][:percentage], 0.001
    assert_in_delta 200.0 / 3.0, footprints.last[:percentage], 0.001
    raw = run[:details].select { |stage, _detail| stage == :stroke_footprint }.map { |pair| pair[1] }
    assert_equal [[0, 0], [1, 0], [1, 1], [2, 0]], raw.map { |detail| [detail[:path], detail[:subpath]] }
    assert_equal run[:snapshots], run[:probed], 'every footprint still polls cancellation'
    lines = run[:status].select { |text| text.include?('stroke footprint') }
    assert_equal 4, lines.length
    assert_includes lines[1], 'page 7'
    assert_includes lines[1], 'stroke footprint 1/3'
    assert_includes lines[1], '33.3%'
    assert_includes lines.last, 'stroke footprint 2/3'
    endpoint = run[:snapshots].last
    assert_equal :geometry_path, endpoint[:stage]
    assert_equal [3, 3, 100.0], [endpoint[:completed], endpoint[:total], endpoint[:percentage]],
      'the existing post-loop checkpoint announces completed work, never an in-flight stroke'
    records = run[:result][:geometry_staging][:stroke_footprints][:records]
    assert_equal [[0, 0], [1, 0], [1, 1], [2, 0]], records.map { |item| [item[:path_index], item[:subpath_index]] }
  end

  def test_source_width_progress_still_cancels_before_later_subpath_construction
    run = footprint_progress_run(3)
    error = run[:cancelled]
    assert_instance_of IMP::ImportRunControl::ImportCancelled, error
    assert_equal 7, error.next_page
    assert_equal :stroke_footprint, error.snapshot[:stage]
    assert_equal [1, 3], [error.snapshot[:completed], error.snapshot[:total]]
    assert_equal 2, run[:built].length, 'the cancelled third subpath must not be built'
    assert_equal run[:snapshots], run[:probed]
    assert_includes run[:status].last, 'stroke footprint 1/3'
    assert_nil run[:result]
  end

  def test_dense_unresolved_strokes_keep_every_item_in_the_report
    count = 301
    stream = count.times.map { |index| "0 w 10 #{index} m 20 #{index} l S" }.join(' ')
    paths = IMP::ContentStreamParser.new([stream], nil).parse
    builder = Subject.new(Model.new, paths, [], [0, 0, 100, count + 10],
      :group_per_page => false, :detect_arcs => false, :import_fills => false,
      :lineweight_mode => 'Preserve visually')
    result = builder.build
    proof = result[:geometry_staging][:stroke_footprints]
    assert_equal count, proof[:unresolved_path_count]
    assert_equal count, proof[:records].length
    assert_equal (0...count).to_a, proof[:records].map { |item| item[:path_index] }
    assert proof[:records].all? { |item| !item[:reason].to_s.empty? }
    assert_equal false, proof[:all_source_widths_represented]
  end

  def test_round_cap_cell_estimate_flags_a_thirty_thousand_stroke_sheet
    paths=IMP::ContentStreamParser.new(['1 J 2 w 0 0 m 10 0 l S'],nil).parse
    per=Subject.estimated_footprint_cells(paths.first)
    assert_equal 1,paths.first.line_cap
    assert_equal 1+(2*IMP::VectorStrokeFootprint::ROUND_SEGMENTS),per
    assert (30_000*per) > Subject::FOOTPRINT_CELL_BUDGET
    butt=IMP::ContentStreamParser.new(['2 w 0 0 m 10 0 l S'],nil).parse
    assert_equal 1,Subject.estimated_footprint_cells(butt.first)
  end

  # About 30k separate round-cap strokes made Preserve visually build ~97
  # faces each (two 48-segment semicircles plus the body) and SketchUp sat
  # there for more than 45 minutes. A sheet of that shape must stay on
  # centerlines and finish inside a few seconds.
  def test_many_round_caps_keep_centerlines_inside_a_few_seconds
    count=1500
    parts=['1 J 1 j 2 w']
    count.times { |i| parts << "#{i} 0 m #{i} 8 l S" }
    stream=parts.join("\n")
    parsed=IMP::ContentStreamParser.new([stream],nil).parse
    assert_equal count,parsed.length
    assert_equal 1,parsed.first.line_cap
    messages=[]
    original=Sketchup.method(:status_text=)
    Sketchup.define_singleton_method(:status_text=) { |value| messages << value.to_s }
    started=Time.now
    result=nil
    Timeout.timeout(8) do
      model=Model.new
      builder=Subject.new(model,parsed,[],[0,0,2000,80],:group_per_page=>false,:detect_arcs=>false,
        :import_fills=>false,:lineweight_mode=>'Preserve visually')
      result=builder.build
    end
    elapsed=Time.now-started
    assert elapsed < 8.0, "large round-cap sheet took #{elapsed.round(2)}s"
    proof=result[:geometry_staging][:stroke_footprints]
    assert_equal true,proof[:simplified]
    assert_equal 'cell_budget',proof[:simplify_trigger]
    assert proof[:estimated_cells] > Subject::FOOTPRINT_CELL_BUDGET
    assert_equal 0,proof[:represented_path_count]
    assert_equal count,proof[:unresolved_path_count]
    assert_equal count,proof[:simplified_path_count]
    assert_equal false,proof[:all_source_widths_represented]
    assert_equal 0,result[:faces]
    assert_equal count,result[:edges]
    assert messages.any? { |text| text.include?('centerlines') }
    assert_match(/centerlines/,proof[:message].to_s)
  ensure
    if original
      Sketchup.define_singleton_method(:status_text=) { |value| original.call(value) }
    end
  end

  def test_time_budget_stops_further_lineweight_faces
    parts=['1 J 1 j 2 w']
    4.times { |i| parts << "#{i*20} 0 m #{i*20+10} 0 l S" }
    model=Model.new
    paths=IMP::ContentStreamParser.new([parts.join("\n")],nil).parse
    builder=Subject.new(model,paths,[],[0,0,400,80],:group_per_page=>false,:detect_arcs=>false,
      :import_fills=>false,:lineweight_mode=>'Preserve visually')
    calls=0
     now=1000.0
    replacement=lambda do |*|
      calls += 1
       now=1003.0
      {:group=>Object.new,:face_count=>1,:edge_count=>0}
    end
     result=Process.stub(:clock_gettime,lambda { |_kind| now }) do
       IMP::VectorStrokeFootprint.stub(:build!,replacement) { builder.build }
     end
    proof=result[:geometry_staging][:stroke_footprints]
    assert_equal 1,calls
    assert_equal true,proof[:simplified]
    assert_equal 'time_budget',proof[:simplify_trigger]
     assert_match(/time limit/, proof[:message])
     assert_match(/page estimate/, proof[:message])
     refute_match(/faces were skipped/, proof[:message])
    assert_equal 1,proof[:represented_path_count]
    assert_equal 3,proof[:unresolved_path_count]
    assert_equal 3,result[:edges]
  end

   def test_footprint_budget_uses_monotonic_threshold_despite_wall_clock_changes
     builder=Subject.new(Model.new,[],[],[0,0,100,80],:lineweight_mode=>'Preserve visually')
     builder.instance_variable_set(:@footprint_started,1000.0)
     now=1002.999
     Process.stub(:clock_gettime,lambda { |kind|
       assert_equal Process::CLOCK_MONOTONIC,kind
       now
     }) do
       Time.stub(:now,Time.at(1_000_000_000)) do
         refute builder.send(:footprint_time_exceeded?),'a wall-clock jump must not trip the threshold early'
       end
       now=1003.0
       Time.stub(:now,Time.at(0)) do
         assert builder.send(:footprint_time_exceeded?),'a wall-clock rollback must not extend the threshold'
       end
     end
   end
end
