#!/usr/bin/env ruby
# test/text_mode_placement_test.rb
# Per-mode placement checks for PRIVATE-01 key labels (Labels + 3D Text).
# Golden tier regression — see text_category_placement_test.rb for pattern rules.

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require_relative '../corpus_paths'

pdf_tier1 = ENV['BCS_TIER1_USER_PDF'].to_s
if pdf_tier1.empty?
  pdf_tier1 = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_manifest_pdf('PRIVATE-01').to_s
  pdf_tier1 = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf('private/user/PRIVATE-01.pdf').to_s if pdf_tier1.empty?
end
PDF_TIER1_USER = pdf_tier1
PDF_TOL = 1.5

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def assert_near(actual, expected, tol, msg)
  assert_true((actual.to_f - expected.to_f).abs <= tol, msg)
end

TextAlignLeft = 0

class Numeric
  def degrees
    self.to_f * Math::PI / 180.0
  end
end

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
    attr_reader :args, :kind
    def initialize(*args)
      @args = args
      @kind = :translation
    end
    def self.rotation(*args)
      t = new(*args)
      t.instance_variable_set(:@kind, :rotation)
      t
    end

    def self.scaling(*args)
      t = new(*args)
      t.instance_variable_set(:@kind, :scaling)
      t
    end

    def apply(point)
      case @kind
      when :scaling
        pivot, sx, sy, sz = @args
        Geom::Point3d.new(
          pivot.x + ((point.x - pivot.x) * sx.to_f),
          pivot.y + ((point.y - pivot.y) * sy.to_f),
          pivot.z + ((point.z - pivot.z) * sz.to_f)
        )
      when :rotation
        pivot, _axis, radians = @args
        dx = point.x - pivot.x
        dy = point.y - pivot.y
        c = Math.cos(radians.to_f)
        s = Math.sin(radians.to_f)
        Geom::Point3d.new(
          pivot.x + (dx * c) - (dy * s),
          pivot.y + (dx * s) + (dy * c),
          point.z
        )
      else
        delta = @args.first || Geom::Vector3d.new
        Geom::Point3d.new(point.x + delta.x, point.y + delta.y, point.z + delta.z)
      end
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0)
Z_AXIS = Geom::Vector3d.new(0, 0, 1)

class DummyBounds
  attr_reader :min, :max

  def initialize(points)
    @min = Geom::Point3d.new(points.map(&:x).min, points.map(&:y).min, points.map(&:z).min)
    @max = Geom::Point3d.new(points.map(&:x).max, points.map(&:y).max, points.map(&:z).max)
  end
end

class DummyTextEntity
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

class DummyMeshEntity
  attr_accessor :layer

  attr_reader :persistent_id

  def initialize(id, width, height, depth)
    @persistent_id = id
    @points = [
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(width, 0, 0),
      Geom::Point3d.new(width, height, depth),
      Geom::Point3d.new(0, height, 0)
    ]
  end

  def typename
    'Face'
  end

  def bounds
    DummyBounds.new(@points)
  end

  def transform!(transformation)
    @points = @points.map { |point| transformation.apply(point) }
  end
end

class DummyEntities
  attr_reader :texts, :mesh_calls, :entities, :transforms

  def initialize
    @texts = []
    @mesh_calls = []
    @entities = []
    @transforms = []
    @fail_text = false
    @next_id = 100
  end

  def fail_add_text!
    @fail_text = true
  end

  def to_a
    @entities
  end

  def add_text(text, point, vector = nil)
    raise 'add_text forced failure' if @fail_text
    @next_id += 1
    ent = DummyTextEntity.new(@next_id, text, point, vector)
    @entities << ent
    @texts << { text: text, point: point, vector: vector, entity: ent }
    ent
  end

  def add_3d_text(text, align, font, bold, italic, height, tol, z, filled, extrusion)
    @mesh_calls << {
      text: text, height: height, align: align, font: font
    }
    @next_id += 1
    ent = DummyMeshEntity.new(@next_id, height.to_f * 3.0,
                              height.to_f * 0.75, extrusion.to_f)
    @entities << ent
    true
  end

  def transform_entities(transformation, *entities)
    @transforms << [transformation, *entities]
    entities.each { |entity| entity.transform!(transformation) }
  end

  def erase_entities(*entities)
    entities.flatten.each { |entity| @entities.delete(entity) }
  end
end

module Sketchup
  class Model
    def layers; @layers ||= {}; end
    def layers_add(name); layers[name] = name; end
  end
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

