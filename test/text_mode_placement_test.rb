#!/usr/bin/env ruby
# test/text_mode_placement_test.rb
# Per-mode placement checks for 1017 key labels (Labels + 3D Text).
# Golden tier regression — see text_category_placement_test.rb for pattern rules.

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require_relative '../corpus_paths'

pdf_1017 = ENV['BCS_1017_PDF'].to_s
pdf_1017 = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf('1017 - Rev 0.pdf').to_s if pdf_1017.empty?
PDF_1017 = pdf_1017
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
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0)
Z_AXIS = Geom::Vector3d.new(0, 0, 1)

class DummyTextEntity
  attr_accessor :layer, :display_leader, :vector
end

class DummyMeshEntity
  attr_accessor :layer
end

class DummyEntities
  attr_reader :texts, :mesh_calls, :entities, :transforms

  def initialize
    @texts = []
    @mesh_calls = []
    @entities = []
    @transforms = []
    @fail_text = false
  end

  def fail_add_text!
    @fail_text = true
  end

  def to_a
    @entities
  end

  def add_text(text, point, vector = nil)
    raise 'add_text forced failure' if @fail_text
    ent = DummyTextEntity.new
    @texts << { text: text, point: point, vector: vector, entity: ent }
    ent
  end

  def add_3d_text(text, align, font, bold, italic, height, tol, extrusion, filled, z)
    @mesh_calls << {
      text: text, height: height, align: align, font: font
    }
    ent = DummyMeshEntity.new
    @entities << ent
    true
  end

  def transform_entities(*args)
    @transforms << args
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
    use_3d_text: use_3d_text
  )
end

label_builder = make_builder(use_3d_text: false)
mesh_builder = make_builder(use_3d_text: true)

quan = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil, 90.0, 198.0, 130.0, 210.0
)
lx, ly, lang = label_builder.send(:text_insertion_pdf, quan)
mx, my, mang = mesh_builder.send(:text_insertion_pdf, quan)
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
  'a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil, 140.0, 250.0, 148.0, 292.0
)
rotated_entities = DummyEntities.new
label_builder.send(:place_text, rotated_entities, rotated_item, 0.0, 0.0, 792.0, 'TextLayer')
assert_true(rotated_entities.texts.length == 1,
            'rotated label-mode text should remain a native label')
assert_true(rotated_entities.mesh_calls.empty?,
            'rotated label-mode text should not silently become 3D text')
if rotated_entities.texts.first
  rotated_vec = rotated_entities.texts.first[:vector]
  assert_true(rotated_vec && rotated_vec.y.abs > 0.99,
              'rotated label-mode text should use a rotated direction vector')
  assert_true(rotated_entities.texts.first[:entity].display_leader == false,
              'rotated native labels should hide SketchUp leader lines when possible')
end

unless File.exist?(PDF_1017)
  puts "  SKIP: 1017 PDF not found at #{PDF_1017}"
