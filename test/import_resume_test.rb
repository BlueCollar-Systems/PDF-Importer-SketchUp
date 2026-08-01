#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class ImportResumeTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl

  class AttrObject
    def initialize
      @attributes = {}
    end

    def set_attribute(dict, key, value)
      @attributes[[dict, key]] = value
    end

    def get_attribute(dict, key, default = nil)
      @attributes.fetch([dict, key], default)
    end
  end

  class Leaf
    attr_reader :persistent_id

    Point = Struct.new(:x, :y, :z)
    Vertex = Struct.new(:position)

    def initialize(id, kind = 'Edge')
      @persistent_id = id
      @kind = kind
      @start = Vertex.new(Point.new(0.0, 0.0, 0.0))
      @end = Vertex.new(Point.new(1.0, 0.0, 0.0))
    end

    def valid?; true; end
    def typename; @kind; end
    def start; @start; end
    def end; @end; end
    def move_end!(x, y, z); @end.position = Point.new(x, y, z); end
  end

  class Entities
    def initialize(items = [])
      @items = items
    end

    def to_a; @items.dup; end
    def add(item); @items << item; item; end
  end

  class Group < AttrObject
    attr_accessor :name
    attr_reader :persistent_id, :entities

    def initialize(id, page)
      super()
      @persistent_id = id
      @name = "PDF Page #{page}"
      @entities = Entities.new([Leaf.new(id * 10)])
      @valid = true
    end

    def valid?; @valid; end
    def typename; 'Group'; end
    def invalidate!; @valid = false; end
  end

  class Model < AttrObject
    attr_reader :active_entities

    def initialize
      super
      @active_entities = Entities.new
    end
  end

  def identity(overrides = {})
    {
      :pdf_sha256 => 'a' * 64,
      :options_sha256 => 'b' * 64,
      :importer_sha256 => 'c' * 64,
      :package_sha256 => 'd' * 64,
      :source_tree_sha256 => 'e' * 64
    }.merge(overrides)
  end

  def controller(model, overrides = {})
    IRC::Controller.new(
      :model => model,
      :pages => [1, 2, 3],
      :requested_mode => :text3d,
      :identity => identity(overrides),
      :clock => lambda { 0.0 }
    )
  end

  def add_group(model, page, id)
    model.active_entities.add(Group.new(id, page))
  end

  def test_certified_page_survives_controller_recreation_and_save_reopen_shape
    model = Model.new
    page = add_group(model, 1, 101)
    first = controller(model)
    first.certify_page!(page, 1, :next_y_offset => 12.5)

    reopened = controller(model)
    assert_equal [1], reopened.resumable_pages
    assert_equal 12.5, reopened.resume_y_offset
    journal = reopened.journal
    assert_equal IRC::JOURNAL_SCHEMA, journal['schema']
    string_identity = {}
    identity.each { |key, value| string_identity[key.to_s] = value }
    assert_equal string_identity, journal['identity']
    assert_equal 101, journal['pages'][0]['group_persistent_id']
  end

  def test_different_identity_dimensions_never_reuse_an_unrelated_journal
    identity.keys.each do |key|
      model = Model.new
      controller(model).certify_page!(add_group(model, 1, 101), 1)
      mismatch = controller(model, key => 'f' * 64)
      assert_equal [], mismatch.resumable_pages
      assert_equal [1], controller(model).resumable_pages
    end
  end

  def test_resume_rejects_edited_missing_and_duplicate_retained_groups
    edited_model = Model.new
    edited = add_group(edited_model, 1, 101)
    controller(edited_model).certify_page!(edited, 1)
    edited.entities.add(Leaf.new(999))
    assert_raises(IRC::ResumeMismatch) do
      controller(edited_model).resumable_pages
    end

    missing_model = Model.new
    missing = add_group(missing_model, 1, 101)
    controller(missing_model).certify_page!(missing, 1)
    missing.invalidate!
    assert_raises(IRC::ResumeMismatch) do
      controller(missing_model).resumable_pages
    end

    duplicate_model = Model.new
    original = add_group(duplicate_model, 1, 101)
    controller(duplicate_model).certify_page!(original, 1)
    duplicate = add_group(duplicate_model, 1, 202)
    duplicate.set_attribute(
      IRC::JOURNAL_DICTIONARY, 'journal_id',
      original.get_attribute(IRC::JOURNAL_DICTIONARY, 'journal_id')
    )
    duplicate.set_attribute(IRC::JOURNAL_DICTIONARY, 'page_number', 1)
    assert_raises(IRC::ResumeMismatch) do
      controller(duplicate_model).resumable_pages
    end
  end

  def test_resume_rejects_in_place_geometry_edits_without_topology_changes
    model = Model.new
    page = add_group(model, 1, 101)
    controller(model).certify_page!(page, 1)

    page.entities.to_a.first.move_end!(2.0, 0.0, 0.0)

    assert_raises(IRC::ResumeMismatch) do
      controller(model).resumable_pages
    end
  end

  def test_page_orchestrator_keeps_only_certified_pages_and_resumes_next_page
    model = Model.new
    first_controller = controller(model)
    calls = []
    runner = lambda do |page, offset, certify|
      calls << [page, offset]
      if page == 3
        raise IRC::ImportCancelled.new([1, 2], 3, { :stage => :text_item })
      end
      group = add_group(model, page, 100 + page)
      next_offset = offset + 10.0
      page_stats = { :pages => 1, :edges => page }
      certify.call(group, next_offset, page_stats)
      { :stats => page_stats,
        :next_y_offset => next_offset }
    end
    first = IRC::PageOrchestrator.new(
      :model => model, :controller => first_controller,
      :pages => [1, 2, 3], :runner => runner
    ).run

    assert first[:cancelled]
    assert_equal [1, 2], first[:retained_pages]
    assert_equal 3, first[:next_page]
    assert_equal [[1, 0.0], [2, 10.0], [3, 20.0]], calls
    assert_equal 2, model.active_entities.to_a.length

    resumed_calls = []
    resumed_controller = controller(model)
    resumed_runner = lambda do |page, offset, certify|
      resumed_calls << [page, offset]
      group = add_group(model, page, 100 + page)
      page_stats = { :pages => 1, :edges => page }
      certify.call(group, offset + 10.0, page_stats)
      { :stats => page_stats,
        :next_y_offset => offset + 10.0 }
    end
    resumed = IRC::PageOrchestrator.new(
      :model => model, :controller => resumed_controller,
      :pages => [1, 2, 3], :runner => resumed_runner
    ).run

    refute resumed[:cancelled]
    assert_equal [[3, 20.0]], resumed_calls
    assert_equal [1, 2], resumed[:resumed_pages]
    assert_equal [3], resumed[:new_pages]
    assert_equal [1, 2, 3], resumed[:retained_pages]
    assert_equal 6, resumed[:stats][:edges]
  end

  def test_page_orchestrator_requires_certifier_and_group_per_page
    model = Model.new
    error = assert_raises(ArgumentError) do
      IRC::PageOrchestrator.new(
        :model => model, :controller => controller(model),
        :pages => [1], :runner => lambda { |_p, _o, _c| {} },
        :group_per_page => false
      ).run
    end
    assert_match(/Group-per-page/, error.message)

    error = assert_raises(IRC::ResumeMismatch) do
      IRC::PageOrchestrator.new(
        :model => model, :controller => controller(model),
        :pages => [1], :runner => lambda { |_p, _o, _c| { :stats => {} } }
      ).run
    end
    assert_match(/certified/, error.message)
  end

  def test_identity_for_binds_pdf_behavior_and_loaded_source_but_not_callbacks
    Dir.mktmpdir('sketchup-resume-identity') do |dir|
      pdf = File.join(dir, 'source.pdf')
      source = File.join(dir, 'plugin')
      Dir.mkdir(source)
      File.binwrite(pdf, '%PDF-synthetic')
      File.write(File.join(source, 'main.rb'), "MAIN = 1\n")
      File.write(File.join(source, 'renderer.rb'), "RENDERER = 1\n")
      base = {
        :pages => [1, 2], :text_mode => :text3d, :scale => 1.0,
        :progress_callback => lambda { nil }, :run_controller => Object.new
      }

      first = IRC.identity_for(pdf, base, source)
      reordered = IRC.identity_for(
        pdf,
        { :scale => 1.0, :text_mode => :text3d, :pages => [1, 2],
          :progress_callback => lambda { raise 'unused' } },
        source
      )
      assert_equal first, reordered
      assert first.values.all? { |value| value =~ /\A[0-9a-f]{64}\z/ }

      changed_options = IRC.identity_for(
        pdf, base.merge(:scale => 2.0), source
      )
      refute_equal first[:options_sha256], changed_options[:options_sha256]

      File.write(File.join(source, 'renderer.rb'), "RENDERER = 2\n")
      changed_source = IRC.identity_for(pdf, base, source)
      refute_equal first[:source_tree_sha256],
                   changed_source[:source_tree_sha256]
      refute_equal first[:importer_sha256], changed_source[:importer_sha256]
    end
  end
end
