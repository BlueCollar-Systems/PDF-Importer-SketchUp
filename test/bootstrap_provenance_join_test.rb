#!/usr/bin/env ruby
# test/bootstrap_provenance_join_test.rb
#
# End-to-end bootstrap↔provenance join lock (corrective 2026-07-12 §1 / RB-01).
#
# v3.7.92 shipped with parts_bootstrap span_ids built from t_<Ruby object_id>
# while source_provenance span_id was the provenance bucket index — the two
# sidecars could NEVER join, and the mock-only unit tests concealed it.
#
# This test drives REAL TextParser::TextItem objects (not mocks) through the
# exact pipeline seam order: TextSourceIdentity.assign! → PartsBootstrap AND
# GeometryBuilder text placement, then asserts the emitted identifiers
# actually join. It also locks the seam ORDER in main.rb/cli.rb source: the
# identity assignment must sit after angle-hint replacement and before
# page_text_map / GeometryBuilder consumption.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

# ── Minimal host stubs so main.rb + GeometryBuilder run headlessly ─────────
module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Transformation
    def initialize(*); end
    def self.rotation(*); new; end
    def self.scaling(*); new; end
  end
end
ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)
TextAlignLeft = 0 unless defined?(TextAlignLeft)
class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end
end unless Numeric.method_defined?(:degrees)

require 'bc_pdf_vector_importer/main'

MOD = BlueCollarSystems::PDFVectorImporter
MOD::Logger.debug = false
TI = MOD::TextParser::TextItem

# Fake SketchUp label/entities host — real GeometryBuilder code paths run,
# only the SketchUp API surface is faked.
class FakeLabel
  attr_accessor :layer, :display_leader, :vector
  attr_reader :persistent_id, :point, :text

  def initialize(id, text, point, vector)
    @persistent_id = id
    @text = text
    @point = point
    @vector = vector
  end

  def typename
    'Text'
  end
end

class FakeEntities
  attr_reader :labels
  def initialize
    @labels = []
    @entities = []
    @next_id = 100
  end

  def to_a
    @entities.dup
  end

  def add_text(text, pt, vec = nil)
    @next_id += 1
    effective_vector = vec || Geom::Vector3d.new(0, 0, 0)
    label = FakeLabel.new(@next_id, text, pt, effective_vector)
    @labels << label
    @entities << label
    label
  end

  def erase_entities(*values)
    values.flatten.each { |value| @entities.delete(value) }
  end
end

class FakeLayer; end

class FakeLayerManager
  def resolve(_name); FakeLayer.new; end
  def text_fallback_layer; FakeLayer.new; end
  def match_pdf_layers; false; end
end