else
  items = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor.extract(PDF_1017, 1)
  GOLDEN_1017_ITEM_COUNT = 342
  assert_true(items && items.length == GOLDEN_1017_ITEM_COUNT,
              "1017 coverage guard: need #{GOLDEN_1017_ITEM_COUNT} text items (got #{items ? items.length : 0})")

  def find_label(items, text, bbox_x0, bbox_y0 = nil)
    items.find do |it|
      it.text.to_s.strip == text &&
        (it.bbox_x0.to_f - bbox_x0).abs < 2.0 &&
        (bbox_y0.nil? || (it.bbox_y0.to_f - bbox_y0).abs < 8.0)
    end
  end

  quan1017 = items.find { |it| it.text.to_s.strip == 'QUAN' }
  p1052 = items.select { |it| it.text.to_s.strip == 'p1052' }
               .min_by { |it| (it.bbox_y0.to_f - 684.21).abs }
  w1023 = find_label(items, 'w1023', 822.74, 760.18)
  aa_a1006 = find_label(items, 'a1006', 782.16, 297.45)
  aa_a1005 = find_label(items, 'a1005', 901.55, 296.38)

  [quan1017, p1052, w1023, aa_a1006, aa_a1005].compact.each do |item|
    next unless item
    lpt = label_builder.send(:text_insertion_pdf, item)
    mpt = mesh_builder.send(:text_insertion_pdf, item)
    assert_near(lpt[0], mpt[0], 0.01, "#{item.text} X must match across modes")
    assert_near(lpt[1], mpt[1], 0.01, "#{item.text} Y must match across modes")
    assert_near(lpt[2], mpt[2], 0.01, "#{item.text} angle must match across modes")
  end

  if quan1017
    qx, qy, _ = label_builder.send(:text_insertion_pdf, quan1017)
    assert_near(qx, 1948.62, PDF_TOL, "1017 QUAN label X (got #{qx})")
    assert_near(qy, 1656.59, PDF_TOL, "1017 QUAN label Y (got #{qy})")
  end

  if p1052
    px, py, _ = label_builder.send(:text_insertion_pdf, p1052)
    assert_near(px, p1052.bbox_x0.to_f, 0.05, "1017 p1052 label X (got #{px})")
    assert_near(py, 686.15, PDF_TOL, "1017 p1052 label Y (got #{py})")
  end

  if w1023
    wx, wy, wang = mesh_builder.send(:text_insertion_pdf, w1023)
    assert_near(wx, 822.74, PDF_TOL, "1017 connection w1023 X left-anchored (got #{wx})")
    assert_near(wy, 762.12, PDF_TOL, "1017 connection w1023 Y baseline (got #{wy})")
    assert_near(wang, 0.0, PDF_TOL, "1017 connection w1023 stays horizontal per PDF angle (got #{wang})")
    mesh_h = mesh_builder.send(:mesh_text_height_inches, w1023, wang, 792.0)
    assert_true(mesh_h < 0.12, "1017 connection w1023 mesh height must not blow up (got #{mesh_h})")
  end

  if aa_a1006
    ax, ay, aang = label_builder.send(:text_insertion_pdf, aa_a1006)
    mx, my, mang = mesh_builder.send(:text_insertion_pdf, aa_a1006)
    assert_near(ax, 782.16, PDF_TOL, "1017 SECTION A-A a1006 label X (got #{ax})")
    assert_near(ay, 299.39, PDF_TOL, "1017 SECTION A-A a1006 label Y (got #{ay})")
    assert_near(aang, 0.0, PDF_TOL, "1017 SECTION A-A a1006 label angle (got #{aang})")
    assert_near(mx, ax, 0.01, "1017 a1006 X must match across modes")
    assert_near(my, ay, 0.01, "1017 a1006 Y must match across modes")
    assert_near(mang, aang, 0.01, "1017 a1006 angle must match across modes")
  end

  if aa_a1005
    ax, ay, aang = label_builder.send(:text_insertion_pdf, aa_a1005)
    mx, my, mang = mesh_builder.send(:text_insertion_pdf, aa_a1005)
    assert_near(ax, 901.55, PDF_TOL, "1017 SECTION A-A a1005 label X (got #{ax})")
    assert_near(ay, 298.32, PDF_TOL, "1017 SECTION A-A a1005 label Y (got #{ay})")
    assert_near(aang, 0.0, PDF_TOL, "1017 SECTION A-A a1005 label angle (got #{aang})")
    assert_near(mx, ax, 0.01, "1017 a1005 X must match across modes")
    assert_near(my, ay, 0.01, "1017 a1005 Y must match across modes")
    assert_near(mang, aang, 0.01, "1017 a1005 angle must match across modes")
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
  label_total = label_entities.texts.length + label_entities.mesh_calls.length
  assert_true(label_total == expected_labels,
              "Labels mode should place #{expected_labels} annotations/mesh labels (got #{label_total})")
  assert_true(label_entities.mesh_calls.empty?,
              "Labels mode should not create 3D text while native labels succeed (got #{label_entities.mesh_calls.length})")
  assert_true(mesh_entities.mesh_calls.length == items.length,
              "3D Text mode should mesh every item (got #{mesh_entities.mesh_calls.length} of #{items.length})")

  coverage_ratio = mesh_entities.mesh_calls.length.to_f / items.length
  assert_true(coverage_ratio >= 0.99,
              "3D Text coverage should track external extractor (ratio #{coverage_ratio.round(3)})")

  failing_entities = DummyEntities.new
  failing_entities.fail_add_text!
  mesh_fallback_builder = make_builder(use_3d_text: false)
  before_mesh = failing_entities.mesh_calls.length
  mesh_fallback_builder.send(:place_annotation_label, failing_entities, quan1017 || quan,
                             0.0, 0.0, 'TextLayer')
  assert_true(failing_entities.mesh_calls.length == before_mesh + 1,
              'Labels should fall back to mesh text only when add_text fails')

  puts "  1017 PDF: labels=#{label_entities.texts.length}, mesh=#{mesh_entities.mesh_calls.length}, items=#{items.length}"
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
