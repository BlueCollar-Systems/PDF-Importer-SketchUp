require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

module Geom
  Point3d = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource::NumericPoint unless const_defined?(:Point3d)
end

class ItemRasterSourceBoundsTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Subject = Importer::ItemRasterSourceBounds
  Error = Importer::RepresentationFidelity::ContractError

  def item(text = 'A', sid = 'text_span:1:0', box = [20, 30, 30, 45])
    value = Importer::TextParser::TextItem.new(text, box[0], box[1], 16, 0, 'Helvetica',
      nil, *box)
    value.source_span_id = sid
    value
  end

  def evidence(source = item)
    Subject.base(source, [0, 0, 100, 100], [0, 0, 100, 100], 0, 1, 'a' * 64,
      'source_svg_unavailable')
  end

  def test_missing_svg_keeps_original_box_and_separate_unqualified_reason
    source = item
    before = Marshal.dump(source)
    result = Subject.prepare({}, [source], [0, 0, 100, 100], [0, 0, 100, 100], 0, 1, 'a' * 64)
    row = result.fetch(source.source_span_id)
    assert_equal Subject::UNQUALIFIED, row[:status]
    assert_equal 'source_svg_unavailable', row[:reason]
    assert_equal [18.5, 28.5, 31.5, 46.5], Subject.requested_box!(row, [0, 0, 100, 100], 0, 1.5)
    assert_equal [19, 29, 31, 46], Subject.requested_box!(row, [0, 0, 100, 100], 0, 1)
    assert_equal [20, 30, 30, 45], Subject.requested_box!(row, [0, 0, 100, 100], 0, 0)
    assert_equal before, Marshal.dump(source)
    assert_equal [20, 30, 30, 45], Subject.validate!(JSON.parse(JSON.generate(row)))
  end

  def test_source_union_is_independently_checked_and_tampered_ownership_rejected
    row = evidence.merge(:status => Subject::QUALIFIED, :reason => 'unique_page_source_match',
      :source_svg_sha256 => 'b' * 64, :source_placements => [
        {:placement_index => 3, :ink_box => [16, 32, 28, 48]},
        {:placement_index => 5, :ink_box => [25, 34, 33, 47]}],
      :source_ink_box => [16, 32, 33, 48])
    assert_equal [16, 30, 33, 48], Subject.validate!(row)
    assert_equal [14.5, 28.5, 34.5, 49.5], Subject.requested_box!(row, [0, 0, 100, 100], 0, 1.5)
    [lambda { |r| r[:source_placements][1][:placement_index] = 3 },
     lambda { |r| r[:source_ink_box][0] = 0 },
     lambda { |r| r[:source_placements][0][:ink_box][0] = Float::NAN },
     lambda { |r| r.delete(:source_svg_sha256) }].each do |tamper|
      copy = Marshal.load(Marshal.dump(row)); tamper.call(copy)
      assert_raises(Error) { Subject.validate!(copy) }
    end
    assert_raises(Error) { Subject.validate!(row, :source_text_sha256 => 'c' * 64) }
  end

  def test_reversed_boxes_preserve_internal_and_external_nonzero_origin_semantics
    media = [-20, 30, 80, 130]
    internal = item('A', 'text_span:1:0', [30, 60, 20, 40])
    assert_equal [20, 40, 30, 60], Subject.canonical_box(internal, media)
    external = item('A', 'text_span:1:0', [50, 30, 40, 10]); external.font_name = 'pdftotext'
    assert_equal [20, 40, 30, 60], Subject.canonical_box(external, media)
  end

  def test_cached_source_plan_is_once_per_page_but_rejects_changed_item_or_pdf_context
    Dir.mktmpdir('source-bounds-cache') do |folder|
      pdf = File.join(folder, 'fixture.pdf'); File.binwrite(pdf, 'source-one')
      source = item; opts = {}
      calls = 0
      original = Subject.method(:prepare)
      wrapper = lambda { |*args| calls += 1; original.call(*args) }
      Subject.stub(:prepare, wrapper) do
        3.times { Importer.item_raster_source_bounds!(pdf, 1, source, [], [0,0,100,100], [0,0,100,100], 0, opts, {}) }
        assert_equal 1, calls
        source.text = 'B'
        assert_equal 'source_bounds_cache_item_mismatch', Importer.item_raster_source_bounds!(pdf, 1, source, [], [0,0,100,100], [0,0,100,100], 0, opts, {})[:reason]
        source.text = 'A'; source.bbox_x0 = 19
        assert_equal 'source_bounds_cache_item_mismatch', Importer.item_raster_source_bounds!(pdf, 1, source, [], [0,0,100,100], [0,0,100,100], 0, opts, {})[:reason]
        other = File.join(folder, 'different.pdf'); File.binwrite(other, 'source-two')
        Importer.item_raster_source_bounds!(other, 1, item, [], [0,0,100,100], [0,0,100,100], 0, opts, {})
        assert_equal 2, calls
      end
    end
  end

  def test_unmatched_and_duplicate_source_span_ownership_never_expand_the_box
    source = item
    doc = {:svg => '<svg viewBox="0 0 100 100"></svg>', :render_box_used => :media_box,
      :missing_fonts=>[], :missing_language_packs=>[]}
    row = Subject.prepare(doc, [source], [0,0,100,100], [0,0,100,100], 0, 1, 'a'*64).fetch(source.source_span_id)
    assert_equal Subject::UNQUALIFIED, row[:status]
    assert_equal 'source_ink_ownership_unqualified', row[:reason]
    duplicate = Subject.prepare(doc, [source, source.dup], [0,0,100,100], [0,0,100,100], 0, 1, 'a'*64).fetch(source.source_span_id)
    assert_equal 'duplicate_source_span_identity', duplicate[:reason]
    assert_equal [20,30,30,45], Subject.validate!(duplicate)
  end

  def test_bezier_control_hull_includes_true_curve_between_flattened_samples
    points = Subject.conservative_local_points('M 0 0 C 0 100 100 100 100 0 Z')
    assert_equal 100.0, points.map { |p| p[0] }.max
    assert_equal(-100.0, points.map { |p| p[1] }.min)
    assert_nil Subject.conservative_local_points('M 0 0 A 2 3 0 0 1 5 6')
  end

  def test_equal_size_viewports_at_different_origins_are_unqualified
    source = item
    doc = {:svg=>'<svg viewBox="0 0 100 100"></svg>',:render_box_used=>:media_box}
    row = Subject.prepare(doc,[source],[0,0,100,100],[10,20,110,120],0,1,'a'*64).fetch(source.source_span_id)
    assert_equal Subject::UNQUALIFIED,row[:status]
    assert_equal 'source_svg_viewport_unqualified',row[:reason]
  end

  def test_visible_inherited_text_strokes_are_not_certified_by_fill_outline_bounds
    svg = '<svg viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path d="M 0 -10 L 10 -10 L 10 0 L 0 0 Z"/></g></defs>' \
      '<g style="stroke:rgb(0,0,0);stroke-width:20"><use xlink:href="#glyph-0-0" x="20" y="60"/></g></svg>'
    source = item('A','text_span:1:0',[20,40,30,50])
    row = Subject.prepare({:svg=>svg,:render_box_used=>:media_box,
      :missing_fonts=>[], :missing_language_packs=>[]},[source],
      [0,0,100,100],[0,0,100,100],0,1,'a'*64).fetch(source.source_span_id)
    assert_equal Subject::UNQUALIFIED,row[:status]
    assert_equal 'source_ink_ownership_unqualified',row[:reason]
    assert_equal({0=>true},Subject.stroked_placement_indices(svg))
  end

  def test_strokes_on_referenced_glyph_definition_are_not_certified_as_fill_only
    svg='<svg viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path d="M 0 -10 L 10 -10 L 10 0 L 0 0 Z" stroke="black" stroke-width="20"/></g></defs>' \
      '<use xlink:href="#glyph-0-0" x="20" y="60"/></svg>'
    source=item('A','text_span:1:0',[20,40,30,50])
    row=Subject.prepare({:svg=>svg,:render_box_used=>:media_box,:missing_fonts=>[],
      :missing_language_packs=>[]},[source],[0,0,100,100],[0,0,100,100],0,1,'a'*64).fetch(source.source_span_id)
    assert_equal Subject::UNQUALIFIED,row[:status]
    assert_equal({0=>true},Subject.stroked_placement_indices(svg))
  end

  def test_absent_or_malformed_font_resolution_evidence_never_qualifies_source_ink
    svg='<svg viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path d="M 0 -10 L 10 -10 L 10 0 L 0 0 Z"/></g></defs>' \
      '<use xlink:href="#glyph-0-0" x="20" y="60"/></svg>'
    source=item('A','text_span:1:0',[20,40,30,50])
    [{}, {:missing_fonts=>nil,:missing_language_packs=>[]},
      {:missing_fonts=>[],:missing_language_packs=>'none'}].each do |metadata|
      row=Subject.prepare(metadata.merge(:svg=>svg,:render_box_used=>:media_box),[source],
        [0,0,100,100],[0,0,100,100],0,1,'a'*64).fetch(source.source_span_id)
      assert_equal Subject::UNQUALIFIED,row[:status]
      assert_equal 'missing_source_resolution_evidence',row[:reason]
    end
  end

  def write_rotated_fixture(path)
    content = "BT /F1 16 Tf 1 0 0 1 72 660 Tm (HORIZA12) Tj ET\n" \
      "BT /F2 16 Tf 0 1 -1 0 180 450 Tm (VERTB34) Tj ET\n" \
      "BT /F1 16 Tf .866025 .5 -.5 .866025 280 400 Tm (SLANTC56) Tj ET\n"
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Count 4 /Kids [3 0 R 4 0 R 5 0 R 6 0 R] >>']
    [0,90,180,270].each do |rotation|
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [-20 30 592 822] /CropBox [0 50 572 802] /Rotate #{rotation} /Resources << /Font << /F1 8 0 R /F2 9 0 R >> >> /Contents 7 0 R >>"
    end
    objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream"
    objects << '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    objects << '<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>'
    pdf, offsets = "%PDF-1.4\n".dup, [0]
    objects.each_with_index do |object, index|
      offsets << pdf.bytesize; pdf << "#{index+1} 0 obj\n#{object}\nendobj\n"
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.length+1}\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.length+1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    File.binwrite(path, pdf)
  end

  def missing_visible_pixels(prepared, crops, roi)
    missing = 0; visible = 0
    File.open(prepared[:raw_path], 'rb') do |file|
      (roi[1]...roi[3]).each do |y|
        file.seek((y * prepared[:pixel_width] + roi[0]) * 4)
        row = file.read((roi[2]-roi[0])*4)
        (roi[0]...roi[2]).each do |x|
          next if row.getbyte((x-roi[0])*4+3) == 0
          visible += 1
          missing += 1 unless crops.any? { |cx,cy,cw,ch| x>=cx && x<cx+cw && y>=cy && y<cy+ch }
        end
      end
    end
    [missing, visible]
  end

  def test_actual_source_ink_survives_crop_union_for_all_rotations_nonzero_media_and_crop_fallback
    gs = Importer::DependencyResolver.bundled_ghostscript_executable
    cairo = Importer::SvgTextRenderer.find_svg_renderer
    if ENV['BC_TEST_REQUIRE_BUNDLED_GS'] == '1'
      refute_nil gs, 'required bundled Ghostscript must resolve'
      refute_nil cairo, 'required SVG renderer must resolve'
    else
      skip 'bundled renderer fixture unavailable' unless gs && cairo
    end
    Dir.mktmpdir('source-owned-ink') do |folder|
      pdf = File.join(folder,'rotated.pdf'); write_rotated_fixture(pdf)
      digest = Digest::SHA256.file(pdf).hexdigest
      media, cropbox = [-20,30,592,822], [0,50,572,802]
      items = Importer::ExternalTextExtractor.extract(pdf,1,:media_box=>media,
        :page_rotation=>0,:offset_x_pts=>20,:offset_y_pts=>20)
      assert_equal 8, items.length
      before_items = Marshal.dump(items)
      [0,90,180,270].each_with_index do |rotation,page_index|
        page = page_index+1; Importer::TextSourceIdentity.assign!(items,page)
        document = Importer::CairoGlyphSource.render_page_svg(pdf,page,:use_cropbox=>true)
        refute_nil document
        plan = Importer::ItemRasterPageRenderer.plan(gs,pdf,page,300,File.join(folder,"page#{page}.png"))
        run = Importer::CommandRunner.run(plan[:arguments],:timeout_s=>30,:env=>plan[:environment])
        assert Importer::ItemRasterPageRenderer.validate_result!(run,plan)
        prepared = Importer::PngCropper.prepare_rgba!(plan[:output_path],File.join(folder,"page#{page}.raw"))
        size = prepared.values_at(:pixel_width,:pixel_height)
        bounds = Subject.prepare(document,items,media,cropbox,rotation,page,digest)
        assert_equal 8,bounds.values.count { |row| row[:status]==Subject::QUALIFIED }, "rotation#{rotation}: #{bounds.values.map{|r|r[:reason]}}"
        original, corrected = [], []
        immutable = Marshal.dump(items)
        items.each_with_index do |source,index|
          original << Importer.item_raster_crop_geometry(source,media,rotation,300,1.5,size)[:pixel_crop]
          geometry = Importer.item_raster_crop_geometry(source,media,rotation,300,1.5,size,bounds.fetch(source.source_span_id))
          corrected << geometry[:pixel_crop]
          path = File.join(folder,"crop#{page}-#{index}.png")
          crop_proof = Importer::PngCropper.crop_rgba!(prepared,geometry[:pixel_crop],path)
          artifact = Importer.verify_item_raster_artifact!(path,source,page,geometry,plan[:arguments],pdf,crop_proof,digest)
          assert artifact[:source_ink_coverage_verified]
          assert Importer::ItemRasterDisplay.source_box!(JSON.parse(JSON.generate(artifact)),media,rotation)
        end
        assert_equal immutable, Marshal.dump(items)
        # Independently authored text-region bounds, never derived from a
        # candidate crop or SVG enclosure. This detects missing source pixels.
        region = Importer::PageTransform.transform_bbox(250,380,380,470,media,rotation)
        roi = [(region[0]*300/72.0).floor,(size[1]-region[3]*300/72.0).floor,
          (region[2]*300/72.0).ceil,(size[1]-region[1]*300/72.0).ceil]
        missing_before, visible = missing_visible_pixels(prepared,original,roi)
        missing_after, visible_after = missing_visible_pixels(prepared,corrected,roi)
        assert visible > 5000
        assert missing_before > 300, "fixture must expose original clipping at rotation#{rotation}"
        assert_equal visible,visible_after
        assert_equal 0,missing_after,"source ink lost at rotation#{rotation}"
        # A rejected -cropbox flag can still yield a default CropBox SVG.
        # Qualify decoded dimensions, not the command-option metadata.
        media_document = Importer::CairoGlyphSource.render_page_svg(pdf,page,:use_cropbox=>false)
        media_bounds = Subject.prepare(media_document,items,media,cropbox,rotation,page,digest)
        assert_equal 8,media_bounds.values.count { |row| row[:status]==Subject::QUALIFIED }
        view = Importer::SvgTextRenderer.parse_viewbox(media_document[:svg])
        resolved = [media,cropbox].find { |box|
          (Importer::PageTransform.effective_width(box,rotation)-view[2]).abs<1e-7 &&
          (Importer::PageTransform.effective_height(box,rotation)-view[3]).abs<1e-7 }
        assert media_bounds.values.all? { |row| row[:render_box]==resolved }
        assert_equal digest,Digest::SHA256.file(pdf).hexdigest
      end
      # The source item collection was changed only by explicit test identity
      # assignment, never by preparing bounds or creating crop geometry.
      Importer::TextSourceIdentity.assign!(items,1)
      original_items = Marshal.load(before_items)
      Importer::TextSourceIdentity.assign!(original_items,1)
      assert_equal Marshal.dump(original_items),Marshal.dump(items)
    end
  end
end
