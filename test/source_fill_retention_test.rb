require_relative 'geometry_builder_staging_test'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/report_dialog'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_health'

class SourceFillRetentionTest < Minitest::Test
  Fixture = GeometryBuilderStagingTest
  Builder = Fixture::Builder
  Parser = Fixture::Parser
  QA = BlueCollarSystems::PDFVectorImporter::QAReport

  class NilFaceEntities < Fixture::Entities
    def add_face(_points); nil; end
  end
  class RaisedFaceEntities < Fixture::Entities
    def add_face(_points); raise ArgumentError, 'fictional native face rejection'; end
  end
  class PartialFaceEntities < Fixture::Entities
    def add_face(points)
      super(points)
      nil
    end
    def erase_entities(entities)
      Array(entities).each { |entity| erase_entity(entity) }
    end
  end
  class UncertainCleanupEntities < PartialFaceEntities
    def erase_entities(_entities); end
  end
  class PartialPlanarFailureEntities < PartialFaceEntities
    def add_face(points)
      super(points)
      raise ArgumentError, 'Points are not planar'
    end
  end
  class UncertainPlanarCleanupEntities < PartialPlanarFailureEntities
    def erase_entities(_entities); end
  end
  class MutatingPeerEntities < PartialFaceEntities
    def add_face(points)
      peer=to_a.first
      peer.points[0]=Geom::Point3d.new(99,98,0) if peer
      super(points)
    end
  end
  class MutatingPlanarPeerEntities < MutatingPeerEntities
    def add_face(points)
      super(points)
      raise ArgumentError, 'Points are not planar'
    end
  end
  class MutatingStylePeerEntities < PartialFaceEntities
    def add_face(points)
      to_a.first.material.alpha=0.25
      super(points)
    end
  end
  class RejectingDefinitions < Fixture::Definitions
    attr_reader :removed
    def initialize(entities_class)
      super()
      @entities_class = entities_class
      @removed = []
    end
    def add(name)
      definition = super(name)
      definition.instance_variable_set(:@entities, @entities_class.new)
      owner=self
      definition.define_singleton_method(:valid?) { !owner.removed.include?(self) }
      definition
    end
    def remove(definition)
      @removed << definition
      @items.delete(definition)
    end
  end
  class NilInstanceEntities < Fixture::Entities
    def add_instance(*); nil; end
  end
  class RaisedInstanceEntities < Fixture::Entities
    def add_instance(*); raise ArgumentError, 'fictional native instance rejection'; end
  end
  class PartialInstanceEntities < PartialFaceEntities
    def add_instance(*args)
      super(*args)
      nil
    end
  end
  class UncertainInstanceEntities < PartialInstanceEntities
    def erase_entities(*); end
  end
  class RaisingRemoveDefinitions < RejectingDefinitions
    def remove(*); raise 'fictional definition removal rejection'; end
  end
  class NoOpRemoveDefinitions < RejectingDefinitions
    def remove(*); false; end
  end
  class RejectedCompoundGroup < Fixture::Group
    def initialize(parent)
      super(parent)
      @entities=NilFaceEntities.new
    end
    def valid?; @parent.to_a.include?(self); end
  end
  class NoOpCompoundGroup < RejectedCompoundGroup
    def erase!; nil; end
  end
  class RaisingCompoundGroup < RejectedCompoundGroup
    def erase!; raise 'fictional group erasure rejection'; end
  end
  class CompoundParent < PartialFaceEntities
    def initialize(group_class)
      super()
      @group_class=group_class
    end
    def add_group
      group=@group_class.new(self)
      @items << group
      group
    end
  end
  class CountingBuilder < Builder
    attr_reader :peer_visits
    def fill_peer_state(*args)
      @peer_visits=(@peer_visits || 0)+1
      super(*args)
    end
  end

  def setup
    BlueCollarSystems::PDFVectorImporter::Logger.reset
  end
  def point(x,y,z=0); Geom::Point3d.new(x,y,z); end
  def builder
    @builder ||= Builder.new(Fixture::Model.new,[],[],[0,0,300,300],:page_number=>2,:import_session_id=>'fictional-session')
  end
  def path
    @path ||= Parser.new(["0 0 m 216 0 l 216 216 l 0 216 l h f*\n"],nil).parse.first
  end
  def rectangle
    [point(0,0),point(3,0),point(3,3),point(0,3),point(0,0)]
  end
  def draw(entities,points=rectangle)
    builder.send(:draw_source_fill,entities,points,path,7,1,nil,[0,0,0],true)
  end

  def test_exact_closing_marker_is_removed_independently_of_native_length_comparison
    model=Fixture::Model.new
    built=Builder.new(model,[],[],[0,0,300,300],:merge_tolerance=>0.0)
    cleaned=built.send(:build_face_loop,rectangle)
    assert_equal rectangle.first(4).map { |p| [p.x,p.y,p.z] },cleaned.map { |p| [p.x,p.y,p.z] }
  end
  def test_real_short_quadrilateral_edge_is_retained
    points=[point(1,2),point(1.045,2),point(1.045,2.0003),point(1,2.001),point(1,2)]
    clean=builder.send(:build_face_loop,points)
    assert_equal 4,clean.length
    assert_equal points.first(4).map { |p| [p.x,p.y,p.z] },clean.map { |p| [p.x,p.y,p.z] }
    owner=Fixture::Entities.new
    assert draw(owner,points)
    builder.send(:flush_deferred_small_faces!)
    instance=owner.to_a.grep(Fixture::ComponentInstance).first
    refute_nil instance
    assert_equal 4,instance.definition.entities.to_a.grep(Fixture::Face).first.points.length
    assert_empty builder.fill_delivery_failures
  end
  def test_positive_contour_below_old_area_screen_is_constructed
    points=[point(0,0),point(0.01,0),point(0.01,0.00002),point(0,0)]
    assert builder.send(:build_face_loop,points)
    owner=Fixture::Entities.new
    assert draw(owner,points)
    builder.send(:flush_deferred_small_faces!)
    assert_equal 1,owner.to_a.grep(Fixture::ComponentInstance).length
    assert_empty builder.fill_delivery_failures
  end
  def test_signed_zero_area_bowtie_is_not_a_no_ink_exclusion
    bowtie=[point(0,0),point(3,3),point(0,3),point(3,0),point(0,0)]
    refute builder.send(:proven_collinear_fill?,bowtie)
    assert builder.send(:build_face_loop,bowtie)
    refute draw(NilFaceEntities.new,bowtie)
    assert_equal 1,builder.fill_delivery_failures.length
    assert_equal 'native_fill_returned_no_face',builder.fill_delivery_failures[0][:reason]
  end
  def test_exact_collinear_and_identical_contours_do_not_claim_lost_ink
    refute draw(NilFaceEntities.new,[])
    assert_equal 1,builder.fill_delivery_failures.length
    [[point(2,3),point(2,3),point(2,3)],
     [point(0,0),point(1,2),point(2,4),point(0,0)]].each do |points|
      refute draw(NilFaceEntities.new,points)
      assert_equal 1,builder.fill_delivery_failures.length
    end
    assert_equal 'source_fill_not_buildable',builder.fill_delivery_failures.first[:reason]
  end
  def test_near_collinear_positive_contour_is_not_certified_empty
    points=[point(2,3),point(3,4),point(4,5.000000000000001)]
    refute builder.send(:proven_collinear_fill?,points)
    assert builder.send(:build_face_loop,points)
  end
  def test_interior_repeat_is_never_silently_deleted
    points=[point(0,0),point(3,0),point(3,3),point(3,0),point(0,3)]
    clean=builder.send(:build_face_loop,points)
    assert_equal points.length,clean.length
    assert_equal points.map { |p| [p.x,p.y,p.z] },clean.map { |p| [p.x,p.y,p.z] }
  end
  def test_nil_and_exception_record_exact_original_source_context
    [NilFaceEntities.new,RaisedFaceEntities.new].each do |entities|
      refute draw(entities)
      record=builder.fill_delivery_failures.last
      assert_equal 'bcs.sketchup.fill_delivery_failure/1',record[:schema]
      assert_equal 'original_pdf_fill',record[:source_kind]
      assert_equal 2,record[:page]
      assert_equal 7,record[:path_index]
      assert_equal 1,record[:subpath_index]
      assert_equal path.source_paint_order,record[:source_paint_order]
      assert_equal 'evenodd',record[:fill_rule]
      assert_equal false,record[:delivered]
      assert_equal true,record[:partial_cleanup_verified]
      assert_equal 5,record[:original_source_point_count]
      assert_match(/\A[0-9a-f]{64}\z/,record[:original_source_input_sha256])
    end
  end
  def test_partial_native_artifacts_are_removed_without_erasing_a_successful_peer
    entities=PartialFaceEntities.new
    peer=Fixture::Face.new([point(10,10),point(12,10),point(12,12)])
    entities.instance_variable_get(:@items) << peer
    refute draw(entities)
    assert_equal [peer],entities.to_a
    assert_equal 1,builder.fill_delivery_failures.last[:partial_artifact_count_removed]
  end
  def test_uncertain_partial_cleanup_remains_terminal
    assert_raises(Builder::FillRollbackFailure) { draw(UncertainCleanupEntities.new) }
  end
  def test_successful_scaled_recovery_removes_the_rejected_direct_attempt
    points=[point(0,0),point(0.006,0),point(0.006,0.006),point(0,0.006)]
    entities=PartialPlanarFailureEntities.new
    assert draw(entities,points)
    builder.send(:flush_deferred_small_faces!)
    assert_empty entities.to_a.grep(Fixture::Face)
    assert_equal 1,entities.to_a.grep(Fixture::ComponentInstance).length
    assert_empty builder.fill_delivery_failures
  end
  def test_uncertain_direct_recovery_cleanup_does_not_enqueue_a_success
    points=[point(0,0),point(0.006,0),point(0.006,0.006),point(0,0.006)]
    assert_raises(Builder::FillRollbackFailure) { draw(UncertainPlanarCleanupEntities.new,points) }
    assert_empty builder.instance_variable_get(:@deferred_small_face_batches)
  end
  def test_changed_existing_peer_geometry_is_terminal_even_after_new_artifacts_are_removed
    [MutatingPeerEntities.new,MutatingPlanarPeerEntities.new,MutatingStylePeerEntities.new].each do |entities|
      peer=Fixture::Face.new([point(10,10),point(12,10),point(12,12)])
      peer.material=Fixture::Material.new
      peer.material.color=Sketchup::Color.new(1,2,3)
      entities.instance_variable_get(:@items) << peer
      points=[point(0,0),point(0.006,0),point(0.006,0.006),point(0,0.006)]
      assert_raises(Builder::FillRollbackFailure) { draw(entities,points) }
      assert_empty builder.instance_variable_get(:@deferred_small_face_batches)
      refute builder.fill_delivery_failures.any? { |row| row[:partial_cleanup_verified] }
    end
  end
  def test_deferred_nil_and_exception_retain_source_context_and_fail_the_page
    [NilFaceEntities, RaisedFaceEntities].each do |entities_class|
      model = Fixture::Model.new
      definitions = RejectingDefinitions.new(entities_class)
      model.instance_variable_set(:@definitions, definitions)
      built = Builder.new(model,[],[],[0,0,300,300],:page_number=>2,:import_session_id=>'fictional-session')
      points=[point(1,2),point(1.02,2),point(1.02,2.0003),point(1,2.001),point(1,2)]
      assert built.send(:draw_source_fill,Fixture::Entities.new,points,path,7,1,nil,[0,0,0],true)
      error=assert_raises(Builder::FillDeliveryFailure) { built.send(:flush_deferred_small_faces!) }
      row=error.fill_delivery_failures.first
      assert_equal 'scaled_fill_construction_failed',row[:reason]
      assert_equal 'original_pdf_fill',row[:source_kind]
      assert_equal [2,7,1],[row[:page],row[:path_index],row[:subpath_index]]
      assert_equal path.source_paint_order,row[:source_paint_order]
      assert_match(/\A[0-9a-f]{64}\z/,row[:original_source_input_sha256])
      assert_equal 1,definitions.removed.length
      assert_empty definitions.items
      refute row[:delivered]
    end
  end
  def test_deferred_instance_nil_and_exception_report_every_queued_source_contour
    [NilInstanceEntities.new,RaisedInstanceEntities.new].each do |owner|
      model=Fixture::Model.new
      model.instance_variable_set(:@definitions,RejectingDefinitions.new(Fixture::Entities))
      built=Builder.new(model,[],[],[0,0,300,300],:page_number=>2)
      points=[point(0,0),point(0.01,0),point(0.01,0.0003),point(0,0)]
      [4,9].each { |index| assert built.send(:draw_source_fill,owner,points,path,index,0,nil,[0,0,0],true) }
      error=assert_raises(Builder::FillDeliveryFailure) { built.send(:flush_deferred_small_faces!) }
      rows=error.fill_delivery_failures
      assert_equal [4,9],rows.map { |row| row[:path_index] }
      assert rows.all? { |row| row[:reason]=='scaled_fill_instance_failed' && row[:delivered]==false }
      assert_empty owner.to_a
    end
  end
  def test_nested_evenodd_compound_failure_never_paints_hole_contours_as_separate_fills
    nested=Parser.new(["0 0 m 216 0 l 216 216 l 0 216 l h 72 72 m 144 72 l 144 144 l 72 144 l h f*\n"],nil).parse.first
    [BlueCollarSystems::PDFVectorImporter::ImportRunControl::RollbackFailure,
     Builder::FillDeliveryFailure].each do |error_class|
      model=Fixture::Model.new
      built=Builder.new(model,[nested],[],[0,0,300,300],:group_per_page=>false,:page_number=>2)
      assert built.send(:compound_fill_needs_punch?,nested)
      built.define_singleton_method(:draw_source_compound_fill) do |*_args|
        message='fictional compound construction/cleanup uncertain'
        raise(error_class == Builder::FillDeliveryFailure ?
              error_class.new(message,[]) : error_class.new(message))
      end
      assert_raises(error_class) { built.build }
      assert_empty model.definitions.items
      assert_equal 0,built.instance_variable_get(:@face_count)
    end
  end
  def test_actual_compound_constructor_rejection_is_typed_and_bound_to_real_source_path
    model=Fixture::Model.new
    built=Builder.new(model,[],[],[0,0,300,300],:page_number=>2)
    built.define_singleton_method(:draw_compound_clip_fill) { |*_args| raise 'fictional compound native rejection' }
    error=assert_raises(Builder::FillDeliveryFailure) do
      built.send(:draw_source_compound_fill,Fixture::Entities.new,[rectangle],path,7,:evenodd,nil,[0,0,0])
    end
    row=error.fill_delivery_failures.first
    assert_equal 'original_pdf_compound_fill',row[:source_kind]
    assert_equal 7,row[:path_index]
    assert_equal [0],row[:source_subpath_indices]
    assert_equal path.source_paint_order,row[:source_paint_order]
    assert_equal 'compound_fill_construction_failed',row[:reason]
    refute row.key?(:subpath_index), 'a compound failure must not invent one original subpath'
    refute row[:delivered]
  end
  def test_failed_page_record_preserves_typed_fill_rows_without_claiming_retention
    draw(NilFaceEntities.new)
    rows=builder.fill_delivery_failures
    error=Builder::FillDeliveryFailure.new('fictional source fill batch failed',rows)
    orchestrator=BlueCollarSystems::PDFVectorImporter::ImportRunControl::PageOrchestrator.allocate
    row=orchestrator.send(:page_failure_record,2,error)
    assert_equal 2,row[:page]
    assert_equal rows,row[:fill_delivery_failures]
    assert_equal error.class.name,row[:error_class]
    refute row.key?(:retained_pages)
    assert_equal JSON.parse(JSON.generate(rows)),JSON.parse(JSON.generate(row[:fill_delivery_failures]))
  end
  def test_one_authentic_many_contour_evenodd_paint_has_linear_bounded_peer_captures
    [16,32,64].each do |count|
      stream=(0...count).map { |i| "#{i*216} 0 m #{i*216+144} 0 l #{i*216+144} 144 l #{i*216} 144 l h" }.join(' ')+' f*'
      source=Parser.new([stream],nil).parse
      assert_equal 1,source.length
      assert_equal count,source[0].subpaths.length
      refute_nil source[0].source_paint_order
      model=Fixture::Model.new
      built=CountingBuilder.new(model,source,[],[0,0,count*216,300],:group_per_page=>false,:detect_arcs=>false)
      stats=built.build
      assert_equal count,stats[:faces]
      assert_operator built.peer_visits.to_i,:<=,count*(Builder::FILL_CONSTRUCTION_CONTOURS-1)/2
      faces=[]
      visit=lambda { |entities| entities.to_a.each { |entity| faces << entity if entity.is_a?(Fixture::Face);visit.call(entity.entities) if entity.is_a?(Fixture::Group) } }
      visit.call(model.active_entities)
      assert_equal count,faces.length
      assert faces.all? { |face| face.points.length==4 && face.edges.all?(&:hidden) }
      assert_empty stats[:fill_delivery_failures]
    end
  end
  def test_huge_face_and_deferred_definition_rotate_before_any_recursive_peer_capture
    [10.0,0.01].each do |radius|
      model=Fixture::Model.new
      built=CountingBuilder.new(model,[],[],[0,0,300,300],:page_number=>2)
      owner=Fixture::Entities.new
      points=1024.times.map { |i| angle=2*Math::PI*i/1024;point(radius*Math.cos(angle),radius*Math.sin(angle)) }
      assert built.send(:draw_source_fill,owner,points,path,7,0,nil,[0,0,0],true)
      built.send(:flush_deferred_small_faces!)
      assert built.send(:draw_source_fill,owner,rectangle,path,7,1,nil,[0,0,0],true)
      assert_equal 0,built.peer_visits.to_i
      assert_equal 1,owner.to_a.grep(Fixture::Group).length
      original=owner.to_a.grep(Fixture::Face).first
      original ||= owner.to_a.grep(Fixture::ComponentInstance).first.definition.entities.to_a.grep(Fixture::Face).first
      assert_equal 1024,original.points.length
      assert_empty built.fill_delivery_failures
    end
  end
  def test_definition_cleanup_missing_raising_and_noop_are_terminal_with_original_source_record
    [Fixture::Definitions.new,RaisingRemoveDefinitions.new(NilFaceEntities),NoOpRemoveDefinitions.new(NilFaceEntities)].each do |definitions|
      if definitions.is_a?(Fixture::Definitions) && !definitions.is_a?(RejectingDefinitions)
        definitions.define_singleton_method(:add) do |name|
          definition=super(name)
          definition.instance_variable_set(:@entities,NilFaceEntities.new)
          definition
        end
      end
      model=Fixture::Model.new
      model.instance_variable_set(:@definitions,definitions)
      built=Builder.new(model,[],[],[0,0,300,300],:page_number=>2)
      points=[point(0,0),point(0.01,0),point(0.01,0.0003),point(0,0)]
      assert built.send(:draw_source_fill,Fixture::Entities.new,points,path,7,1,nil,[0,0,0],true)
      error=assert_raises(Builder::FillRollbackFailure) { built.send(:flush_deferred_small_faces!) }
      assert_kind_of BlueCollarSystems::PDFVectorImporter::ImportRunControl::RollbackFailure,error
      row=error.fill_delivery_failures.first
      assert_equal 'scaled_fill_construction_failed',row[:reason]
      assert_equal [2,7,1],[row[:page],row[:path_index],row[:subpath_index]]
      refute row[:delivered]
    end
  end
  def test_partial_instance_cleanup_is_verified_or_terminal
    [PartialInstanceEntities.new,UncertainInstanceEntities.new].each do |owner|
      model=Fixture::Model.new
      model.instance_variable_set(:@definitions,RejectingDefinitions.new(Fixture::Entities))
      built=Builder.new(model,[],[],[0,0,300,300],:page_number=>2)
      points=[point(0,0),point(0.01,0),point(0.01,0.0003),point(0,0)]
      assert built.send(:draw_source_fill,owner,points,path,7,1,nil,[0,0,0],true)
      klass=owner.is_a?(UncertainInstanceEntities) ? Builder::FillRollbackFailure : Builder::FillDeliveryFailure
      error=assert_raises(klass) { built.send(:flush_deferred_small_faces!) }
      assert_equal 'scaled_fill_instance_failed',error.fill_delivery_failures.first[:reason]
      assert_empty owner.to_a unless owner.is_a?(UncertainInstanceEntities)
    end
  end
  def test_compound_group_cleanup_verified_and_noop_or_raising_terminal
    [RejectedCompoundGroup,NoOpCompoundGroup,RaisingCompoundGroup].each do |group_class|
      model=Fixture::Model.new
      built=Builder.new(model,[],[],[0,0,300,300],:page_number=>2)
      owner=CompoundParent.new(group_class)
      klass=group_class==RejectedCompoundGroup ? Builder::FillDeliveryFailure : Builder::FillRollbackFailure
      error=assert_raises(klass) { built.send(:draw_source_compound_fill,owner,[rectangle],path,7,:evenodd,nil,[0,0,0]) }
      row=error.fill_delivery_failures.first
      assert_equal 'original_pdf_compound_fill',row[:source_kind]
      assert_equal 7,row[:path_index]
      refute row[:delivered]
      assert_empty owner.to_a if group_class==RejectedCompoundGroup
    end
  end
  def test_unbound_failure_never_invents_original_path_identity
    refute builder.send(:draw_face,NilFaceEntities.new,rectangle,nil,[0,0,0],true)
    failure=builder.fill_delivery_failures.last
    assert_equal 'unbound_fill',failure[:source_kind]
    assert_equal 'unresolved',failure[:source_binding]
    refute failure.key?(:path_index)
    refute failure.key?(:subpath_index)
  end
  def test_failures_survive_json_reporting_warning_readiness_and_plain_completion
    draw(NilFaceEntities.new)
    row=builder.fill_delivery_failures.first
    [{:fill_delivery_failures=>[row]},JSON.parse(JSON.generate(:fill_delivery_failures=>[row]))].each do |data|
      stats={:pages=>1,:primitives=>3,:edges=>9,:text=>0,:layers=>[]}.merge(data)
      report=QA.build_from_stats('fictional-fill.pdf',{:import_mode=>'auto'},stats)
      assert_equal 1,report[:result][:warnings]
      assert_equal false,report[:extra][:import_contract_ready][:ready]
      assert_equal false,report[:extra][:import_contract_ready][:checks][:source_filled_geometry_retained]
      assert_equal false,report[:extra][:representation_fidelity][:checks][:source_filled_geometry_retained]
      assert_equal JSON.parse(JSON.generate([row])),JSON.parse(JSON.generate(report[:extra][:fill_delivery_failures]))
      assert_includes report[:extra][:human_summary],'1 filled shape could not be created'
      message=BlueCollarSystems::PDFVectorImporter::ReportDialog.completion_status(stats)
      assert_includes message,'finished with problems'
      assert_includes message,'1 filled shape could not be created'
      BlueCollarSystems::PDFVectorImporter::ImportHealth.record!(stats)
      assert_equal JSON.parse(JSON.generate([row])),JSON.parse(JSON.generate(BlueCollarSystems::PDFVectorImporter::ImportHealth.snapshot[:fill_delivery_failures]))
    end
  end
end
