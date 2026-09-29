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
    attr_accessor :abort_result
    def initialize
      @contents = [:original_source_edge, :unrelated_user_entity]
      @selection = [Sketchup::Group.new(@contents)]
      @events = []
      @abort_result = true
    end
    def start_operation(*_args)
      @events << :start
      @before = @contents.dup
      true
    end
    def commit_operation; @events << :commit; true; end
    def abort_operation
      @events << :abort
      raise @abort_result if @abort_result.is_a?(Exception)
      @contents.replace(@before) if @abort_result == true
      @abort_result
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

  def test_unconfirmed_cleanup_rollback_reports_uncertain_model_without_retry
    [false, nil, RuntimeError.new('host abort failed')].each do |abort_result|
      model = Model.new
      model.abort_result = abort_result
      messages = with_ui(model, lambda do |entities|
        entities.delete(:original_source_edge)
        raise Importer::GeometryCleanup::CleanupFailure, 'native replacement failed'
      end)
      assert_equal [:start, :abort], model.events
      assert_equal [:unrelated_user_entity], model.contents
      assert_equal 1, messages.length
      assert_includes messages.first, 'Cleanup failed: native replacement failed'
      assert_includes messages.first, 'could not confirm rollback'
      assert_includes messages.first, 'inspect the model before continuing'
    end
  end

  def test_no_selection_does_not_start_or_abort_an_operation
    model = Model.new
    model.selection.clear
    messages = with_ui(model, lambda { |_entities| flunk 'cleanup should not run' })
    assert_empty model.events
    assert_equal ['Select groups to clean.'], messages
  end
end
