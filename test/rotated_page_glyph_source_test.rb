#!/usr/bin/env ruby
# Glyph outlines from a /Rotate page land in unrotated PDF space.
#
# pdftocairo draws a rotated page as DISPLAYED. Since v3.7.153 the text spans
# come back to unrotated PDF space, and the page transform that places every
# outline group rotates once, after construction. model_space_loops still
# returned displayed coordinates, so on a /Rotate 90 sheet:
#   - match_spans bound almost no span (pens and spans in different spaces),
#   - glyphs past the unrotated page width were clipped away as off-page,
#   - any outline that was built would be rotated a second time.
# All PDFs, SVGs and words here are made up.

require 'minitest/autorun'
require 'tmpdir'

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      if x.is_a?(Array)
        @x, @y, @z = x[0].to_f, x[1].to_f, (x[2] || 0.0).to_f
      else
        @x, @y, @z = x.to_f, y.to_f, z.to_f
      end
    end
    def to_a; [@x, @y, @z]; end
    def [](index); to_a[index]; end
    def transform(_t); self; end
    def distance(o); Math.sqrt((x - o.x)**2 + (y - o.y)**2 + (z - o.z.to_f)**2); end
  end
  class Vector3d < Point3d; end
end unless defined?(Geom::Point3d)

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'
require_relative 'support/synthetic_pdf_builder'

class RotatedPageGlyphSourceTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  CGS = IMP::CairoGlyphSource
  PT = IMP::PageTransform
  MEDIA = [0.0, 0.0, 612.0, 792.0].freeze
  Span = Struct.new(:text, :font_name, :source_span_id, :bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1, :angle)

  # Made-up runs in unrotated PDF points: [text, x of first pen, baseline y].
  RUNS = [['EX207', 72.0, 700.0], ['D42', 300.0, 400.0], ['MXT', 540.0, 100.0], ['A1', 40.0, 60.0]].freeze
  ADVANCE = 9.0

  # A cairo-like SVG of the page as displayed: one square glyph per letter,
  # the page rotation baked into the pen positions.
  def displayed_svg(rotation)
    width = PT.effective_width(MEDIA, rotation)
    height = PT.effective_height(MEDIA, rotation)
    uses = []
    RUNS.each do |text, x, y|
      text.length.times do |index|
        dx, dy = PT.transform_point(x + index * ADVANCE, y, MEDIA, rotation)
        uses << %(<use xlink:href="#glyph-0-0" x="#{dx}" y="#{height - dy}"/>)
      end
    end
    %(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ) +
      %(width="#{width}pt" height="#{height}pt" viewBox="0 0 #{width} #{height}">\n) +
      %(<defs><g><g id="glyph-0-0"><path d="M 1 -2 L 7 -2 L 7 -8 L 1 -8 Z"/></g></g></defs>\n) +
      %(<g fill="rgb(0%, 0%, 0%)" fill-opacity="1">\n#{uses.join("\n")}\n</g>\n</svg>\n)
  end

  def spans
    RUNS.each_with_index.map do |(text, x, y), index|
      Span.new(text, 'pdftotext', "text_span:1:#{index}", x - 1.0, y - 3.0,
               x + text.length * ADVANCE + 1.0, y + 10.0, 0.0)
    end
  end

  def options(rotation)
    { :scale => 1.0, :svg_page_box => MEDIA, :y_offset => 0.0,
      :cache_model_space_loops => false, :page_rotation => rotation }
  end

  def test_rotated_pens_and_ink_return_to_unrotated_space_and_bind_every_span
    [90, 180, 270].each do |rotation|
      svg = displayed_svg(rotation)
      placed = CGS.model_space_loops(svg, MEDIA, options(rotation))
      assert_equal 13, placed.length, "rotation #{rotation}: no glyph may be clipped away"
      expected_pens = RUNS.flat_map { |text, x, y| Array.new(text.length) { |i| [x + i * ADVANCE, y] } }
      placed.zip(expected_pens).each do |entry, pen|
        assert_in_delta pen[0], entry[:pen_pdf][0], 1.0e-9, "rotation #{rotation} pen x"
        assert_in_delta pen[1], entry[:pen_pdf][1], 1.0e-9, "rotation #{rotation} pen y"
        # The glyph square is 6 x 6 pt, 2..8 pt above its pen in unrotated space.
        box = entry[:ink_bbox_pdf]
        assert_in_delta 6.0, box[2] - box[0], 1.0e-9
        assert_in_delta 6.0, box[3] - box[1], 1.0e-9
      end
      binding = CGS.verify_model_loop_bindings(svg, MEDIA, placed, options(rotation))
      assert binding[:ok], "rotation #{rotation}: #{binding[:failures].first.inspect}"
      pens = placed.map { |entry| CGS.placement_pen_record(entry) }
      match = CGS.match_spans(pens, spans, MEDIA)
      assert_equal 4, match[:runs_matched], "rotation #{rotation}"
      assert_equal 0, match[:runs_unmatched]
    end
  end

  def test_the_rotated_page_without_the_rotation_option_is_what_main_did
    svg = displayed_svg(90)
    placed = CGS.model_space_loops(svg, MEDIA, options(nil))
    assert_operator placed.length, :<, 13, 'displayed points past x=612 were clipped away'
    match = CGS.match_spans(placed.map { |e| CGS.placement_pen_record(e) }, spans, MEDIA)
    assert_operator match[:runs_matched], :<, 4
  end

  def test_an_unrotated_page_is_bit_identical_with_or_without_the_option
    svg = displayed_svg(0)
    plain = CGS.model_space_loops(svg, MEDIA, options(nil))
    zero = CGS.model_space_loops(svg, MEDIA, options(0))
    flatten = lambda do |entries|
      entries.map do |entry|
        entry.reject { |key, _| key == :loops }.merge(
          :loops => entry[:loops].map { |loop| loop.map(&:to_a) })
      end
    end
    assert_equal Marshal.dump(flatten.call(plain)), Marshal.dump(flatten.call(zero))
    assert_equal Marshal.dump(CGS.pen_placements_pdf(svg, MEDIA, options(nil))),
                 Marshal.dump(CGS.pen_placements_pdf(svg, MEDIA, options(0)))
  end

  def test_cached_glyph_instances_rebuild_the_unrotated_outline
    [90, 180, 270].each do |rotation|
      CGS.model_space_loops(displayed_svg(rotation), MEDIA, options(rotation)).each do |entry|
        m = entry[:cache_instance_transformation]
        refute_nil m
        entry[:cache_definition_loops].zip(entry[:loops]).each do |definition, loop|
          definition.zip(loop).each do |local, world|
            assert_in_delta world.x, m[0] * local.x + m[4] * local.y + m[12], 1.0e-9
            assert_in_delta world.y, m[1] * local.x + m[5] * local.y + m[13], 1.0e-9
          end
        end
      end
    end
  end

  def test_paint_order_glyphs_use_the_same_unrotated_space
    [90, 270].each do |rotation|
      svg = displayed_svg(rotation)
      placed = CGS.model_space_loops(svg, MEDIA, options(rotation))
      inventory = IMP::SvgPaintOrder.build(svg, MEDIA, :scale => 1.0, :svg_page_box => MEDIA,
                                           :y_offset => 0.0, :page_rotation => rotation)
      by_index = {}
      inventory[:glyphs].each { |glyph| by_index[glyph[:placement_index]] = glyph }
      placed.each do |entry|
        glyph = by_index.fetch(entry[:placement_index])
        glyph[:ink_bbox_pdf].zip(entry[:ink_bbox_pdf]).each do |a, b|
          assert_in_delta b, a, 1.0e-9
        end
      end
    end
  end

  # Real pdftocairo/pdftotext on a made-up PDF, when the helpers are here.
  def made_up_pdf(path, rotation)
    stream = "BT /F1 18 Tf 72 700 Td (EX207 TEST) Tj ET\nBT /F1 12 Tf 300 400 Td (D42-100 SAMPLE) Tj ET\n" \
             "BT /F1 10 Tf 500 100 Td (MXT-100) Tj ET\nBT /F1 14 Tf 40 60 Td (EDGE A1) Tj ET\n"
    SyntheticPdfBuilder.write(path, [
      '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate #{rotation} " \
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
      SyntheticPdfBuilder.stream_object('', stream),
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'])
  end

  def test_real_rotated_pages_match_every_span_and_land_on_it_after_one_page_rotation
    unless IMP::SvgTextRenderer.find_svg_renderer && IMP::DependencyResolver.find_pdftotext
      skip 'pdftocairo/pdftotext are not available here'
    end
    counts = {}
    Dir.mktmpdir('bc_rotated_glyphs') do |dir|
      [0, 90, 180, 270].each do |rotation|
        pdf = File.join(dir, "made_up_#{rotation}.pdf")
        made_up_pdf(pdf, rotation)
        parser = IMP::PDFParser.new(pdf)
        parser.parse
        raw = parser.page_data(1)
        media = raw[:media_box]
        page_rotation = PT.normalize_rotation(raw[:rotation])
        assert_equal rotation, page_rotation
        document = CGS.render_page_svg(pdf, 1, :failure_info => {})
        refute_nil document
        items = IMP.extract_external_page_text(pdf, 1, raw[:content_streams], 0, 0, false,
                                               nil, media, page_rotation)
        IMP::TextSourceIdentity.assign!(items, 1)
        assert_equal 4, items.length
        opts = { :scale => 1.0, :svg_page_box => media, :y_offset => 0.0,
                 :cache_model_space_loops => false, :page_rotation => page_rotation }
        placed = CGS.model_space_loops(document[:svg], media, opts)
        assert CGS.verify_model_loop_bindings(document[:svg], media, placed, opts)[:ok]
        match = CGS.match_spans(placed.map { |e| CGS.placement_pen_record(e) }, items, media)
        assert_equal 4, match[:runs_matched], "rotation #{rotation}"
        counts[rotation] = placed.length
        by_index = {}
        placed.each { |entry| by_index[entry[:placement_index]] = entry }
        items.each do |item|
          sid = IMP::RepresentationFidelity.source_span_id(item)
          indices = match[:placement_matches].select { |r| r[:source_span_id].to_s == sid }
          refute_empty indices
          points = indices.flat_map { |r| by_index[r[:placement_index]][:ink_points_pdf] }
          shown = points.map { |x, y| PT.transform_point(x + media[0], y + media[1], media, page_rotation) }
          box = CGS.item_bbox_media_relative(item, media[0], media[1])
          span = PT.transform_bbox(box[0] + media[0], box[1] + media[1], box[2] + media[0],
                                   box[3] + media[1], media, page_rotation)
          xs = shown.map(&:first)
          ys = shown.map(&:last)
          outside = [span[0] - xs.min, span[1] - ys.min, xs.max - span[2], ys.max - span[3]].max
          assert_operator outside, :<=, 2.0, "rotation #{rotation}: glyphs must land on their span"
        end
      end
    end
    assert_equal [counts[0]], counts.values.uniq, 'every rotation keeps every glyph'
  ensure
    IMP::SvgTextRenderer.release_embedded_font_copies!
  end
end
