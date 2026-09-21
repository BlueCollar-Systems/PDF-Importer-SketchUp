require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

module Sketchup
  class Group
    attr_reader :entities
    def initialize(entities); @entities = entities; end
  end
  def self.active_model; nil; end
end

module UI
  def self.messagebox(_message); end
end

class CleanupSelectedOperationTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter

  class Model
    attr_reader :selection, :events, :contents
    def initialize
      @contents = [:original_source_edge, :unrelated_user_entity]
      @selection = [Sketchup::Group.new(@contents)]
      @events = []
    end
    def start_operation(*_args)
      @events << :start
      @before = @contents.dup
    end
    def commit_operation; @events << :commit; end
    def abort_operation
      @events << :abort
      @contents.replace(@before)
    end
  end

  def with_ui(model, cleanup)
    messages = []
    Sketchup.stub(:active_model, model) do
      UI.stub(:messagebox, lambda { |message| messages << message }) do
        Importer::Logger.stub(:error, nil) do
          Importer::GeometryCleanup.stub(:cleanup, cleanup) { Importer.cleanup_selected }
        end
      end
    end
    messages
  end

  def test_destructive_cleanup_failure_aborts_and_restores_existing_user_geometry
    model = Model.new
    original = model.contents.dup
    messages = with_ui(model, lambda do |entities|
      entities.delete(:original_source_edge)
      raise Importer::GeometryCleanup::CleanupFailure, 'native replacement failed'
    end)
    assert_equal [:start, :abort], model.events
    assert_equal original, model.contents
    assert_equal ['Cleanup failed: native replacement failed'], messages
  end

  def test_successful_cleanup_commits_once_and_reports_result
    model = Model.new
    messages = with_ui(model, lambda do |entities|
      entities << :joined_source_edge
      { :joined_collinear => 2 }
    end)
    assert_equal [:start, :commit], model.events
    assert_includes model.contents, :joined_source_edge
    assert_equal ["Cleanup:\n  2 joined_collinear"], messages
  end

  def test_no_selection_does_not_start_or_abort_an_operation
    model = Model.new
    model.selection.clear
    messages = with_ui(model, lambda { |_entities| flunk 'cleanup should not run' })
    assert_empty model.events
    assert_equal ['Select groups to clean.'], messages
  end
end
