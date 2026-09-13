#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/primitives'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/arc_fitter'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/document_profiler'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/dimension_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/generic_recognizer'

GR = BlueCollarSystems::PDFVectorImporter::GenericRecognizer
Prim = BlueCollarSystems::PDFVectorImporter::Primitive
NText = BlueCollarSystems::PDFVectorImporter::NormalizedText
Cfg = BlueCollarSystems::PDFVectorImporter::RecognitionConfig

class ImportPerfAccuracyTest < Minitest::Test
  def test_dimension_association_matches_all_pairs_reference
    prims = []
    80.times do |index|
      x = (index % 10) * 2.0
      y = (index / 10) * 2.0
      prims << Prim.new(
        index + 1, :line, [[x, y], [x + 0.4, y]], nil, nil, nil, nil,
        [x, y, x + 0.4, y + 0.02], nil, nil, nil, nil, nil, false, nil, 1, nil
      )
    end
    texts = [
      NText.new(1001, '1"', '1"', [0.2, 0.01], nil, 0.1, 0.0, '', 1, [:dimension_like]),
      NText.new(1002, '2"', '2"', [10.2, 6.01], nil, 0.1, 0.0, '', 1, [:dimension_like]),
      NText.new(1003, '9"', '9"', [40.0, 40.0], nil, 0.1, 0.0, '', 1, [:dimension_like])
    ]
    config = Cfg.default
    radius = config.dimension_assoc_radius
    expected = texts.map do |txt|
      nearest = nil
      nearest_dist = radius
      prims.each do |p|
        next unless p.bbox
        pcx = (p.bbox[0] + p.bbox[2]) / 2.0
        pcy = (p.bbox[1] + p.bbox[3]) / 2.0
        d = Math.sqrt((txt.insertion[0] - pcx)**2 + (txt.insertion[1] - pcy)**2)
        if d < nearest_dist
          nearest = p
          nearest_dist = d
        end
      end
      nearest && nearest.id
    end

    actual = GR.send(:associate_dimensions, texts, prims, config)
    assert_equal expected, actual.map { |row| row[:nearest_prim_id] }
    assert_nil actual.last[:nearest_prim_id]
  end

  def test_dense_circle_keeps_recognition_and_profile
    points = (0..200).map { |i| [10 + 5 * Math.cos(i * Math::PI * 2 / 200), 10 + 5 * Math.sin(i * Math::PI * 2 / 200)] }
    primitive = Prim.new
    primitive.id = 1
    primitive.type = :closed_loop
    primitive.closed = true
    primitive.points = points
    primitive.bbox = [5, 5, 15, 15]
    result = GR.send(:detect_circles, [primitive], Cfg.default)
    assert_equal 1, result.length
    assert_in_delta 5, result.first[:radius], 1e-9
    page = Struct.new(:primitives, :text_items, :width, :height, :layers, :page_number).new([primitive], [], 100, 100, [], 1)
    profile = BlueCollarSystems::PDFVectorImporter::DocumentProfiler.profile(page)
    assert_equal 1, profile.circle_count
    assert_equal points, primitive.points
  end
end
