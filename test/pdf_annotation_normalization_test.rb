require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/dependency_resolver'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_salvage'

class PdfAnnotationNormalizationTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  PS = IMP::PdfSalvage

  def fixture(path, flags = 4, second_page = false, indirect = false)
    stream = '0 0 0 RG 40 50 m 240 50 l S'
    appearance = '3 w 1 0 0 RG 0 10 m 200 10 l S'
    annots = indirect ? '10 0 R' : '[6 0 R]'
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R 8 0 R] /Count 2 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Contents 4 0 R' + (second_page ? '' : ' /Annots '+annots) + ' >>',
      '<< /Length '+stream.bytesize.to_s+" >>\nstream\n"+stream+"\nendstream",
      'null',
      '<< /Type /Annot /Subtype /Line /Rect [40 200 240 220] /L [40 210 240 210] /C [1 0 0] /F '+flags.to_s+' /AP << /N 7 0 R >> >>',
      '<< /Type /XObject /Subtype /Form /BBox [0 0 200 20] /Resources << >> /Length '+appearance.bytesize.to_s+" >>\nstream\n"+appearance+"\nendstream",
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Contents 9 0 R'+(second_page ? ' /Annots '+annots : '')+' >>',
      '<< /Length '+stream.bytesize.to_s+" >>\nstream\n"+stream+"\nendstream",
      '[6 0 R]'
    ]
    data="%PDF-1.4\n".dup;offsets=[0]
    objects.each_with_index do |object,index|
      offsets << data.bytesize
      data << (index+1).to_s+" 0 obj\n"+object+"\nendobj\n"
    end
    xref=data.bytesize
    data << "xref\n0 "+(objects.length+1).to_s+"\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| data << format('%010d 00000 n ',offset)+"\n" }
    data << 'trailer << /Size '+(objects.length+1).to_s+' /Root 1 0 R >>'+"\nstartxref\n"+xref.to_s+"\n%%EOF\n"
    File.binwrite(path,data)
    path
  end

  def parser(path)
    value=IMP::PDFParser.new(path);value.parse;value
  end

  def helper_result(value, &block)
    if defined?(IMP::CommandRunner)
      IMP::CommandRunner.stub(:run,value,&block)
    else
      PS.stub(:fallback_run_pdftocairo,value,&block)
    end
  end

  def test_inventory_finds_direct_and_indirect_arrays_on_later_pages
    Dir.mktmpdir('annotation_fixture') do |dir|
      [false,true].each do |indirect|
        source=fixture(File.join(dir,'source.pdf'),4,true,indirect)
        p=parser(source)
        refute p.page_has_annotations?(1)
        assert p.page_has_annotations?(2)
        assert_equal 'page annotations',PS.send(:needs_salvage_reason,source)
      end
    end
  end

  def test_missing_helper_is_an_error_not_silent_annotation_omission
    Dir.mktmpdir('annotation_fixture') do |dir|
      source=fixture(File.join(dir,'source.pdf'))
      IMP::DependencyResolver.stub(:find_ghostscript,nil) do
        error=assert_raises(PS::SalvageError) { PS.send(:prepare_uncached,source) }
        assert_match(/bundled Ghostscript/,error.message)
      end
    end
  end

  def test_failed_helper_and_source_mutation_cannot_authorize_output
    Dir.mktmpdir('annotation_fixture') do |dir|
      source=fixture(File.join(dir,'source.pdf'))
      IMP::DependencyResolver.stub(:find_ghostscript,'fake-gs') do
        helper_result({:ok=>false,:stderr=>'fixture failure'}) do
          assert_raises(PS::SalvageError) { PS.send(:prepare_uncached,source) }
        end
        mutate=lambda do |args,*_options|
          output=args.find { |a| a.start_with?('-sOutputFile=') }.split('=',2).last
          File.binwrite(output,File.binread(source))
          File.open(source,'ab') { |f| f.write("\n% changed\n") }
          {:ok=>true,:exitstatus=>0,:stdout=>'',:stderr=>''}
        end
        helper_result(mutate) do
          error=assert_raises(PS::SalvageError) { PS.send(:prepare_uncached,source) }
          assert_match(/changed/,error.message)
        end
      end
    end
  end

  def test_annotation_timeout_scales_with_verified_pages_and_remains_bounded
    assert_equal 120, PS.send(:annotation_timeout_s, 1)
    assert_equal 120, PS.send(:annotation_timeout_s, 24)
    assert_equal 1295, PS.send(:annotation_timeout_s, 259)
    assert_equal 1800, PS.send(:annotation_timeout_s, 10_000)
    [nil, 0, -1, 2.5, '259'].each do |invalid|
      assert_raises(ArgumentError) { PS.send(:annotation_timeout_s, invalid) }
    end
  end

  def test_verified_count_controls_helper_budget_and_timeout_is_diagnosable
    Dir.mktmpdir('annotation_budget') do |dir|
      source = fixture(File.join(dir, 'source.pdf'))
      observed = []
      timed_out = lambda do |args, options = {}|
        observed << options
        output = args.find { |a| a.start_with?('-sOutputFile=') }.split('=', 2).last
        File.binwrite(output, '%PDF-incomplete fixture')
        {:ok=>false, :timed_out=>true, :exitstatus=>1, :stdout=>'', :stderr=>''}
      end
      # Use the production runner boundary so this also proves the computed
      # budget reaches the actual subprocess, not just a utility method.
      require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'
      IMP::DependencyResolver.stub(:find_ghostscript, 'fake-gs') do
        IMP::CommandRunner.stub(:run, timed_out) do
          error = assert_raises(PS::SalvageError) do
            PS.send(:normalize_annotation_appearances, source, 259)
          end
          assert_match(/1295s reached for 259 pages/, error.message)
          assert_equal 1295, observed.fetch(0).fetch(:timeout_s)
          assert_equal 'PdfAnnotationNormalization', observed.fetch(0).fetch(:context)
          assert_empty PS.temp_salvages, 'A timed-out partial PDF cannot become accepted output'
        end
      end
    end
  end

  def test_real_vector_writer_preserves_screen_visibility_and_every_page
    skip 'Bundled/system Ghostscript unavailable' unless IMP::DependencyResolver.find_ghostscript
    Dir.mktmpdir('annotation_fixture') do |dir|
      {0=>1,4=>1,2=>0,32=>0,36=>0}.each do |flags,expected|
        source=fixture(File.join(dir,'source-'+flags.to_s+'.pdf'),flags,true,true)
        before=Digest::SHA256.file(source).hexdigest
        output,note=PS.send(:prepare_uncached,source)
        refute_equal source,output
        assert_match(/annotation appearances/,note)
        p=parser(output)
        assert_equal 2,p.page_count
        2.times { |index| refute p.page_has_annotations?(index+1) }
        paths=IMP::ContentStreamParser.new(p.page_data(2)[:content_streams],p,p.page_ocg_map(2),IMP::ContentStreamParser.page_fill_opacity_effects(p,2)).parse
        red=paths.select { |path| path.stroke_color==[1.0,0.0,0.0] }
        assert_equal expected,red.length,'annotation flags '+flags.to_s
        assert_equal before,Digest::SHA256.file(source).hexdigest
        PS.cleanup(output)
      end
    end
  end
end
