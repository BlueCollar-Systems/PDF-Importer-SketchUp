require 'minitest/autorun'
require 'fileutils'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/annotation_composite_source'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'

class AnnotationCompositeSourceTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Subject = Importer::AnnotationCompositeSource

  def record
    { :original_geometry_verified=>true, :full_capsule_clip_verified=>true,
      :page_clip_polygons_pdf=>[[[0,0],[200,0],[200,200],[0,200]]],
      :start_pdf=>[30.0,40.0], :end_pdf=>[30.014,40.0], :radius_pdf=>2.0 }
  end

  def plan
    Subject.crop_plan(record,[0,0,200,200])
  end

  def scene(content, definition = '<g id="glyph-0-0"><path d="M 0 0 L 2 0 L 2 2 L 0 2 Z"/></g>')
    '<svg width="200pt" height="200pt" viewBox="0 0 200 200"><defs>' + definition + '</defs>' + content + '</svg>'
  end

  def glyph(x, y, extra = '')
    '<use xlink:href="#glyph-0-0" x="' + x.to_s + '" y="' + y.to_s + '" ' + extra + '/>'
  end

  def absence(svg)
    Subject::BackgroundGlyphInventory.new(svg).prove_absence!([plan])
  end

  def test_integer_device_lattice_has_no_semantic_bbox_fit
    actual = plan
    assert_equal 600, actual[:dpi]
    assert_equal [232,1315,268,1351], actual[:pixel_box]
    assert_equal 36, actual[:pixel_width]
    assert_equal 36, actual[:pixel_height]
    [27.84,157.8,32.16,162.12].zip(actual[:source_box_svg]).each { |a,b| assert_in_delta a,b,1.0e-12 }
    assert_in_delta 37.88, actual[:source_box_pdf][1], 1.0e-12
    assert_in_delta 42.2, actual[:source_box_pdf][3], 1.0e-12
  end

  def test_rotated_nonzero_origin_clipped_or_oversized_patch_is_not_guessed
    assert_raises(Subject::Unproven) { Subject.crop_plan(record,[0,0,200,200],90) }
    assert_raises(Subject::Unproven) { Subject.crop_plan(record,[10,0,200,200]) }
    assert_raises(Subject::Unproven) { Subject.crop_plan(record.merge(:start_pdf=>[1,1]),[0,0,200,200]) }
    assert_raises(Subject::Unproven) { Subject.crop_plan(record.merge(:radius_pdf=>500),[0,0,2000,2000]) }
    assert_raises(Subject::Unproven) { Subject.crop_plan(record.merge(:original_geometry_verified=>false),[0,0,200,200]) }
    clipped = record.merge(:page_clip_polygons_pdf=>[[[28,38],[200,38],[200,200],[28,200]]])
    assert_raises(Subject::Unproven) { Subject.crop_plan(clipped,[0,0,200,200]) }
  end

  def test_crop_command_uses_original_pdf_and_integer_origin_once
    args = Subject.crop_arguments('helper.exe','original.pdf',2,plan,'owned-crop')
    assert_equal ['helper.exe','-png','-singlefile','-f','2','-l','2','-r','600',
      '-x','232','-y','1315','-W','36','-H','36','original.pdf','owned-crop'], args
    refute_includes args, '-cropbox'
    refute_includes args, '-transp'
    assert_raises(Subject::Unproven) { Subject.crop_arguments('h','s',0,plan,'o') }
    assert_raises(Subject::Unproven) { Subject.crop_arguments('h','s',1,plan.merge(:pixel_width=>1),'o') }
  end

  def test_unused_overlapping_definition_is_not_live_paint
    proof = absence(scene(glyph(80,80)))
    assert proof[:all_crop_glyph_bounds_disjoint]
    assert_equal 1, proof[:possible_glyph_count]
    assert_equal 1, proof[:crop_count]
  end

  def test_referenced_glyph_ink_inside_crop_is_rejected
    assert_raises(Subject::Unproven) { absence(scene(glyph(30,160))) }
  end

  def test_hidden_and_clipped_glyphs_remain_conservative_possible_ink
    defs = '<g id="glyph-0-0"><path d="M0 0L2 0L2 2L0 2Z"/></g>' +
      '<clipPath id="effect-clip"><rect width="200" height="200"/></clipPath>' +
      '<mask id="effect-mask"><rect width="200" height="200"/></mask>'
    ['clip-path="url(#effect-clip)"','mask="url(#effect-mask)"',
     'opacity="0"','display="none"','visibility="hidden"'].each do |effect|
      assert_raises(Subject::Unproven) { absence(scene(glyph(30,160,effect),defs)) }
    end
    # A nonrectangular clip elsewhere cannot make an unrelated crop unprovable;
    # ignoring the clip only enlarges the possible glyph bounds.
    defs = '<g id="glyph-0-0"><path d="M0 0L2 0L2 2L0 2Z"/></g>' +
      '<clipPath id="curved"><path d="M0 0C20 10 5 20 0 0Z"/></clipPath>'
    assert absence(scene(glyph(80,80,'clip-path="url(#curved)"'),defs))[:all_crop_glyph_bounds_disjoint]
  end

  def test_reference_transforms_are_applied_once_before_absence_check
    use = '<g transform="translate(20,150)">' + glyph(10,10) + '</g>'
    assert_raises(Subject::Unproven) { absence(scene(use)) }
    definition = '<g id="source-a" transform="translate(20,150)">' + glyph(10,10) + '</g>' +
      '<g id="glyph-0-0"><path d="M0 0L2 0L2 2L0 2Z"/></g>'
    assert_raises(Subject::Unproven) { absence(scene('<use xlink:href="#source-a"/>',definition)) }
  end

  def test_filters_css_unknown_text_and_reference_cycles_fail_closed
    assert_raises(Subject::Unproven) { absence(scene(glyph(80,80,'filter="url(#blur)"'))) }
    assert_raises(Subject::Unproven) { absence(scene(glyph(80,80,'class="move"'))) }
    assert_raises(Subject::Unproven) { absence(scene('<text x="30" y="160">A</text>')) }
    defs = '<g id="loop"><use xlink:href="#loop"/></g>'
    assert_raises(Subject::Unproven) { absence(scene('<use xlink:href="#loop"/>',defs)) }
  end

  def test_possible_flattened_text_image_cannot_be_used_as_no_text_proof
    assert_raises(Subject::Unproven) do
      absence(scene('<image x="29" y="159" width="5" height="5" xlink:href="data:image/png;base64,AA=="/>'))
    end
    proof = absence(scene('<image x="80" y="80" width="5" height="5" xlink:href="data:image/png;base64,AA=="/>'))
    assert_equal 1,proof[:possible_flattened_text_image_count]
    assert_equal true,proof[:flattened_image_bounds_disjoint]
    assert_raises(Subject::Unproven) do
      absence(scene('<image x="80" y="80" width="5" height="5" preserveAspectRatio="xMidYMid slice" overflow="visible" xlink:href="data:image/png;base64,AA=="/>'))
    end
  end

  def test_unhandled_css_transform_and_nested_viewport_cannot_move_glyphs_silently
    assert_raises(Subject::Unproven) { absence(scene(glyph(80,80,'style="translate: -50px 80px"'))) }
    assert_raises(Subject::Unproven) { absence(scene('<svg x="-50" y="80">' + glyph(80,80) + '</svg>')) }
    defs = '<symbol id="glyph-0-0" viewBox="0 0 5 5"><path d="M0 0L2 0L2 2Z"/></symbol>'
    assert_raises(Subject::Unproven) { absence(scene(glyph(80,80),defs)) }
  end

  def test_curve_control_hull_is_conservative_not_bbox_of_endpoints
    defs = '<g id="glyph-0-0"><path d="M0 0 C30 160 32 162 0 0 Z"/></g>'
    assert_raises(Subject::Unproven) { absence(scene(glyph(0,0),defs)) }
  end

  def test_glyph_used_only_as_mask_or_clip_cannot_be_misclassified_as_absent_text
    ['mask','clipPath'].each do |kind|
      defs = '<g id="glyph-0-0"><path d="M0 0L2 0L2 2L0 2Z"/></g>' +
        '<' + kind + ' id="text-effect">' + glyph(30,160) + '</' + kind + '>'
      attr = kind == 'mask' ? 'mask' : 'clip-path'
      content = '<rect x="0" y="0" width="200" height="200" ' + attr + '="url(#text-effect)"/>'
      assert_raises(Subject::Unproven) { absence(scene(content,defs)) }
    end
  end

  def minimal_pdf
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>',
      "<< /Length 19 >>\nstream\n10 10 m 20 20 l S\nendstream",
      '<< /Type /Annot /Subtype /Ink /Rect [10 10 20 20] /F 4 >>'
    ]
    result = "%PDF-1.4\n".dup
    offsets = [0]
    objects.each_with_index do |body,index|
      offsets << result.bytesize
      result << (index+1).to_s + " 0 obj\n" + body + "\nendobj\n"
    end
    xref = result.bytesize
    result << "xref\n0 6\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| result << format('%010d 00000 n ',offset) + "\n" }
    result << "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + xref.to_s + "\n%%EOF\n"
  end

  def with_original
    dir = Importer::SafeTemp.mktmpdir('annotation-source-test-')
    source = File.join(dir,'original.pdf')
    File.binwrite(source,minimal_pdf)
    parser = Importer::PDFParser.new(source)
    parser.parse
    yield dir, source, parser, Digest::SHA256.file(source).hexdigest
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  def test_incremental_background_copy_preserves_original_bytes_and_all_nonannotation_page_data
    with_original do |dir,source,parser,sha|
      before = File.binread(source)
      original_page = parser.page_data(1)
      copy = File.join(dir,'background.pdf')
      proof = Subject.write_background_copy!(parser,sha,1,copy)
      assert_equal before, File.binread(copy,before.bytesize)
      assert_equal sha, Digest::SHA256.file(source).hexdigest
      assert_equal '/Annots', proof[:overridden_key]
      assert_equal Digest::SHA256.file(copy).hexdigest, proof[:copy_sha256]
      background = Importer::PDFParser.new(copy)
      background.parse
      assert_empty background.page_annotation_entries(1)
      assert_equal ['5 0 R'], parser.page_annotation_entries(1)
      assert_equal original_page, background.page_data(1)
    end
  end

  def test_copy_does_not_overwrite_existing_files_and_rejects_stale_source
    with_original do |dir,source,parser,sha|
      assert_raises(Errno::EEXIST) { Subject.write_background_copy!(parser,sha,1,source) }
      assert_equal sha, Digest::SHA256.file(source).hexdigest
      out = File.join(dir,'background.pdf')
      assert_raises(Subject::Unproven) { Subject.write_background_copy!(parser,'0'*64,1,out) }
      refute File.exist?(out)
      assert_raises(Subject::Unproven) { Subject.write_background_copy!(parser,sha,0,out) }
      refute File.exist?(out)
      File.binwrite(source,File.binread(source) + "% external mutation\n")
      assert_raises(Subject::Unproven) { Subject.write_background_copy!(parser,sha,1,out) }
      refute File.exist?(out)
    end
  end

  class FontScopeParser
    attr_accessor :resources,:stream
    def initialize
      @resources = {'/Font'=>{'/F1'=>{'/Subtype'=>'/TrueType'}}}
      @stream = 'BT /F1 12 Tf 0 Tr (A) Tj ET'
    end
    def pages; ['3 0 R']; end
    def resolve_object(value); value == '3 0 R' ? {'/Resources'=>@resources} : value; end
    def to_dict(value); value.is_a?(Hash) ? value : nil; end
    def find_inherited(dict,key); dict[key]; end
    def page_data(_page); {:source_content_streams=>[@stream]}; end
  end

  def test_unlabelled_type3_pattern_and_text_clip_paint_cannot_authorize_a_display_crop
    parser = FontScopeParser.new
    assert Subject.font_scope!(parser,1)[:text_clipping_modes_absent]
    parser.resources['/Font']['/F1']['/Subtype'] = '/Type3'
    assert_raises(Subject::Unproven) { Subject.font_scope!(parser,1) }
    parser = FontScopeParser.new
    parser.resources['/Pattern'] = {'/P1'=>{'/PatternType'=>'1'}}
    assert_raises(Subject::Unproven) { Subject.font_scope!(parser,1) }
    parser = FontScopeParser.new
    parser.stream = 'BT 7 Tr (clip text) Tj ET'
    assert_raises(Subject::Unproven) { Subject.font_scope!(parser,1) }
    [1,2].each do |mode|
      parser.stream = 'BT ' + mode.to_s + ' Tr (stroked source text) Tj ET'
      assert_raises(Subject::Unproven) { Subject.font_scope!(parser,1) }
    end
    parser.stream = 'BT (literal 7 Tr) Tj 0 Tr (fill) Tj ET'
    assert Subject.font_scope!(parser,1)[:text_clipping_modes_absent]
  end
end
