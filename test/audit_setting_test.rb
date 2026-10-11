#!/usr/bin/env ruby
# test/audit_setting_test.rb
#
# SU-1010-17, owner ruling: heavy self-proofs belong in an optional Audit
# setting or in CI, never in every import. "Audit import (slow self-checks)"
# is off by default; BC_PDF_AUDIT=1, --audit or the saved setting turn it on.
# Off: the PDF is hashed once per import (size and times are trusted after
# that) and the per-page entity census is skipped. On: today's behaviour.
# Fictional data only.

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/cli'

class AuditSettingTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  IRC = IMP::ImportRunControl
  CE = IMP::RepresentationFidelity::ContractError

  def setup
    @saved_env = ENV['BC_PDF_AUDIT']
    ENV.delete('BC_PDF_AUDIT')
  end

  def teardown
    if @saved_env.nil?
      ENV.delete('BC_PDF_AUDIT')
    else
      ENV['BC_PDF_AUDIT'] = @saved_env
    end
  end

  def with_hash_counter
    calls = []
    original = Digest::SHA256.method(:file)
    Digest::SHA256.define_singleton_method(:file) do |path|
      calls << path
      original.call(path)
    end
    yield calls
  ensure
    Digest::SHA256.define_singleton_method(:file, original) if original
  end

  def with_pdf(body = "%PDF-1.4\nsource-a\n%%EOF\n")
    Dir.mktmpdir('audit-setting') do |dir|
      pdf = File.join(dir, 'fictional.pdf')
      File.binwrite(pdf, body)
      yield pdf
    end
  end

  # ---- the switch -------------------------------------------------------

  def test_audit_is_off_by_default_and_on_by_env_or_option
    refute IMP.audit_mode?({})
    refute IMP.audit_mode?(:audit => false)
    assert IMP.audit_mode?(:audit => true)
    ENV['BC_PDF_AUDIT'] = '1'
    assert IMP.audit_mode?({})
    ENV['BC_PDF_AUDIT'] = '0'
    refute IMP.audit_mode?({})
  end

  def test_build_opts_defaults_audit_off_and_yes_turns_it_on
    dialog = IMP::ImportDialog
    dialog.stub(:saved_audit_setting, nil) do
      assert_equal false, dialog.send(:build_opts, {})[:audit]
      assert_equal true, dialog.send(:build_opts, :audit => 'Yes')[:audit]
      assert_equal false, dialog.send(:build_opts, :audit => 'No')[:audit]
      ENV['BC_PDF_AUDIT'] = '1'
      assert_equal true, dialog.send(:build_opts, :audit => 'No')[:audit],
                   'BC_PDF_AUDIT=1 turns Audit on for CI and the host harness'
    end
    ENV.delete('BC_PDF_AUDIT')
    dialog.stub(:saved_audit_setting, 'Yes') do
      assert_equal true, dialog.send(:build_opts, {})[:audit],
                   'the saved setting applies when the caller passes none'
    end
    assert_equal 'Audit import (slow self-checks)', dialog::AUDIT_LABEL
  end

  def test_cli_audit_flag
    assert_equal true, IMP::CLI.parse_args(['--input', 'fictional.pdf', '--audit'])[:audit]
    assert_nil IMP::CLI.parse_args(['--input', 'fictional.pdf'])[:audit]
  end

  def test_resume_identity_is_unchanged_by_audit
    Dir.mktmpdir('audit-identity') do |dir|
      pdf = File.join(dir, 'fictional.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      source = File.join(dir, 'src')
      Dir.mkdir(source)
      File.write(File.join(source, 'main.rb'), "MAIN = 1\n")
      base = { :pages => [1], :text_mode => :text3d, :scale => 1.0 }
      plain = IRC.identity_for(pdf, base, source)
      audited = IRC.identity_for(
        pdf, base.merge(:audit => true, :import_digest_memo => { 'x' => 1 }), source
      )
      assert_equal plain, audited
    end
  end

  # ---- per-page full-file re-hash ---------------------------------------

  def test_audit_off_commit_gate_does_not_rehash_but_catches_a_size_change
    with_pdf do |pdf|
      opts = {}
      IMP.cached_source_pdf_sha256!(opts, pdf)
      with_hash_counter do |calls|
        assert IMP.verify_cached_source_pdf_bindings!(opts)
        assert_empty calls, 'Audit off: no full-file re-hash at the commit gate'
      end
      File.binwrite(pdf, "%PDF-1.4\nsource-a plus more bytes\n%%EOF\n")
      assert_raises(CE) { IMP.verify_cached_source_pdf_bindings!(opts) }
    end
  end

  def test_audit_on_commit_gate_rehashes_and_catches_a_same_size_rewrite
    with_pdf do |pdf|
      opts = { :audit => true }
      IMP.cached_source_pdf_sha256!(opts, pdf)
      with_hash_counter do |calls|
        assert IMP.verify_cached_source_pdf_bindings!(opts)
        assert_equal 1, calls.length
      end
      time = File.mtime(pdf)
      File.binwrite(pdf, "%PDF-1.4\nsource-b\n%%EOF\n")
      File.utime(time, time, pdf)
      assert_raises(CE) { IMP.verify_cached_source_pdf_bindings!(opts) }
    end
  end

  def test_audit_off_hashes_the_pdf_once_per_import_not_once_per_page
    with_pdf do |pdf|
      memo = {}
      with_hash_counter do |calls|
        3.times do
          page_opts = { :import_digest_memo => memo }
          stats = {}
          IMP.record_source_lineage!(stats, pdf, pdf, nil, page_opts)
          IMP.cached_source_pdf_sha256!(page_opts, pdf)
        end
        assert_equal 1, calls.length, 'one full read of the PDF for three pages'
      end
      with_hash_counter do |calls|
        3.times do
          page_opts = { :import_digest_memo => memo, :audit => true }
          IMP.record_source_lineage!({}, pdf, pdf, nil, page_opts)
          IMP.cached_source_pdf_sha256!(page_opts, pdf)
        end
        assert_equal 9, calls.length, 'Audit on: every page re-proves as today'
      end
    end
  end

  def test_memo_is_not_reused_after_the_file_changes
    with_pdf do |pdf|
      memo = {}
      first = IMP.import_file_sha256({ :import_digest_memo => memo }, pdf)
      File.binwrite(pdf, "%PDF-1.4\nanother size entirely\n%%EOF\n")
      second = IMP.import_file_sha256({ :import_digest_memo => memo }, pdf)
      refute_equal first, second
    end
  end

  # ---- per-page entity census --------------------------------------------

  class CensusCountingController < IRC::Controller
    attr_reader :census_calls
    def entity_census(entity)
      @census_calls = @census_calls.to_i + 1
      super
    end
  end

  class AttrObject
    def initialize; @attributes = {}; end
    def set_attribute(dict, key, value); @attributes[[dict, key]] = value; end
    def get_attribute(dict, key, default = nil)
      @attributes.fetch([dict, key], default)
    end
  end

  class Edge
    Point = Struct.new(:x, :y, :z)
    Vertex = Struct.new(:position)
    attr_reader :persistent_id
    def initialize(id); @persistent_id = id; end
    def valid?; true; end
    def typename; 'Edge'; end
    def start; Vertex.new(Point.new(0.0, 0.0, 0.0)); end
    def end; Vertex.new(Point.new(1.0, 0.0, 0.0)); end
  end

  class Entities
    def initialize(items = []); @items = items; end
    def to_a; @items.dup; end
    def add(item); @items << item; item; end
  end

  class Group < AttrObject
    attr_reader :persistent_id, :entities
    def initialize(id); super(); @persistent_id = id; @entities = Entities.new([Edge.new(id * 10)]); end
    def name; 'PDF Page 1'; end
    def valid?; true; end
    def typename; 'Group'; end
  end

  class Model < AttrObject
    attr_reader :active_entities
    def initialize; super; @active_entities = Entities.new; end
  end

  def certify_with(audit)
    model = Model.new
    group = model.active_entities.add(Group.new(101))
    ctrl = CensusCountingController.new(
      :model => model, :pages => [1], :requested_mode => :text3d,
      :identity => { :pdf_sha256 => 'a' * 64, :options_sha256 => 'b' * 64,
                     :importer_sha256 => 'c' * 64, :package_sha256 => 'd' * 64,
                     :source_tree_sha256 => 'e' * 64 },
      :clock => lambda { 0.0 }, :audit => audit
    )
    ctrl.certify_page!(group, 1)
    refute ctrl.page_reseal_pending?(group, 1),
           'the page still counts as certified in this run'
    ctrl
  end

  def test_certify_skips_the_entity_census_with_audit_off
    assert_equal 0, certify_with(false).census_calls.to_i
    assert_equal 1, certify_with(true).census_calls.to_i
  end

  # ---- the report records the mode ---------------------------------------

  def test_import_report_records_audit_mode
    [true, false].each do |mode|
      stats = { :pages => 1, :audit_mode => mode,
                :pipeline_performance => { :audit => mode, :source_verify_ms => 0.1 } }
      json = JSON.parse(JSON.generate(
        IMP::QAReport.build_from_stats('fictional.pdf', { import_mode: 'auto' }, stats)
      ))
      assert_equal mode, json['extra']['audit_mode']
    end
  end

  def test_pipeline_wires_the_switch
    main = File.read(File.expand_path(
      '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
    ), :encoding => 'UTF-8')
    # The flag is the last argument of the controller call that the page
    # runner uses; a line or two may sit between that call and the runner.
    assert_match(/:audit => opts\[:audit\] == true\n\s*\)\n(?:[^\n]*\n){0,3}?\s*runner = lambda/, main,
                 'the page certifier gets the Audit flag')
    assert_match(/pipeline_performance: \{ :audit => audit_mode\?\(opts\) \}/, main)
    assert_match(/immutable_sha256 = import_file_sha256\(opts, immutable_path\)/, main)
    assert_includes IRC::TRANSIENT_OPTION_KEYS, :audit
    assert_includes IRC::TRANSIENT_OPTION_KEYS, :import_digest_memo
  end
end
