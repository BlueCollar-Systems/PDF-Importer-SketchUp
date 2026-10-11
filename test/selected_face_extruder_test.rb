# Contract regressions against the actual product module; not native certification.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/selected_face_extruder'
require_relative 'support/selected_face_extrusion_fixtures'

class SelectedFaceExtruderTest < Minitest::Test
  Tool=BlueCollarSystems::PDFVectorImporter::SelectedFaceExtruder
  def setup; @model=FixtureModel.new; end
  def rectangle(owner=@model.entities,x=0,normal=[0,0,1])
    owner.add_face([[[x,0,0],[x+2,0,0],[x+2,1,0],[x,1,0]]],normal)
  end
  def definition
    d=Sketchup::Definition.new(@model); rectangle(d.entities); d
  end
  def component(d=definition,t=Geom::Transformation.new,owner=@model.entities)
    Sketchup::ComponentInstance.new(@model,d,t,owner)
  end
  def tool_run(depth=0.125); Tool.run(@model,depth); end
  def select(*items); @model.selection=items; end

  def test_strict_supported_depths
    {'1/8"'=>0.125,'1 1/2 in'=>1.5,'.25'=>0.25,'10mm'=>10/25.4,
      "2'"=>24.0,"5'-6 1/2\""=>66.5,'1cm'=>10/25.4,'2yd'=>72.0}.each do |input,expected|
      assert_in_delta expected,Tool.parse_depth(input),1.0e-12,input
    end
  end
  def test_invalid_depths_are_rejected_before_mutation
    ['1/0','0/0','2 1/0','10bananas','0','-1','NaN','Infinity','1e999',
      '1/2 unknown','1" trailing',"2' --1\"",'','9'*129].each do |input|
      assert_raises(Tool::InputError,input) { Tool.parse_depth(input) }
    end
    [Float::INFINITY,Float::NAN,0,-1,'1'].each do |depth|
      assert_raises(Tool::InputError) { Tool.run(@model,depth) }
    end
    assert_empty @model.calls
  end
  def test_nil_native_pushpull_is_verified_as_completed
    face=rectangle; select(face)
    result=tool_run
    assert_equal :completed,result[:status]
    assert_equal 1,result[:faces_extruded]
    assert_equal [0.125],face.calls
    assert_equal [true],face.copy_calls
    assert_equal [:start,:commit],@model.calls
    refute @model.open_operation
  end
  def test_duplicate_face_selection_is_only_extruded_once
    face=rectangle; select(face,face)
    assert_equal 1,tool_run[:faces_extruded]
    assert_equal [0.125],face.calls
  end
  def test_one_selected_instance_cannot_mutate_an_unselected_copy
    d=definition; original=d.entities.to_a.grep(Sketchup::Face).first
    selected=component(d); unselected=component(d); select(selected)
    assert_equal 1,tool_run[:faces_extruded]
    refute_same d,selected.definition
    assert_same d,unselected.definition
    assert_empty original.calls
    assert_equal 0.0,original.positions.first.first[2]
  end
  def test_two_shared_selected_instances_are_individually_isolated_and_not_double_pushed
    d=definition; first=component(d); second=component(d); unselected=component(d)
    original=d.entities.to_a.grep(Sketchup::Face).first; select(first,second,first)
    assert_equal 2,tool_run[:faces_extruded]
    refute_same first.definition,second.definition
    [first,second].each { |instance| assert_equal [0.125],instance.definition.entities.to_a.grep(Sketchup::Face).find { |f| !f.calls.empty? }.calls }
    assert_same d,unselected.definition
    assert_empty original.calls
  end
  def test_nested_shared_definitions_are_isolated_inside_the_selected_parent
    inner=definition; outer=Sketchup::Definition.new(@model)
    nested=component(inner,Geom::Transformation.new,outer.entities)
    selected=component(outer); sibling=component(outer); foreign=component(inner); select(selected)
    assert_equal 1,tool_run[:faces_extruded]
    selected_nested=selected.definition.entities.to_a.grep(Sketchup::ComponentInstance).first
    refute_same outer,selected.definition
    refute_same inner,selected_nested.definition
    assert_same outer,sibling.definition
    assert_same inner,foreign.definition
    assert_same inner,nested.definition
    assert_empty inner.entities.to_a.grep(Sketchup::Face).first.calls
  end
  def test_groups_also_receive_explicit_make_unique
    d=definition; a=Sketchup::Group.new(@model,d); b=Sketchup::Group.new(@model,d); select(a)
    tool_run
    assert_equal 1,a.unique_calls
    assert_same d,b.definition
    refute_same d,a.definition
  end
  def test_full_nested_scale_is_used_for_world_depth
    inner=definition; outer=Sketchup::Definition.new(@model)
    nested=component(inner,Geom::Transformation.scale(3,5,0.5),outer.entities)
    selected=component(outer,Geom::Transformation.scale(2,2,4)); select(selected)
    tool_run
    assert_in_delta 0.0625,nested.definition.entities.to_a.grep(Sketchup::Face).find { |f| !f.calls.empty? }.calls.first,1e-12
  end
  def test_reflection_and_reversed_normal_extrude_up_in_world_coordinates
    [-2.0,2.0].each do |scale_z|
      d=Sketchup::Definition.new(@model); face=rectangle(d.entities,0,[0,0,-1])
      selected=component(d,Geom::Transformation.scale(1,1,scale_z)); select(selected)
      tool_run
      assert_in_delta 0.125/(-scale_z),face.calls.first,1e-12
    end
  end
  def test_positive_footprints_and_hidden_centerlines_are_skipped_without_isolation
    paint=component; paint.set_attribute(Tool::DICTIONARY,'source_width_footprint',true)
    hidden=component; hidden.hidden=true; select(paint,hidden)
    result=tool_run
    assert_equal :no_eligible_faces,result[:status]
    assert_equal 1,result[:skipped][:source_stroke_paint]
    assert_equal 1,result[:skipped][:hidden]
    assert_equal 0,paint.unique_calls
    assert_empty @model.calls
  end
  def test_text_representation_markers_preserve_flat_glyph_faces
    marked=component; marked.set_attribute(Tool::DICTIONARY,'source_kind','svg_glyph_placement')
    select(marked)
    assert_equal 1,tool_run[:skipped][:source_text]
    assert_equal 0,marked.unique_calls
    assert_empty @model.calls
  end
  def test_open_footprint_cell_cannot_bypass_ancestor_protection
    paint=component; paint.set_attribute(Tool::DICTIONARY,'source_width_footprint',true)
    @model.active_path=[paint]; select(paint.definition.entities.to_a.grep(Sketchup::Face).first)
    assert_raises(Tool::SelectionError) { tool_run }
    assert_empty @model.calls
  end
  def test_open_shared_edit_context_is_refused_before_any_operation
    d=definition; a=component(d); component(d)
    @model.active_path=[a]; select(d.entities.to_a.grep(Sketchup::Face).first)
    error=assert_raises(Tool::SelectionError) { tool_run }
    assert_match(/Close the open group or component/,error.message)
    assert_empty @model.calls
  end
  def test_unique_edit_context_is_also_refused_until_native_coordinate_conventions_are_verified
    a=component(definition,Geom::Transformation.scale(1,1,8))
    @model.active_path=[a]; @model.edit_transform=a.transformation
    face=a.definition.entities.to_a.grep(Sketchup::Face).first; select(face)
    assert_raises(Tool::SelectionError) { tool_run }
    assert_empty face.calls
    assert_empty @model.calls
  end
  def test_legacy_homogeneous_scale_is_read_through_transformed_points
    t=Geom::Transformation.new([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,4])
    a=component(definition,t); face=a.definition.entities.to_a.grep(Sketchup::Face).first; select(a)
    tool_run
    assert_in_delta 0.5,face.calls.first,1e-12
  end
  def test_extrusion_axis_shear_is_refused_before_mutation
    t=Geom::Transformation.new([1,0,0,0,0,1,0,0,1,0,1,0,0,0,0,1])
    a=component(definition,t); select(a)
    assert_raises(Tool::TransformError) { tool_run }
    assert_empty @model.calls
  end
  def test_singular_and_nonfinite_transform_are_refused
    [Geom::Transformation.scale(1,1,0),Geom::Transformation.scale(Float::INFINITY)].each do |t|
      a=component(definition,t); select(a)
      assert_raises(Tool::TransformError) { tool_run }
    end
    assert_empty @model.calls
  end
  def test_hidden_layer_and_locked_descendants_are_preserved
    hidden=component; hidden.layer=Sketchup::Layer.new(false)
    locked=component; locked.locked=true; face=rectangle; select(hidden,locked,face)
    result=tool_run
    assert_equal 1,result[:faces_extruded]
    assert_equal 1,result[:skipped][:hidden]
    assert_equal 1,result[:skipped][:locked]
    assert_equal 0,locked.unique_calls
  end
  def test_connected_face_or_loose_edge_is_not_inferred_into_a_profile
    face=rectangle; peer=rectangle(@model.entities,4)
    face.connected_extras << peer; select(face)
    assert_raises(Tool::SelectionError) { tool_run }
    face.connected_extras=[]
    extra=Sketchup::Edge.new(@model,Geom::Point3d.new(0,0,0),Geom::Point3d.new(-1,0,0))
    face.connected_extras << extra
    assert_raises(Tool::SelectionError) { tool_run }
    assert_empty @model.calls
  end
  def test_holes_retain_top_and_complete_side_boundaries
    face=@model.entities.add_face([[[0,0,0],[4,0,0],[4,4,0],[0,4,0]],[[1,1,0],[1,2,0],[2,2,0],[2,1,0]]])
    select(face)
    assert_equal 1,tool_run[:faces_extruded]
    assert_equal [0.125],face.calls
  end
  def test_native_no_effect_or_incomplete_extrusion_rolls_back
    [:no_effect,:missing_sides].each do |mode|
      face=rectangle(@model.entities,mode==:no_effect ? 0 : 4); face.mode=mode
      baseline=face.positions; count=@model.entities.items.length; select(face)
      assert_raises(Tool::ProofError) { tool_run }
      assert_equal baseline,face.positions
      assert_equal count,@model.entities.items.length
      refute @model.open_operation
    end
    assert_equal [:start,:abort,:start,:abort],@model.calls
  end
  def test_any_second_face_failure_aborts_successful_first_and_instance_isolation
    good=rectangle; bad=rectangle(@model.entities,4); bad.mode=:raise_after_change
    d=definition; selected=component(d); component(d); select(good,bad,selected)
    good_before=good.positions; bad_before=bad.positions; count=@model.entities.items.length
    assert_raises(RuntimeError) { tool_run }
    assert_equal good_before,good.positions
    assert_equal bad_before,bad.positions
    assert_same d,selected.definition
    assert_equal count,@model.entities.items.length
    assert_equal [:start,:abort],@model.calls
    refute @model.open_operation
  end
  def test_false_or_raised_commit_is_an_error_and_aborts
    [false,:raise].each do |commit|
      face=rectangle(@model.entities,commit==false ? 0 : 4); baseline=face.positions
      select(face); @model.commit_result=commit
      assert_raises(commit == false ? Tool::TransactionError : RuntimeError) { tool_run }
      assert_equal baseline,face.positions
      refute @model.open_operation
    end
    assert_equal [:start,:commit,:abort,:start,:commit,:abort],@model.calls
  end
  def test_false_start_is_not_owned_and_cannot_abort_a_foreign_operation
    face=rectangle; select(face); @model.start_result=false
    assert_raises(Tool::TransactionError) { tool_run }
    assert_empty face.calls
    assert_equal [:start],@model.calls
  end
  def test_failed_abort_is_explicit_and_retains_original_error
    [false,:raise].each do |abort|
      face=rectangle(@model.entities,abort==false ? 0 : 4); face.mode=:raise_after_change
      select(face); @model.abort_result=abort
      error=assert_raises(Tool::RollbackFailure) { tool_run }
      assert_instance_of RuntimeError,error.primary_error
      assert_match(/pushpull rejected/,error.message)
      assert_match(/could not confirm rollback/,error.message)
      assert_match(/Partial model changes may remain/,error.message)
      assert @model.open_operation
    end
  end
  def test_unselected_peer_mutation_is_detected_and_rolled_back
    face=rectangle; peer=rectangle(@model.entities,4); baseline=peer.positions
    face.peer_to_move=peer; select(face)
    assert_raises(Tool::ProofError) { tool_run }
    assert_equal baseline,peer.positions
    assert_equal [:start,:abort],@model.calls
  end
  def test_isolation_that_leaves_a_shared_definition_is_refused_and_rolled_back
    d=definition; a=component(d); component(d); a.unique_mode=:leave_shared; select(a)
    assert_raises(Tool::SelectionError) { tool_run }
    assert_empty d.entities.to_a.grep(Sketchup::Face).first.calls
    assert_equal [:start,:abort],@model.calls
  end
  def test_live_component_is_refused_before_any_operation
    d=definition; d.live=true; select(component(d))
    assert_raises(Tool::SelectionError) { tool_run }
    assert_empty @model.calls
  end
  def test_decorative_text_wrappers_are_not_isolated_when_a_peer_profile_is_edited
    text=component; text.set_attribute(Tool::DICTIONARY,'decorative_text_container',true)
    wrapper=component; wrapper.set_attribute(Tool::DICTIONARY,'decorative_text_wrapper',true)
    face=rectangle; select(text,wrapper,face)
    result=tool_run
    assert_equal 1,result[:faces_extruded]
    assert_equal 2,result[:skipped][:source_text]
    assert_equal 0,text.unique_calls
    assert_equal 0,wrapper.unique_calls
  end
  def test_arithmetic_overflow_is_rejected_before_a_native_call
    matrix=[[2.0,0,0],[0,1.0,0],[0,0,1.0],[0,0,0]]
    assert_raises(Tool::TransformError) { Tool.point(matrix,[1e308,0,0]) }
    face=@model.entities.add_face([[[1e308,0,0],[1e308,1,0],[1e308,1,1]]],[0,0,1])
    a=Sketchup::Definition.new(@model)
    a.entities.items=@model.entities.items.dup
    selected=component(a,Geom::Transformation.scale(2,1,1)); select(selected)
    assert_raises(Tool::TransformError) { tool_run }
    assert_empty face.calls
    assert_empty @model.calls
  end
  def test_recursion_is_detected_before_container_isolation
    d=definition; component(d,Geom::Transformation.new,d.entities)
    root=component(d); select(root)
    assert_raises(Tool::SelectionError) { tool_run }
    assert_equal 0,root.unique_calls
    assert_empty @model.calls
  end
  def test_rotated_local_vertical_profile_can_be_horizontal_in_world_coordinates
    d=Sketchup::Definition.new(@model)
    face=d.entities.add_face([[[0,0,0],[2,0,0],[2,0,-1],[0,0,-1]]],[0,1,0])
    # (x,y,z) -> (x,-z,y)
    rotation=Geom::Transformation.new([1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1])
    select(component(d,rotation))
    assert_equal 1,tool_run[:faces_extruded]
    assert_in_delta 0.125,face.calls.first,1e-12
  end
  def test_xy_shear_and_translation_preserve_world_vertical_depth
    t=Geom::Transformation.new([1,0,0,0,1,1,0,0,0,0,2,0,50,60,7,1])
    d=definition; face=d.entities.to_a.grep(Sketchup::Face).first; select(component(d,t))
    assert_equal 1,tool_run[:faces_extruded]
    assert_in_delta 0.0625,face.calls.first,1e-12
  end
  def test_a_nonhorizontal_profile_is_reported_without_operation_or_isolation
    d=Sketchup::Definition.new(@model)
    face=d.entities.add_face([[[0,0,0],[2,0,0],[2,0,1],[0,0,1]]],[0,1,0])
    instance=component(d); select(instance)
    result=tool_run
    assert_equal :no_eligible_faces,result[:status]
    assert_equal 1,result[:skipped][:non_horizontal_face]
    assert_empty face.calls
    assert_equal 0,instance.unique_calls
    assert_empty @model.calls
  end
  def test_explicit_manual_target_bound_rejects_large_batch_before_mutation
    faces=(Tool::MAX_TARGETS+1).times.map { |i| rectangle(@model.entities,i*3) }
    select(*faces)
    error=assert_raises(Tool::SelectionError) { tool_run }
    assert_match(/at most 256/,error.message)
    assert faces.all? { |face| face.calls.empty? }
    assert_empty @model.calls
  end
  def test_hidden_parent_tag_folder_is_detected_without_new_api_on_legacy_layers
    outer=Struct.new(:folder,:visible).new(nil,false)
    inner=Struct.new(:folder,:visible).new(outer,true)
    [outer,inner].each { |folder| folder.define_singleton_method(:visible?) { visible } }
    face=rectangle; face.layer.define_singleton_method(:folder) { inner }; select(face)
    result=tool_run
    assert_equal :no_eligible_faces,result[:status]
    assert_equal 1,result[:skipped][:hidden]
    assert_empty face.calls
    assert_empty @model.calls
  end
  def test_boundary_proof_requires_cyclic_order_and_allows_rotation_or_reversal
    expected=[[0,0,0],[2,0,0],[2,2,0],[1,1,0],[0,2,0]]
    assert Tool.matching_points?(expected.rotate(2),expected,1e-7)
    assert Tool.matching_points?(expected.reverse,expected,1e-7)
    wrong=[expected[0],expected[1],expected[3],expected[2],expected[4]]
    refute Tool.matching_points?(wrong,expected,1e-7)
  end
end
