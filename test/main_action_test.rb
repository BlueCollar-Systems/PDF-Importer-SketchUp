# UI fixtures only; no dialogs, native host, imported PDFs or source edits.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/selected_face_extruder'
require_relative 'support/selected_face_extrusion_fixtures'
module Sketchup
  class << self; attr_accessor :fixture_model; end
  def self.active_model; fixture_model; end
end
module UI
  class << self; attr_accessor :response, :messages, :input_calls; end
  def self.inputbox(*args); self.input_calls+=1; response; end
  def self.messagebox(message); messages << message; end
end
module BlueCollarSystems
  module PDFVectorImporter
    module Logger
      class << self; attr_accessor :errors; end
      def self.error(*args); errors << args; end
    end
    # Extract only the real entrypoint to avoid booting the SketchUp importer
    # while retaining exact product source text, filename and line binding.
    main_path=File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb',File.dirname(__FILE__))
    main_source=File.read(main_path)
    method_match=/^    def self\.extrude_selected_faces.*?(?=^    def self\.cleanup_selected)/m.match(main_source)
    raise 'Product extrusion action is missing or ambiguous' unless method_match && main_source.scan(/^    def self\.extrude_selected_faces/).length==1
    method_line=main_source[0...method_match.begin(0)].count("\n")+1
    module_eval(method_match[0],main_path,method_line)
  end
end

class ManualExtrusionMainActionTest < Minitest::Test
  Importer=BlueCollarSystems::PDFVectorImporter
  def setup
    @model=FixtureModel.new; Sketchup.fixture_model=@model
    UI.response=['0.125"']; UI.messages=[]; UI.input_calls=0
    Importer::Logger.errors=[]
  end
  def rectangle(x=0)
    @model.entities.add_face([[[x,0,0],[x+2,0,0],[x+2,1,0],[x,1,0]]])
  end
  def invoke; Importer.extrude_selected_faces; end
  def test_module_and_action_are_bound_to_actual_product_sources
    source_root=File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer',File.dirname(__FILE__))
    assert_equal File.join(source_root,'selected_face_extruder.rb'),File.expand_path(Importer::SelectedFaceExtruder.method(:run).source_location.first)
    main_path=File.join(source_root,'main.rb')
    source=File.read(main_path)
    line=source[0...source.index('    def self.extrude_selected_faces')].count("\n")+1
    assert_equal [main_path,line],Importer.method(:extrude_selected_faces).source_location
  end
  def test_cancelled_depth_dialog_makes_no_changes
    @model.selection=[rectangle]; UI.response=nil
    assert_nil invoke
    assert_empty @model.calls
    assert_empty UI.messages
    assert_empty Importer::Logger.errors
  end
  def test_empty_selection_has_actionable_guidance_without_depth_dialog
    invoke
    assert_match(/Close any open group or component/,UI.messages.last)
    assert_equal 0,UI.input_calls
    assert_empty @model.calls
  end
  def test_bad_depth_is_explained_and_does_not_open_transaction
    @model.selection=[rectangle]; UI.response=['1/0']
    assert_nil invoke
    assert_match(/denominator must be greater than zero/,UI.messages.last)
    assert_empty @model.calls
    assert_equal 1,Importer::Logger.errors.length
  end
  def test_completed_ui_reports_skipped_protected_paint
    d=Sketchup::Definition.new(@model)
    d.entities.add_face([[[4,0,0],[6,0,0],[6,1,0],[4,1,0]]])
    paint=Sketchup::Group.new(@model,d)
    paint.set_attribute(Importer::SelectedFaceExtruder::DICTIONARY,'source_width_footprint',true)
    @model.selection=[rectangle,paint]
    assert_equal :completed,invoke[:status]
    assert_match(/Extruded 1 closed profile/,UI.messages.last)
    assert_match(/Skipped: 1 PDF stroke paint/,UI.messages.last)
    assert_equal [:start,:commit],@model.calls
    assert_equal 0,paint.unique_calls
  end
  def test_partial_native_failure_never_reports_success
    good=rectangle; bad=rectangle(4); bad.mode=:raise_after_change
    baseline=good.positions; @model.selection=[good,bad]
    assert_nil invoke
    assert_match(/did not finish/,UI.messages.last)
    refute_match(/Extruded [0-9]/,UI.messages.last)
    assert_equal baseline,good.positions
    assert_equal [:start,:abort],@model.calls
  end
  def test_false_commit_never_reports_success
    @model.selection=[rectangle]; @model.commit_result=false
    assert_nil invoke
    assert_match(/did not confirm committing/,UI.messages.last)
    refute_match(/Extruded [0-9]/,UI.messages.last)
    assert_equal [:start,:commit,:abort],@model.calls
  end
  def test_failed_abort_has_an_explicit_separate_uncertainty_message
    face=rectangle; face.mode=:raise_after_change
    @model.selection=[face]; @model.abort_result=false
    assert_nil invoke
    assert_match(/pushpull rejected/,UI.messages.last)
    assert_match(/could not confirm rollback/,UI.messages.last)
    assert_match(/Partial model changes may remain/,UI.messages.last)
    assert_instance_of Importer::SelectedFaceExtruder::RollbackFailure,Importer::Logger.errors.last.last
  end
  def test_open_context_failure_tells_user_how_to_select_safely
    d=Sketchup::Definition.new(@model); face=d.entities.add_face([[[0,0,0],[2,0,0],[2,1,0],[0,1,0]]])
    instance=Sketchup::ComponentInstance.new(@model,d)
    @model.active_path=[instance]; @model.selection=[face]
    assert_nil invoke
    assert_match(/Close the open group or component, then select the whole instance/,UI.messages.last)
    assert_empty @model.calls
  end
end