def make_builder(use_3d_text:)
  BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
    Sketchup::Model.new,
    [],
    [],
    [0, 0, 612, 792],
    scale_factor: 1.0,
    import_text: true,
    use_3d_text: use_3d_text,
    native_font_identity_resolver: lambda { |source|
      {
        source_span_id: source.source_span_id,
        pdf_font_identity: 'embedded:test-font',
        installed_family: 'Test Exact Font',
        exact_family_match: true,
        verified: true
      }
    }
  )
end

label_builder = make_builder(use_3d_text: false)
mesh_builder = make_builder(use_3d_text: true)

quan = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil, 90.0, 198.0, 130.0, 210.0,
  nil, 'text_span:1:0'
)
lx, ly, lang = label_builder.send(:text_insertion_pdf, quan)
# Horizontal text: Labels and 3D Text share the same PDF anchor. Mesh placement
# must go through mesh_text_insertion_pdf (not the Labels helper alone).
mx, my, mang = mesh_builder.send(:mesh_text_insertion_pdf, quan)
assert_near(lx, mx, 0.01, 'Labels and 3D Text share QUAN insertion X')
assert_near(ly, my, 0.01, 'Labels and 3D Text share QUAN insertion Y')
assert_near(lang, mang, 0.01, 'Labels and 3D Text share QUAN angle')

label_h = label_builder.send(:mesh_text_height_inches, quan, lang, 792.0)
mesh_h = mesh_builder.send(:mesh_text_height_inches, quan, mang, 792.0)
assert_near(label_h, mesh_h, 0.0001, 'mesh_text_height_inches is mode-independent')

def first_translation_point(entities)
  entry = entities.transforms.find do |args|
    args.first.respond_to?(:kind) && args.first.kind == :translation
  end
  return nil unless entry
  tr = entry.first
  tr.respond_to?(:args) ? tr.args.first : nil
end

sample_label_entities = DummyEntities.new
sample_mesh_entities = DummyEntities.new
label_builder.send(:place_text, sample_label_entities, quan, 0.0, 0.0, 792.0, 'TextLayer')
mesh_builder.send(:place_text, sample_mesh_entities, quan, 0.0, 0.0, 792.0, 'TextLayer')
label_call = sample_label_entities.texts.first
mesh_point = first_translation_point(sample_mesh_entities)
assert_true(label_call && mesh_point, 'sample label and 3D text should both place')
if label_call && mesh_point
  label_point = label_call[:point]
  assert_near(label_point.x, mesh_point.x, 0.001,
              '3D Text should use same SketchUp X anchor as label for centered bbox text')
  assert_near(label_point.y, mesh_point.y, 0.001,
              '3D Text should use same SketchUp Y anchor as label for centered bbox text')
  label_vec = label_call[:vector]
  assert_true(label_vec && label_vec.x.abs < 0.001 && label_vec.y.abs < 0.001,
              'native Labels should use a zero leader vector')
  assert_true(label_call[:entity].display_leader == false,
              'native Labels should hide SketchUp leader lines when the API supports it')
end

rotated_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil, 140.0, 250.0, 148.0, 292.0,
  nil, 'text_span:1:1'
)
rotated_entities = DummyEntities.new
label_builder.send(:place_text, rotated_entities, rotated_item, 0.0, 0.0, 792.0, 'TextLayer')
assert_true(rotated_entities.texts.empty?,
            'leader vectors must not masquerade as rotated label glyphs')
assert_true(rotated_entities.mesh_calls.empty?,
            'rotated label-mode text should not silently become 3D text')
rotated_failure = label_builder.text_delivery_failures.last
assert_true(rotated_failure &&
            rotated_failure[:reason] == 'label_rotation_unsupported_by_host',
            'rotated Labels must record the honest host limitation')
assert_true(rotated_failure && rotated_failure[:transition_proof] &&
            rotated_failure[:transition_proof][:to_mode] == :text3d,
            'rotated Labels may move only to the adjacent 3D Text rung')

rotated_mesh_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil, 140.0, 250.0, 148.0, 292.0,
  nil, 'text_span:1:2'
)
rotated_mesh_entities = DummyEntities.new
mesh_builder.send(:place_text, rotated_mesh_entities, rotated_mesh_item, 0.0, 0.0, 792.0, 'TextLayer')
assert_true(rotated_mesh_entities.mesh_calls.length == 1,
            'rotated 3D text mode should add one mesh')
assert_true(rotated_mesh_entities.texts.empty?,
            '3D text mode should not fall back to a native label')
rotated_mesh_kinds = rotated_mesh_entities.transforms.map { |args| args.first.kind }
assert_true(rotated_mesh_kinds.count(:scaling) == 1,
            'rotated 3D text should be fitted once to the declared PDF width and height')
assert_true(rotated_mesh_kinds.count(:translation) == 1,
            'rotated 3D text should move once to the mesh anchor')
