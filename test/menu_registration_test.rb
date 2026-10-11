#!/usr/bin/env ruby
# test/menu_registration_test.rb
#
# File > Import really offers this importer, the post-import tools the
# README describes can be reached from the Extensions menu, and a File >
# Import failure tells the user why instead of failing silently.
# Ruby 2.2 compatible -- no keyword arguments or safe navigation.

require 'minitest/autorun'
require 'tmpdir'

module MenuRecorder
  class << self
    attr_accessor :items, :importers, :messages
  end
  self.items = {}
  self.importers = []
  self.messages = []
end

class RecordingMenu
  def initialize(path)
    @path = path
  end

  def add_item(label, &block)
    MenuRecorder.items["#{@path} > #{label}"] = block
    MenuRecorder.items.length
  end

  def add_submenu(label)
    RecordingMenu.new("#{@path} > #{label}")
  end

  def add_separator; end
end

module UI
  def self.menu(name = 'Plugins')
    RecordingMenu.new(name)
  end

  def self.messagebox(message, *_rest)
    MenuRecorder.messages << message
    1
  end
end

module Sketchup
  class Importer
    ImportSuccess = 0 unless const_defined?(:ImportSuccess)
    ImportFail = 1 unless const_defined?(:ImportFail)
    ImportCanceled = 2 unless const_defined?(:ImportCanceled)
  end

  class << self
    attr_accessor :fake_model
  end

  def self.register_importer(importer)
    MenuRecorder.importers << importer
    true
  end

  def self.active_model
    fake_model
  end

  def self.status_text=(_text); end
end

MAIN_RB = File.expand_path(
  '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
)
load MAIN_RB
load MAIN_RB

class MenuRegistrationTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  MENU = 'Extensions > PDF Vector Importer'

  class FakeModel
    attr_reader :aborts

    def initialize
      @aborts = 0
    end

    def abort_operation
      @aborts += 1
      true
    end
  end

  def setup
    MenuRecorder.messages = []
    Sketchup.fake_model = FakeModel.new
  end

  def test_file_import_is_registered_exactly_once_for_pdf
    assert_equal 1, MenuRecorder.importers.length
    importer = MenuRecorder.importers.first
    assert_kind_of IMP::PDFFileImporter, importer
    assert_equal 'pdf', importer.file_extension
    assert_equal true, IMP.importer_registered?
  end

  # SketchUp shows an Options... button when this is true; there are no
  # options to show, so the button must not appear.
  def test_file_import_has_no_dead_options_button
    assert_equal false, IMP::PDFFileImporter.new.supports_options?
  end

  def test_post_import_tools_are_in_the_extensions_menu
    {
      'Clean Up Selected Groups' => :cleanup_selected,
      'Feature Inventory...' => :feature_inventory,
      'Show/Hide PDF Tags...' => :visibility_toggles
    }.each do |label, method_name|
      block = MenuRecorder.items["#{MENU} > #{label}"]
      refute_nil block, "#{label} missing from #{MenuRecorder.items.keys.inspect}"
      called = false
      IMP.stub(method_name, lambda { called = true }) { block.call }
      assert called, "#{label} must run #{method_name}"
    end
  end

  def test_menus_are_added_once_even_when_main_loads_twice
    imports = MenuRecorder.items.keys.select { |key| key.end_with?('> Import PDF...') }
    assert_equal ["#{MENU} > Import PDF..."], imports
  end

  def with_pdf
    Dir.mktmpdir('file-import') do |dir|
      path = File.join(dir, 'D042-file-import.pdf')
      File.binwrite(path, "%PDF-1.4\n%%EOF\n")
      yield path
    end
  end

  # Our own box already explains the failure, so SketchUp is told Canceled;
  # ImportFail would make it show its generic failure box as well.
  def test_file_import_failure_shows_one_box_with_the_reason
    with_pdf do |path|
      failing = lambda { |*_args| raise RuntimeError, 'page 1 renderer failed' }
      result = IMP.stub(:handle_open_gate, nil) do
        IMP::ImportDialog.stub(:show, {}) do
          IMP.stub(:run_resumable_pipeline, failing) do
            IMP::PDFFileImporter.new.load_file(path, nil)
          end
        end
      end
      assert_equal Sketchup::Importer::ImportCanceled, result
      assert_equal 1, MenuRecorder.messages.length
      assert_includes MenuRecorder.messages.first, 'PDF import failed'
      assert_includes MenuRecorder.messages.first, 'page 1 renderer failed'
    end
  end

  def test_file_import_runs_the_same_import_as_the_menu
    with_pdf do |path|
      seen = []
      run = lambda do |_model, pdf, opts|
        seen << [pdf, opts]
        { :pages => 1, :result_status => 'success' }
      end
      result = IMP.stub(:handle_open_gate, nil) do
        IMP::ImportDialog.stub(:show, { :text_mode => :text3d }) do
          IMP.stub(:run_resumable_pipeline, run) do
            IMP::ReportDialog.stub(:announce, nil) do
              IMP::PDFFileImporter.new.load_file(path, nil)
            end
          end
        end
      end
      assert_equal Sketchup::Importer::ImportSuccess, result
      assert_equal [[path, { :text_mode => :text3d }]], seen
    end
  end

  def test_file_import_cancel_in_the_dialog_reports_cancelled
    with_pdf do |path|
      result = IMP.stub(:handle_open_gate, nil) do
        IMP::ImportDialog.stub(:show, nil) do
          IMP::PDFFileImporter.new.load_file(path, nil)
        end
      end
      assert_equal Sketchup::Importer::ImportCanceled, result
      assert_empty MenuRecorder.messages
    end
  end

  class Node
    attr_reader :typename, :name, :entities

    def initialize(typename, name = '', children = nil)
      @typename = typename
      @name = name
      @entities = children
    end

    def valid?; true; end

    def get_attribute(*_args); nil; end
  end

  class InventoryModel < FakeModel
    attr_reader :active_entities, :selection

    def initialize(entities)
      super()
      @active_entities = entities
      @selection = []
    end
  end

  def test_feature_inventory_counts_what_each_imported_page_holds
    letters = Node.new('Group', '', [Node.new('Edge'), Node.new('Face')])
    page = Node.new('Group', 'PDF Page 1',
                    [Node.new('Edge'), Node.new('Edge'), Node.new('ComponentInstance'),
                     letters, Node.new('Text')])
    person = Node.new('ComponentInstance', 'Person')
    Sketchup.fake_model = InventoryModel.new([page, person])
    IMP.feature_inventory

    message = MenuRecorder.messages.last
    assert_includes message, 'PDF Page 1: 3 edges, 1 face, 1 group, 1 component, 1 label'
    refute_includes message, 'Person'
  end

  def test_feature_inventory_says_what_to_do_when_nothing_was_imported
    Sketchup.fake_model = InventoryModel.new([])
    IMP.feature_inventory
    assert_includes MenuRecorder.messages.last, 'No imported PDF pages found'
  end

  def test_end_of_import_line_names_the_real_menu_path
    line = IMP::ReportDialog.completion_status(:pages => 1, :edges => 2, :text => 0,
                                               :failed_pages => [{ :page => 1 }])
    assert_includes line, 'Extensions > PDF Vector Importer > Import Health'
  end
end
