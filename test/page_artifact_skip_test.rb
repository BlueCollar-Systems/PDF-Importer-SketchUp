#!/usr/bin/env ruby
# test/page_artifact_skip_test.rb
# Regression coverage for page-sized path filtering.

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/geometry_builder'

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def assert_false(cond, msg)
  assert_true(!cond, msg)
end

class TestPoint
  attr_reader :x, :y, :z

  def initialize(x, y, z = 0.0)
    @x = x.to_f
    @y = y.to_f
    @z = z.to_f
  end

  def distance(other)
    dx = x - other.x
    dy = y - other.y
    dz = z - other.z
    Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
  end
end

P = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
Segment = P::Segment
SubPath = P::SubPath
VectorPath = P::VectorPath

def rect_path(stroke, fill)
  points = [
    [0.0, 0.0],
    [612.0, 0.0],
    [612.0, 792.0],
    [0.0, 792.0],
    [0.0, 0.0]
  ]
  segments = [Segment.new(:move, [points[0]])]
  (0...points.length - 1).each do |i|
    segments << Segment.new(:line, [points[i], points[i + 1]])
  end
  VectorPath.new(
    [SubPath.new(segments, true)],
    stroke,
    fill,
    [0, 0, 0],
    [1, 1, 1],
    1.0,
    0,
    0,
    nil,
    [1, 0, 0, 1, 0, 0],
    nil
  )
end

builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  nil, [], [], [0, 0, 612, 792], scale_factor: 1.0
)
page_area = 612.0 * 792.0

stroked_border = rect_path(true, false)
fill_background = rect_path(false, true)
filled_and_stroked_frame = rect_path(true, true)

assert_false(
  builder.send(:discardable_page_artifact?, stroked_border, [0, 0, 612, 792], page_area),
  'stroked page border must be preserved'
)
assert_true(
  builder.send(:discardable_page_artifact?, fill_background, [0, 0, 612, 792], page_area),
  'simple fill-only page background can be skipped'
)
assert_false(
  builder.send(:discardable_page_artifact?, filled_and_stroked_frame, [0, 0, 612, 792], page_area),
  'filled-and-stroked page frame must be preserved'
)

assert_false(
  builder.send(:face_buildable?, [
    TestPoint.new(0, 0), TestPoint.new(1, 0), TestPoint.new(2, 0)
  ]),
  'collinear face candidate should be skipped before add_face'
)
assert_false(
  builder.send(:face_buildable?, [
    TestPoint.new(0, 0), TestPoint.new(0, 0), TestPoint.new(0, 0)
  ]),
  'duplicate-only face candidate should be skipped before add_face'
)
assert_true(
  builder.send(:face_buildable?, [
    TestPoint.new(0, 0), TestPoint.new(1, 0),
    TestPoint.new(1, 1), TestPoint.new(0, 1)
  ]),
  'non-degenerate face candidate should still be buildable'
)

if $failures.empty?
  puts "PASS: #{$pass_count} page artifact assertions"
  exit 0
end

puts "FAIL: #{$failures.length} assertion(s)"
$failures.each { |failure| puts "  - #{failure}" }
exit 1