assert_true(rotated_mesh_kinds.count(:rotation) == 1,
            'rotated 3D text should rotate once around the anchor')
assert_true(rotated_mesh_kinds == [:scaling, :translation, :rotation],
            'rotated 3D text should use only measured fit, anchor, and source rotation transforms')

# Rotated mesh uses a half-height baseline offset (add_3d_text origin), not the
# Labels 0.18*fs screen-space heuristic — lock both so a reintroduced nudge or
# shared-label anchor cannot silently return.
label_rx, label_ry, = label_builder.send(:label_insertion_pdf, rotated_mesh_item)
mesh_rx, mesh_ry, = mesh_builder.send(:mesh_text_insertion_pdf, rotated_mesh_item)
assert_true((mesh_rx - label_rx).abs > 0.5 || (mesh_ry - label_ry).abs > 0.5,
            'rotated 3D Text mesh anchor must diverge from Labels baseline heuristic')
fs = 8.0
expected_mesh = mesh_builder.send(
  :rotated_bbox_text_origin_pdf,
  rotated_mesh_item,
  140.0, 250.0, 148.0, 292.0, fs, 90.0, fs * 0.5
)
assert_near(mesh_rx, expected_mesh[0], 0.01,
            'rotated 3D Text X uses half-height mesh baseline offset')
assert_near(mesh_ry, expected_mesh[1], 0.01,
            'rotated 3D Text Y uses half-height mesh baseline offset')
assert_true(
  !File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'))
       .include?('mesh_text_post_rotation_offset'),
  'geometry_builder must not reintroduce mesh_text_post_rotation_offset'
)

unless File.exist?(PDF_TIER1_USER)
  puts "  SKIP: PRIVATE-01 PDF not found at #{PDF_TIER1_USER}"
