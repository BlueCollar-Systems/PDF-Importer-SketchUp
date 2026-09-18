require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/dependency_resolver'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_salvage'

class PdfNavigationLinkAppearanceTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  PS = IMP::PdfSalvage

  def fixture(path, annotations, extra_update = false)
    stream = '0 0 0 RG 20 20 m 180 20 l S'
    appearance = '0 1 0 RG 2 w 0 10 m 30 10 l S'
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R /Annots [' +
        annotations.each_index.map { |i| (i+6).to_s + ' 0 R' }.join(' ') + '] >>',
      '<< /Length '+stream.bytesize.to_s+" >>\nstream\n"+stream+"\nendstream",
      '<< /Type /XObject /Subtype /Form /BBox [0 0 30 20] /Resources << >> /Length '+appearance.bytesize.to_s+" >>\nstream\n"+appearance+"\nendstream"] + annotations
    data="%PDF-1.4\n".dup; offsets=[0]
    objects.each_with_index do |object,index|
      offsets << data.bytesize
      data << (index+1).to_s+" 0 obj\n"+object+"\nendobj\n"
    end
    xref=data.bytesize
    data << "xref\n0 "+(objects.length+1).to_s+"\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| data << format('%010d 00000 n ',offset)+"\n" }
    data << 'trailer << /Size '+(objects.length+1).to_s+' /Root 1 0 R >>'+"\nstartxref\n"+xref.to_s+"\n%%EOF\n"
    if extra_update
      object_position=data.bytesize
      data << "1 0 obj\n"+objects[0]+"\nendobj\n"
      current=data.bytesize
      data << "xref\n1 1\n"+format('%010d 00000 n ',object_position)+"\ntrailer << /Size "+(objects.length+1).to_s+' /Root 1 0 R /Prev '+xref.to_s+" >>\nstartxref\n"+current.to_s+"\n%%EOF\n"
    end
    File.binwrite(path,data)
    path
  end

  def link(extra='')
    '<< /Type /Annot /Subtype /Link /Rect [20 120 80 150] /A << /S /URI /URI (https://example.invalid/) >> '+extra+' >>'
  end

  def parser(path)
    result=IMP::PDFParser.new(path); result.parse; result
  end

  def xref_stream_fixture(path, annotations)
    fixture(path,annotations)
    data=File.binread(path).split("\nxref\n",2).first+"\n"
    data.sub!('%PDF-1.4','%PDF-1.5')
    number=annotations.length+6
    position=data.bytesize
    rows=[[0,0,65535]]
    (1...number).each { |i| rows << [1,data.index(i.to_s+" 0 obj\n"),0] }
    rows << [1,position,0]
    stream=rows.map { |row| row.pack('CNn') }.join
    data << number.to_s+" 0 obj\n<< /Type /XRef /Root 1 0 R /Size "+(number+1).to_s+
      ' /W [1 4 2] /Length '+stream.bytesize.to_s+" >>\nstream\n"+stream+
      "\nendstream\nendobj\nstartxref\n"+position.to_s+"\n%%EOF\n"
    File.binwrite(path,data)
    path
  end

  def test_navigation_metadata_and_zero_borders_do_not_require_normalization
    Dir.mktmpdir('navigation_links') do |dir|
      source=fixture(File.join(dir,'source.pdf'),[link,link('/Border [0 0 0]'),link('/BS << /W 0 >> /Border [0 0 2]'),link('/H /N /NM (navigation)'),link('/AP null /Border null /BS null /C null')])
      p=parser(source)
      assert p.page_has_annotations?(1)
      refute p.page_has_annotation_appearances?(1)
      before=File.binread(source)
      IMP::DependencyResolver.stub(:find_ghostscript,nil) do
        assert_equal [source,nil],PS.send(:prepare_uncached,source)
      end
      assert_equal before,File.binread(source)
    end
  end

  def test_authored_link_appearances_and_explicit_styles_are_never_dropped
    p=IMP::PDFParser.new('unused')
    [link('/AP << /N 5 0 R >>'),link('/AP << >>'),link('/Border [0 0 2]'),
     link('/BS << /W 2 >>'),link('/BS << >>'),link('/C [1 0 0]'),link('/MK << >>')].each do |raw|
      refute p.navigation_only_link?(raw),raw
    end
    refute p.navigation_only_link?('<< /Type /Annot /Subtype /Line /Rect [20 30 80 50] >>')
    assert_raises(RuntimeError) { p.navigation_only_link?(link('/BS 999 0 R')) }
    assert_raises(RuntimeError) { p.navigation_only_link?(link('/Border [0 0 bad]')) }
    assert_raises(RuntimeError) { p.navigation_only_link?('999 0 R') }
  end

  def test_incremental_copy_keeps_visible_annotations_content_and_original_bytes
    Dir.mktmpdir('navigation_links') do |dir|
      source=fixture(File.join(dir,'source.pdf'),[link,link('/AP << /N 5 0 R >> /A << /S /URI /URI (https://example.invalid/) /IsMap false /Next null >> /BCFixture true'),
        '<< /Type /Annot /Subtype /Line /Rect [100 90 130 110] /AP << /N 5 0 R >> >>'],true)
      p=parser(source); before=File.binread(source); expected=p.page_data(1)
      copy=File.join(dir,'prepared.pdf')
      assert p.write_annotation_appearance_copy(copy)
      assert_equal before,File.binread(source)
      assert File.binread(copy).start_with?(before)
      q=parser(copy)
      assert_equal expected,q.page_data(1)
      assert_equal ['9 0 R','8 0 R'],q.page_annotation_entries(1)
      assert q.page_has_annotation_appearances?(1)
      assert_equal p.resolve_object('7 0 R'),q.resolve_object('7 0 R')
      adjusted=q.send(:to_dict,q.resolve_object('9 0 R')).dup
      assert_equal ['0','0','0'],adjusted.delete('/Border')
      assert_equal p.send(:to_dict,p.resolve_object('7 0 R')),adjusted
      assert_equal p.resolve_object('8 0 R'),q.resolve_object('8 0 R')
      refute q.write_annotation_appearance_copy(File.join(dir,'unneeded.pdf'))
      refute File.exist?(File.join(dir,'unneeded.pdf'))
      assert_raises(RuntimeError) { p.write_annotation_appearance_copy(source) }
      assert_raises(RuntimeError) { p.write_annotation_appearance_copy(copy) }
      assert_equal before,File.binread(source)
    end
  end

  def test_real_writer_does_not_synthesize_navigation_border_in_mixed_markup
    if ENV['BC_TEST_REQUIRE_BUNDLED_GS'] == '1'
      executable=IMP::DependencyResolver.bundled_ghostscript_executable
      refute_nil executable,'Required bundled Ghostscript must resolve; no skip or system fallback'
      assert_equal executable,IMP::DependencyResolver.find_ghostscript
    else
      skip 'Bundled/system Ghostscript unavailable' unless IMP::DependencyResolver.find_ghostscript
    end
    Dir.mktmpdir('navigation_links') do |dir|
      source=fixture(File.join(dir,'source.pdf'),[link,link('/AP << /N 5 0 R >>'),
        '<< /Type /Annot /Subtype /Line /Rect [100 90 130 110] /AP << /N 5 0 R >> >>',
        '<< /Type /Annot /Subtype /Link /Rect [100 120 160 150] /Border [0 0 2] /C [0 0 1] >>',
        '<< /Type /Annot /Subtype /Link /Rect [100 160 160 190] /AP << /N << /On 5 0 R >> >> /AS /On >>',
        '<< /Type /Annot /Subtype /Link /Rect [20 50 80 80] /BS << /W 2 >> /C [0 0 1] >>',
        '<< /Type /Annot /Subtype /Link /Rect [100 50 160 80] /C [1 0 0] >>'])
      before=Digest::SHA256.file(source).hexdigest
      output,note=PS.send(:prepare_uncached,source)
      p=parser(output)
      refute p.page_has_annotations?(1)
      paths=IMP::ContentStreamParser.new(p.page_data(1)[:content_streams],p,p.page_ocg_map(1),
        IMP::ContentStreamParser.page_fill_opacity_effects(p,1)).parse
      assert_equal 1,paths.count { |path| path.stroke && path.stroke_color==[0.0,0.0,0.0] },
        'Only original black line; no fabricated Link boxes: '+paths.map { |path| [path.stroke,path.fill,path.stroke_color,path.fill_color] }.inspect
      assert_equal 3,paths.count { |path| path.stroke_color==[0.0,1.0,0.0] },'Direct Link AP, selected Link AP state and Line AP preserved'
      assert_equal 2,paths.count { |path| path.stroke_color==[0.0,0.0,1.0] },'Explicit positive Border and BS preserved'
      assert_equal 1,paths.count { |path| path.stroke_color==[1.0,0.0,0.0] },'Explicit authored color preserved'
      assert_equal before,Digest::SHA256.file(source).hexdigest
      refute File.exist?(output.sub(/\.pdf\z/,'_appearance_input.pdf'))
      PS.cleanup(output)
    end
  end

  def test_xref_stream_source_preserves_streams_and_selected_appearance_state
    Dir.mktmpdir('navigation_links') do |dir|
      source=xref_stream_fixture(File.join(dir,'source.pdf'),[link,
        link('/AP << /N << /On 5 0 R >> >> /AS /On')])
      before=File.binread(source); p=parser(source)
      assert_equal 1,p.page_count
      copy=File.join(dir,'prepared.pdf')
      assert p.write_annotation_appearance_copy(copy)
      q=parser(copy)
      assert_equal 1,q.page_count
      assert File.binread(copy).start_with?(before)
      assert_equal before,File.binread(source)
      assert_equal p.page_data(1),q.page_data(1)
      assert_equal p.resolve_object('5 0 R'),q.resolve_object('5 0 R')
      assert_equal p.get_stream_data(5),q.get_stream_data(5)
      annotation=q.send(:to_dict,q.resolve_object(q.page_annotation_entries(1).first))
      assert_equal ['0','0','0'],annotation['/Border']
      assert_equal '/On',annotation['/AS']
      assert_equal p.send(:to_dict,p.resolve_object('7 0 R'))['/AP'],annotation['/AP']
    end
  end

  def test_unresolved_annotation_or_appearance_fails_before_helper
    Dir.mktmpdir('navigation_links') do |dir|
      ['999 0 R',link('/Border [0 0 bad]'),link('/AP 999 0 R'),
        link('/AP << >>'),link('/AP << /N 999 0 R >>'),
        link('/AP << /N << /On 5 0 R >> >> /AS /Missing')].each_with_index do |annotation,index|
        source=fixture(File.join(dir,'source-'+index.to_s+'.pdf'),[annotation])
        before=File.binread(source)
        IMP::DependencyResolver.stub(:find_ghostscript,'fake-gs') do
          assert_raises(PS::SalvageError) { PS.send(:prepare_uncached,source) }
        end
        assert_equal before,File.binread(source)
      end
    end
  end

  def test_failed_helper_removes_private_navigation_copy_without_touching_source
    Dir.mktmpdir('navigation_links') do |dir|
      source=fixture(File.join(dir,'source.pdf'),[link,link('/AP << /N 5 0 R >>')])
      before=File.binread(source); input=nil
      failure=lambda do |args,*_options|
        input=args.last
        assert File.file?(input)
        refute_equal source,input
        {:ok=>false,:exitstatus=>1,:stdout=>'',:stderr=>'public fixture failure'}
      end
      IMP::DependencyResolver.stub(:find_ghostscript,'fake-gs') do
        method=defined?(IMP::CommandRunner) ? :run : :fallback_run_pdftocairo
        target=defined?(IMP::CommandRunner) ? IMP::CommandRunner : PS
        target.stub(method,failure) { assert_raises(PS::SalvageError) { PS.send(:prepare_uncached,source) } }
      end
      refute File.exist?(input)
      assert_equal before,File.binread(source)
    end
  end
end
