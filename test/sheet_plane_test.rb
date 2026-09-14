#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'

class SheetPlaneTest < Minitest::Test
  G = BlueCollarSystems::PDFVectorImporter::GeometryBuilder

  def test_sheet_xy_keeps_bottom_edge
    assert_equal [10.0, 0.0], G.sheet_xy([10.0, 0.0])
  end

  def test_sheet_xy_keeps_true_y_when_z_is_a_small_offset
    assert_equal [10.0, 20.0], G.sheet_xy([10.0, 20.0, 0.1])
  end

  def test_sheet_xy_remaps_orthogonal_z_fence
    assert_equal [10.0, 500.0], G.sheet_xy([10.0, 0.0, 500.0])
  end
end