else
  items = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor.extract(PDF_TIER1_USER, 1)
  GOLDEN_TIER1_ITEM_COUNT = 342
  assert_true(items && items.length == GOLDEN_TIER1_ITEM_COUNT,
              "PRIVATE-01 coverage guard: need #{GOLDEN_TIER1_ITEM_COUNT} text items (got #{items ? items.length : 0})")

  def find_label(items, text, bbox_x0, bbox_y0 = nil)
    items.find do |it|
      it.text.to_s.strip == text &&
        (it.bbox_x0.to_f - bbox_x0).abs < 2.0 &&
        (bbox_y0.nil? || (it.bbox_y0.to_f - bbox_y0).abs < 8.0)
    end
  end

  quan_bom = items.find { |it| it.text.to_s.strip == 'QUAN' }
  p1052 = items.select { |it| it.text.to_s.strip == 'p1052' }
               .min_by { |it| (it.bbox_y0.to_f - 684.21).abs }
  w1023 = find_label(items, 'w1023', 822.74, 760.18)
  aa_a1006 = find_label(items, 'a1006', 782.16, 297.45)
  aa_a1005 = find_label(items, 'a1005', 901.55, 296.38)

  [quan_bom, p1052, w1023, aa_a1006, aa_a1005].compact.each do |item|
    next unless item
    lpt = label_builder.send(:text_insertion_pdf, item)
    mpt = mesh_builder.send(:mesh_text_insertion_pdf, item)
    # Horizontal shop labels share anchors; rotated items may diverge by design.
    if item.angle.to_f.abs <= 0.1
      assert_near(lpt[0], mpt[0], 0.01, "#{item.text} X must match across modes")
      assert_near(lpt[1], mpt[1], 0.01, "#{item.text} Y must match across modes")
    end
    assert_near(lpt[2], mpt[2], 0.01, "#{item.text} angle must match across modes")
  end

  if quan_bom
    qx, qy, _ = label_builder.send(:text_insertion_pdf, quan_bom)
    assert_near(qx, 1948.62, PDF_TOL, "PRIVATE-01 QUAN label X (got #{qx})")
    assert_near(qy, 1656.59, PDF_TOL, "PRIVATE-01 QUAN label Y (got #{qy})")
  end

  if p1052
    px, py, _ = label_builder.send(:text_insertion_pdf, p1052)
    assert_near(px, p1052.bbox_x0.to_f, 0.05, "PRIVATE-01 p1052 label X (got #{px})")
    assert_near(py, 686.15, PDF_TOL, "PRIVATE-01 p1052 label Y (got #{py})")
  end

  if w1023
    wx, wy, wang = mesh_builder.send(:mesh_text_insertion_pdf, w1023)
    assert_near(wx, 822.74, PDF_TOL, "PRIVATE-01 connection w1023 X left-anchored (got #{wx})")
    assert_near(wy, 762.12, PDF_TOL, "PRIVATE-01 connection w1023 Y baseline (got #{wy})")
    assert_near(wang, 0.0, PDF_TOL, "PRIVATE-01 connection w1023 stays horizontal per PDF angle (got #{wang})")
    mesh_h = mesh_builder.send(:mesh_text_height_inches, w1023, wang, 792.0)
    assert_true(mesh_h < 0.12, "PRIVATE-01 connection w1023 mesh height must not blow up (got #{mesh_h})")
  end

  if aa_a1006
    ax, ay, aang = label_builder.send(:text_insertion_pdf, aa_a1006)
    mx, my, mang = mesh_builder.send(:mesh_text_insertion_pdf, aa_a1006)
    assert_near(ax, 782.16, PDF_TOL, "PRIVATE-01 SECTION A-A a1006 label X (got #{ax})")
    assert_near(ay, 299.39, PDF_TOL, "PRIVATE-01 SECTION A-A a1006 label Y (got #{ay})")
    assert_near(aang, 0.0, PDF_TOL, "PRIVATE-01 SECTION A-A a1006 label angle (got #{aang})")
    assert_near(mx, ax, 0.01, "PRIVATE-01 a1006 X must match across modes")
    assert_near(my, ay, 0.01, "PRIVATE-01 a1006 Y must match across modes")
    assert_near(mang, aang, 0.01, "PRIVATE-01 a1006 angle must match across modes")
  end

  if aa_a1005
    ax, ay, aang = label_builder.send(:text_insertion_pdf, aa_a1005)
    mx, my, mang = mesh_builder.send(:mesh_text_insertion_pdf, aa_a1005)
    assert_near(ax, 901.55, PDF_TOL, "PRIVATE-01 SECTION A-A a1005 label X (got #{ax})")
    assert_near(ay, 298.32, PDF_TOL, "PRIVATE-01 SECTION A-A a1005 label Y (got #{ay})")
    assert_near(aang, 0.0, PDF_TOL, "PRIVATE-01 SECTION A-A a1005 label angle (got #{aang})")
    assert_near(mx, ax, 0.01, "PRIVATE-01 a1005 X must match across modes")
    assert_near(my, ay, 0.01, "PRIVATE-01 a1005 Y must match across modes")
    assert_near(mang, aang, 0.01, "PRIVATE-01 a1005 angle must match across modes")
  end

  label_entities = DummyEntities.new
  mesh_entities = DummyEntities.new
  items.each do |item|
    label_builder.send(:place_text, label_entities, item, 0.0, 0.0, 792.0, 'TextLayer')
    mesh_builder.send(:place_text, mesh_entities, item, 0.0, 0.0, 792.0, 'TextLayer')
  end

  extra_placements = items.inject(0) do |acc, it|
    acc + (label_builder.send(:stacked_vertical_dimension_labels?, it) ?
             it.text.to_s.strip.split(/\s+/).length - 1 : 0)
  end
  expected_labels = items.length + extra_placements
  label_total = label_entities.texts.length
  assert_true(label_total == expected_labels,
              "Labels mode should place #{expected_labels} native annotations (got #{label_total})")
  assert_true(label_entities.mesh_calls.empty?,
              "Labels mode should not create 3D text while native labels succeed (got #{label_entities.mesh_calls.length})")
  assert_true(mesh_entities.mesh_calls.length == items.length,
              "3D Text mode should mesh every item (got #{mesh_entities.mesh_calls.length} of #{items.length})")

  coverage_ratio = mesh_entities.mesh_calls.length.to_f / items.length
  assert_true(coverage_ratio >= 0.99,
              "3D Text coverage should track external extractor (ratio #{coverage_ratio.round(3)})")

  failing_entities = DummyEntities.new
  failing_entities.fail_add_text!
  label_stop_builder = make_builder(use_3d_text: false)
  before_mesh = failing_entities.mesh_calls.length
  delivered = label_stop_builder.send(
    :place_annotation_label, failing_entities, quan_bom || quan,
    0.0, 0.0, 'TextLayer'
  )
  assert_true(!delivered,
              'Labels must stop explicitly when native add_text fails')
  assert_true(failing_entities.mesh_calls.length == before_mesh,
              'Labels failure must not create substitute 3D text')
  assert_true(!label_stop_builder.text_delivery_failures.empty?,
              'Labels failure must be reported for the exact source span')

  puts "  PRIVATE-01 PDF: labels=#{label_entities.texts.length}, mesh=#{mesh_entities.mesh_calls.length}, items=#{items.length}"
end

puts
if $failures.empty?
  puts "PASS: #{$pass_count} assertions"
  exit 0
else
  puts "FAIL: #{$failures.length} assertion(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
