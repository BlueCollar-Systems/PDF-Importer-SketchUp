require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/item_raster_page_renderer'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/dependency_resolver'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/png_cropper'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/page_transform'

class ItemRasterPageRendererTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::ItemRasterPageRenderer
  ContractError = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError

  def test_exact_command_binds_original_media_page_rgba_and_dpi
    args = Subject.arguments('gs', '/source with spaces.pdf', 3, 144, '/page image.png')
    assert Subject.verify_command!(args, '/source with spaces.pdf', 3, 144)
    assert_includes args, '-sDEVICE=pngalpha'
    assert_includes args, '-dSAFER'
    assert_includes args, '-dPDFSTOPONWARNING'
    assert_includes args, '-dPDFNOCIDFALLBACK'
    refute_includes args, '-dQUIET'
    assert_equal ['-f', '/source with spaces.pdf'], args.last(2)
    refute args.any? { |arg| arg.include?('UseCropBox') || arg.include?('FitPage') }
    assert_equal 'ghostscript_transparent_page_crop', Subject::RENDERER
  end

  def test_command_binding_rejects_changed_source_page_dpi_or_extra_interpretation_options
    args = Subject.arguments('gs', '/source.pdf', 3, 144, '/page.png')
    [['-dFirstPage=3', '-dFirstPage=2'], ['-dLastPage=3', '-dLastPage=4'],
     ['-r144', '-r72'], ['-sDEVICE=pngalpha', '-sDEVICE=png16m'],
     ['/source.pdf', '/different.pdf']].each do |old, replacement|
      assert_raises(ContractError) do
        Subject.verify_command!(args.map { |arg| arg == old ? replacement : arg }, '/source.pdf', 3, 144)
      end
    end
    ['-dUseCropBox', '-dPDFFitPage', '-c', '-g100x100', '-dAutoRotatePages=/All'].each do |extra|
      assert_raises(ContractError) { Subject.verify_command!(args + [extra], '/source.pdf', 3, 144) }
    end
  end

  def test_missing_helper_is_a_failure_without_switching_renderer
    assert_raises(ContractError) { Subject.plan(nil, '/source.pdf', 1, 150, '/page.png') }
    assert_raises(ContractError) { Subject.arguments('gs', '/source.pdf', 0, 150, '/page.png') }
    assert_raises(ContractError) { Subject.arguments('gs', '/source.pdf', 1, 0, '/page.png') }
  end

  def test_process_and_diagnostic_checks_are_required_even_with_an_artifact
    Dir.mktmpdir('item-page-renderer') do |folder|
      executable, png = File.join(folder, 'helper.exe'), File.join(folder, 'page.png')
      File.binwrite(executable, 'fixture executable')
      File.binwrite(png, 'fixture artifact; PNG decoding is a separate production gate')
      plan = Subject.plan(executable, '/source.pdf', 1, 150, png)
      assert_equal Digest::SHA256.file(executable).hexdigest, plan[:executable_sha256]
      assert_equal :ghostscript, plan[:engine]
      ok = { :ok => true, :exitstatus => 0, :timed_out => false, :stdout => '', :stderr => '' }
      assert Subject.validate_result!(ok, plan)
      standard = 'Loading font Helvetica (or substitute) from %rom%Resource/Font/NimbusSans-Regular'
      assert Subject.validate_result!(ok.merge(:stdout => standard), plan)
      [{ :ok => false }, { :exitstatus => 1 }, { :timed_out => true },
       { :error => 'could not start' }, { :stderr => 'Warning: damaged PDF repaired' },
       { :stdout => 'Substituting font for MissingFont' },
       { :stdout => standard.sub('Helvetica', 'MissingFont') },
       { :stdout => standard.sub('NimbusSans-Regular', 'NimbusRoman-Regular') },
       { :stdout => standard.sub('%rom%', 'C:/unverified/') }].each do |failure|
        assert_raises(ContractError) { Subject.validate_result!(ok.merge(failure), plan) }
      end
      File.delete(png)
      assert_raises(ContractError) { Subject.validate_result!(ok, plan) }
    end
  end

  def test_real_rgba_render_preserves_media_canvas_origin_rotation_and_declared_crop_clip
    importer = BlueCollarSystems::PDFVectorImporter
    executable = importer::DependencyResolver.find_ghostscript
    skip 'Ghostscript runtime unavailable for native PNG fixture' unless executable
    Dir.mktmpdir('rgba-page-fixture') do |folder|
      source = File.join(folder, 'source.pdf')
      content = "1 0 0 rg -15 35 10 10 re f\n0 1 0 rg 165 35 10 10 re f\n" \
                "0 0 1 rg -15 115 10 10 re f\n1 1 0 rg 165 115 10 10 re f\n" \
                "1 0 0 rg 5 45 10 10 re f\n0 1 0 rg 145 45 10 10 re f\n" \
                "0 0 1 rg 5 105 10 10 re f\n1 1 0 rg 145 105 10 10 re f\n"
      objects = ['<< /Type /Catalog /Pages 2 0 R >>',
                 '<< /Type /Pages /Count 4 /Kids [3 0 R 4 0 R 5 0 R 6 0 R] >>']
      [0, 90, 180, 270].each do |rotation|
        objects << "<< /Type /Page /Parent 2 0 R /MediaBox [-20 30 180 130] " \
                   "/CropBox [0 40 160 120] /Rotate #{rotation} /Resources << >> /Contents 7 0 R >>"
      end
      objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream"
      pdf, offsets = "%PDF-1.4\n".dup, [0]
      objects.each_with_index do |object, index|
        offsets << pdf.bytesize
        pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      end
      xref = pdf.bytesize
      pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
      offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset) }
      pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
      File.binwrite(source, pdf)
      source_digest = Digest::SHA256.file(source).hexdigest
      points = [[10, 50, [255, 0, 0, 255]], [150, 50, [0, 255, 0, 255]],
                [10, 110, [0, 0, 255, 255]], [150, 110, [255, 255, 0, 255]]]
      [0, 90, 180, 270].each_with_index do |rotation, index|
        png, raw = File.join(folder, "page#{index}.png"), File.join(folder, "page#{index}.rgba")
        plan = Subject.plan(executable, source, index + 1, 72, png)
        run = importer::CommandRunner.run(plan[:arguments], :timeout_s => 30, :env => plan[:environment])
        assert Subject.validate_result!(run, plan)
        assert_equal source_digest, Digest::SHA256.file(source).hexdigest
        prepared = importer::PngCropper.prepare_rgba!(png, raw)
        width = importer::PageTransform.effective_width([-20, 30, 180, 130], rotation).to_i
        height = importer::PageTransform.effective_height([-20, 30, 180, 130], rotation).to_i
        assert_equal [width, height], [prepared[:pixel_width], prepared[:pixel_height]]
        assert prepared[:alpha_channel_verified]
        File.open(raw, 'rb') do |file|
          points.each do |x, y, color|
            px, py = importer::PageTransform.transform_point(x, y, [-20, 30, 180, 130], rotation)
            file.seek(((height - 1 - py.to_i) * width + px.to_i) * 4)
            assert_equal color, file.read(4).unpack('C*'), "rotation #{rotation}, source #{x},#{y}"
          end
          # The original CropBox clips visibility without resizing/translating
          # the MediaBox canvas. Do not expose the deliberately exterior marks.
          [[-10, 40], [170, 40], [-10, 120], [170, 120]].each do |x, y|
            px, py = importer::PageTransform.transform_point(x, y, [-20, 30, 180, 130], rotation)
            file.seek(((height - 1 - py.to_i) * width + px.to_i) * 4)
            assert_equal 0, file.read(4).unpack('C*')[3]
          end
          file.seek(((height / 2) * width + width / 2) * 4)
          assert_equal 0, file.read(4).unpack('C*')[3]
        end
      end
    end
  end

  def test_real_missing_font_cannot_be_silently_certified_as_standard_font_resolution
    importer = BlueCollarSystems::PDFVectorImporter
    executable = importer::DependencyResolver.find_ghostscript
    skip 'Ghostscript runtime unavailable for font fixture' unless executable
    poisoned = { 'GS_OPTIONS' => '-dFILTERTEXT', 'GS_DLL' => 'C:/missing/foreign-gs.dll',
                 'GS_LIB' => 'C:/missing/foreign-resources' }
    previous = {}
    poisoned.each { |key, value| previous[key] = ENV[key]; ENV[key] = value }
    Dir.mktmpdir('rgba-font-fixture') do |folder|
      ['Helvetica', 'BCSMissingFontFixture'].each do |font|
        source, output = File.join(folder, "#{font}.pdf"), File.join(folder, "#{font}.png")
        content = "BT /F1 24 Tf 10 50 Td (Font proof) Tj ET\n"
        objects = ['<< /Type /Catalog /Pages 2 0 R >>',
                   '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] ' \
                   '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
                   "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream",
                   "<< /Type /Font /Subtype /Type1 /BaseFont /#{font} >>"]
        pdf, offsets = "%PDF-1.4\n".dup, [0]
        objects.each_with_index do |object, index|
          offsets << pdf.bytesize
          pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
        end
        xref = pdf.bytesize
        pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
        offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset) }
        pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
        File.binwrite(source, pdf)
        plan = Subject.plan(executable, source, 1, 72, output)
        run = importer::CommandRunner.run(plan[:arguments], :timeout_s => 30, :env => plan[:environment])
        if font == 'Helvetica'
          assert Subject.validate_result!(run, plan)
          assert_includes run[:stdout], 'Loading font Helvetica (or substitute) from %rom%Resource/Font/NimbusSans-Regular'
          # This PDF contains only text. Inherited FILTERTEXT would erase all
          # visible pixels, and inherited GS_DLL would prevent any render.
          assert importer::PngCropper.inspect_pixels!(output)[:visible_pixel_present]
        else
          assert_raises(ContractError) { Subject.validate_result!(run, plan) }
          assert_includes run[:stdout], 'Loading font BCSMissingFontFixture (or substitute)'
        end
      end
    end
  ensure
    previous.each { |key, value| ENV[key] = value } if previous
  end

  def test_runtime_overrides_do_not_inherit_options_dll_or_resource_paths
    inherited = { 'GS_OPTIONS' => '-dFILTERTEXT', 'GS_DLL' => 'external.dll',
                  'GS_LIB' => 'external resources', 'GS_FONTPATH' => 'external fonts',
                  'GS_OTHER' => 'external', 'SystemRoot' => 'C:/Windows' }
    before = inherited.dup
    env = Subject.environment('/fixture/gswin64c.exe', inherited)
    assert_equal before, inherited
    assert_equal '', env['GS_OPTIONS']
    assert_equal '', env['GS_FONTPATH']
    assert_nil env['GS_OTHER']
    refute_equal 'external.dll', env['GS_DLL']
    refute_includes env['GS_LIB'], 'external'
    assert_includes env['GS_LIB'], '%rom%Resource/Init/'
  end
end
