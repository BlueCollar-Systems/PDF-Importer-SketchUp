#!/usr/bin/env ruby
# test/page_rotation_test.rb
# Regression coverage for rotated landscape PDF sheets.

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/page_transform'
require 'bc_pdf_vector_importer/pdf_parser'

$failures = []
$pass_count = 0

def assert_equal(expected, actual, msg)
  return $pass_count += 1 if expected == actual
  $failures << "#{msg}: expected #{expected.inspect}, got #{actual.inspect}"
end

def assert_near(actual, expected, tol, msg)
  return $pass_count += 1 if (actual.to_f - expected.to_f).abs <= tol
  $failures << "#{msg}: expected #{expected.inspect}, got #{actual.inspect}"
end

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end
end

require 'bc_pdf_vector_importer/geometry_builder'

PT = BlueCollarSystems::PDFVectorImporter::PageTransform
box = [0.0, 0.0, 1728.0, 2592.0]

assert_equal 270, PT.normalize_rotation(270), 'normalizes valid page rotation'
assert_near PT.effective_width(box, 270), 2592.0, 0.001, 'rotated page width uses source height'
assert_near PT.effective_height(box, 270), 1728.0, 0.001, 'rotated page height uses source width'
stack_h = BlueCollarSystems::PDFVectorImporter::PageTransform.effective_height(box, 270) / 72.0 * 1.2
assert_near stack_h, 28.8, 0.001, 'spread stack step uses displayed page height'

x, y = PT.transform_point(0.0, 2592.0, box, 270)
assert_near x, 0.0, 0.001, 'top-left raw point maps to displayed left'
assert_near y, 0.0, 0.001, 'top-left raw point maps to displayed bottom'

x, y = PT.transform_point(1728.0, 0.0, box, 270)
assert_near x, 2592.0, 0.001, 'bottom-right raw point maps to displayed right'
assert_near y, 1728.0, 0.001, 'bottom-right raw point maps to displayed top'

assert_near PT.transform_angle(-90.0, 270), 0.0, 0.001,
  'raw vertical text on /Rotate 270 page becomes displayed horizontal'

builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  nil, [], [], box, scale_factor: 1.0, page_rotation: 270
)
pt = builder.send(:pdf_to_su, 1728.0, 0.0, 0.0, 0.0)
assert_near pt.x, 36.0, 0.001, 'builder maps rotated width to 36 inches'
assert_near pt.y, 24.0, 0.001, 'builder maps rotated height to 24 inches'

TextStub = Struct.new(:font_name)
external = TextStub.new('pdftotext')
# pdftotext bbox coords stay in MediaBox space and are rotated into displayed space.
pt = builder.send(:text_point_to_su, external, 1728.0, 0.0, 0.0, 0.0)
assert_near pt.x, 36.0, 0.001, 'external text maps raw bottom-right x to displayed width'
assert_near pt.y, 24.0, 0.001, 'external text maps raw bottom-right y to displayed height'

sample_pdf = ENV['BCS_ROTATED_PDF'].to_s
if !sample_pdf.empty? && File.exist?(sample_pdf)
  parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(sample_pdf)
  parser.parse
  page = parser.page_data(1)
  assert_equal 270, page[:rotation], 'bound sealed drawings page 1 exposes /Rotate 270'
  assert_equal [0.0, 0.0, 1728.0, 2592.0], page[:media_box],
    'bound sealed drawings page 1 keeps raw MediaBox'
end

if $failures.empty?
  puts "page_rotation_test passed (#{$pass_count} checks)"
  exit 0
end

puts 'page_rotation_test failures:'
$failures.each { |failure| puts "  - #{failure}" }
exit 1