class BootstrapProvenanceJoinTest < Minitest::Test
  MEDIA_BOX = [0, 0, 612, 792].freeze

  # Real TextItem BOM page. All items carry bboxes like external extraction.
  def bom_page_items(page)
    [
      bbox_item('QUAN',           50.0, 500.0, 30.0, 510.0),
      bbox_item('MARK',          120.0, 500.0, 30.0, 510.0),
      bbox_item('DESCRIPTION',   220.0, 500.0, 80.0, 510.0),
      bbox_item('2',              50.0, 460.0, 8.0, 470.0),
      bbox_item('p1019',         120.0, 460.0, 34.0, 470.0),
      bbox_item("PL1/2X8X2'-0\"", 220.0, 460.0, 90.0, 470.0)
    ]
  end

  def second_page_items
    [
      bbox_item('QUAN',        50.0, 500.0, 30.0, 510.0),
      bbox_item('MARK',       120.0, 500.0, 30.0, 510.0),
      bbox_item('3',           50.0, 460.0, 8.0, 470.0),
      bbox_item('b202',       120.0, 460.0, 30.0, 470.0),
      bbox_item('HSS6X6X1/4', 220.0, 460.0, 80.0, 470.0)
    ]
  end

  def bbox_item(text, x, y, w, y1)
    TI.new(text, x, y, 10.0, 0.0, 'pdftotext', nil, x, y, x + w, y1, nil)
  end

  # Narrow-vertical stacked dimension text: GeometryBuilder SPLITS this one
  # item into per-token derived sub-items (sub_dimension_text_item).
  def stacked_dimension_item
    TI.new('2 2', 400.0, 300.0, 10.0, 0.0, 'pdftotext', nil,
           400.0, 300.0, 408.0, 340.0, nil)
  end

  def build_geometry(items, page, bucket, entities = FakeEntities.new)
    builder = MOD::GeometryBuilder.new(
      nil, [], items, MEDIA_BOX,
      import_text: true,
      group_per_page: false,
      page_number: page,
      layer_manager: FakeLayerManager.new,
      target_entities: entities,
      provenance_bucket: bucket,
      import_session_id: 'join-test-session'
    )
    builder.build
  end

  def test_page_two_only_selection_places_only_page_two_text
    page_map = { 1 => bom_page_items(1), 2 => second_page_items }
    selected_pages = MOD.normalized_requested_pages([2], page_map.length)
    assert_equal [2], selected_pages

    bucket = []
    entities = FakeEntities.new
    selected_pages.each do |page|
      MOD::TextSourceIdentity.assign!(page_map.fetch(page), page)
      result = build_geometry(page_map.fetch(page), page, bucket, entities)
      assert_operator result[:text_objects], :>, 0
    end

    placed_text = entities.labels.map(&:text)
    assert_includes placed_text, 'b202'
    refute_includes placed_text, 'p1019'
    assert_equal [2], bucket.map { |entry| entry[:page] }.uniq
    assert page_map.fetch(1).all? { |item| item.source_span_id.nil? },
           'unselected page 1 must not enter identity or placement seams'
  end

  # ── The acceptance test from the corrective spec ─────────────────────────
  def test_end_to_end_bootstrap_provenance_join_two_pages_and_split_text
    page1 = bom_page_items(1) + [stacked_dimension_item]
    page2 = second_page_items

    # The pipeline seam: identity assigned ONCE per page on the final array,
    # BEFORE both consumers see the SAME objects.
    MOD::TextSourceIdentity.assign!(page1, 1)
    MOD::TextSourceIdentity.assign!(page2, 2)

    # Both consumers must observe assigned IDs on every item.
    (page1 + page2).each do |item|
      assert_match(/\Atext_span:\d+:\d+\z/, item.source_span_id.to_s,
                   "item #{item.text.inspect} missing assigned identity")
    end

    # Consumer 1: PartsBootstrap (exact page_text_map shape).
    sidecar = MOD::PartsBootstrap.build({ 1 => page1, 2 => page2 },
                                        session_id: 'join-test-session')
    assert_equal 2, sidecar[:table_count], 'expected BOM tables on both pages'
    rows = sidecar[:tables].map { |t| t[:rows] }.flatten
    refute_empty rows, 'expected extracted BOM rows'

    # Consumer 2: GeometryBuilder provenance over the SAME item objects,
    # one shared bucket across pages like stats[:source_provenance_objects].
    bucket = []
    result1 = build_geometry(page1, 1, bucket)
    result2 = build_geometry(page2, 2, bucket)
    assert_operator result1[:text_objects], :>, 0, 'page 1 placed no text'
    assert_operator result2[:text_objects], :>, 0, 'page 2 placed no text'

    prov_span_ids = bucket.map { |e| e[:span_id] }.compact
    refute_empty prov_span_ids, 'provenance emitted no span_id values'

    # Every provenance entry from the real pipeline path carries span_id.
    bucket.each do |entry|
      assert entry.key?(:span_id),
             "provenance entry #{entry[:object_id]} missing span_id"
    end

    # THE JOIN LOCK: every bootstrap row's span_ids intersect the provenance
    # span_id values (this is exactly what v3.7.92 could not do).
    rows.each do |row|
      refute_empty row[:span_ids], "row #{row[:piece_mark].inspect} has no span_ids"
      joined = row[:span_ids] & prov_span_ids
      refute_empty joined,
                   "row #{row[:piece_mark].inspect} span_ids #{row[:span_ids].inspect} " \
                   "do not join any provenance span_id"
    end

    # NO canonical id may be Ruby memory identity (t_<object_id>).
    (rows.map { |r| r[:span_ids] }.flatten + prov_span_ids).each do |sid|
      refute_match(/\At_\d+\z/, sid.to_s,
                   'canonical ids must never be t_<object_id> (RB-01)')
      assert_match(/\Atext_span:\d+:\d+\z/, sid.to_s)
    end

    # Two-page isolation: page-2 rows join page-2 provenance only.
    page2_rows = sidecar[:tables].find { |t| t[:page] == 2 }[:rows]
    page2_rows.each do |row|
      row[:span_ids].each do |sid|
        assert sid.start_with?('text_span:2:'),
               "page-2 row leaked identity #{sid.inspect}"
        matches = bucket.select { |e| e[:span_id] == sid }
        refute_empty matches
        matches.each { |e| assert_equal 2, e[:page] }
      end
    end
    page1_rows = sidecar[:tables].find { |t| t[:page] == 1 }[:rows]
    page1_rows.each do |row|
      row[:span_ids].each do |sid|
        assert sid.start_with?('text_span:1:'),
               "page-1 row leaked identity #{sid.inspect}"
      end
    end

    # Split/derived case: the stacked "2 2" item was split into two derived
    # sub-items; BOTH provenance entries must keep the SOURCE span identity.
    stacked = page1.find { |it| it.text == '2 2' }
    stacked_entries = bucket.select { |e| e[:span_id] == stacked.source_span_id }
    assert_operator stacked_entries.length, :>=, 2,
                    'split stacked text must record one provenance entry per ' \
                    'derived sub-item, all carrying the source span identity'
    assert_equal stacked_entries.map { |e| e[:object_id] }.uniq.length,
                 stacked_entries.length,
                 'derived entries stay separate created-entity labels'
  end

  # Post-assignment clones keep identity (real helper, not a mock).
  def test_angle_hint_clone_preserves_assigned_identity
    item = TI.new('w1023', 822.0, 760.0, 33.0, 0.0, 'pdftotext', nil,
                  822.0, 760.0, 833.0, 794.0, nil)
    hint = TI.new('w1023', 831.0, 760.0, 11.0, -90.0, 'F1', 1.0)
    MOD::TextSourceIdentity.assign!([item], 1)
    merged = MOD.apply_internal_text_angle_hints([item], [hint])
    refute_same item, merged[0], 'expected an enriched clone'
    assert_equal 'text_span:1:0', merged[0].source_span_id,
                 'clone_text_item_with_hints must copy source_span_id'
  end

  # Parser-derived text (fraction normalization clone) keeps identity.
  def test_fraction_fix_clone_preserves_identity
    parser = MOD::TextParser.new([])
    src = TI.new('5 16', 10.0, 20.0, 8.0, 0.0, 'F1', 8.0)
    src.source_span_id = 'text_span:3:9'
    out = parser.send(:fix_merged_fractions, [src])
    refute_same src, out[0], 'expected a normalized clone'
    assert_equal '5/16', out[0].text
    assert_equal 'text_span:3:9', out[0].source_span_id,
                 'fix_merged_fractions must copy source_span_id'
  end

  # Seam-order lock: assignment sits after final extractor selection/merging/
  # angle hints and BEFORE page_text_map + GeometryBuilder in BOTH pipelines.
  def test_pipeline_seam_order_main_and_cli
    main_src = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'))
    hints_call = main_src.index('text_items = apply_internal_text_angle_hints(text_items, angle_items)')
    assign_call = main_src.index('TextSourceIdentity.assign!(text_items, page_num)')
    map_write = main_src.index('stats[:page_text_map][page_num] = text_items')
    builder_call = main_src.index('GeometryBuilder.new(model, paths, builder_text_items')
    refute_nil hints_call, 'main.rb angle-hint call site missing'
    refute_nil assign_call, 'main.rb must call TextSourceIdentity.assign!'
    refute_nil map_write, 'main.rb page_text_map write missing'
    refute_nil builder_call, 'main.rb GeometryBuilder call site missing'
    assert_operator hints_call, :<, assign_call,
                    'identity must be assigned AFTER angle-hint replacement'
    assert_operator assign_call, :<, map_write,
                    'identity must be assigned BEFORE page_text_map is built'
    assert_operator assign_call, :<, builder_call,
                    'identity must be assigned BEFORE GeometryBuilder consumes items'

    cli_src = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'cli.rb'))
    cli_gate = cli_src.index('certified_pages = certify_page_text_sources(')
    cli_extract = cli_src.index('text_items, text_source = extract_text(')
    cli_assign = cli_src.index('TextSourceIdentity.assign!(text_items, page_num)')
    cli_map = cli_src.index('stats[:page_text_map][page_num] = text_items')
    refute_nil cli_gate, 'cli.rb all-pages identity gate call site missing'
    refute_nil cli_extract, 'cli.rb extract_text call site missing'
    refute_nil cli_assign, 'cli.rb must call TextSourceIdentity.assign!'
    refute_nil cli_map, 'cli.rb page_text_map write missing'
    assert_operator cli_extract, :<, cli_assign,
                    'CLI identity must be assigned AFTER final extraction'
    assert_operator cli_gate, :<, cli_map,
                    'CLI all-pages identity gate must run BEFORE page_text_map is built'
  end
end
