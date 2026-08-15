require 'minitest/autorun'
require 'tmpdir'
require 'open3'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

unless defined?(Geom)
  module Geom; end
end
unless defined?(Geom::Point3d)
  class Geom::Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z = 0.0)
      @x = x
      @y = y
      @z = z
    end
  end
end

unless defined?(Sketchup)
  module Sketchup
    def self.status_text=(_value)
      true
    end
  end
end

class PopplerActiveBoundaryValidationTest < Minitest::Test
  NS = BlueCollarSystems::PDFVectorImporter
  RUNNER = NS::CommandRunner
  EXTERNAL = NS::ExternalTextExtractor
  SVG = NS::SvgTextRenderer
  SALVAGE = NS::PdfSalvage
  RESOLVER = NS::DependencyResolver

  DIAGNOSTIC_CLUSTER = [
    "Syntax Error: Missing language pack for 'Adobe-GB1' mapping",
    "Syntax Error: Unknown font tag 'china-s'",
    'Syntax Error (44846): No font in show/space'
  ].join("\n") + "\n"

  VALID_BBOX_HTML = <<-HTML
    <html><body><doc><page width="100" height="100">
      <line xMin="10" yMin="10" xMax="30" yMax="20">
        <word xMin="10" yMin="10" xMax="30" yMax="20">VISIBLE</word>
      </line>
    </page></doc></body></html>
  HTML

  SuccessStatus = Struct.new(:exitstatus) do
    def success?
      true
    end
  end

  class ParseablePdf
    def initialize(_path); end
    def parse; true; end
    def page_count; 1; end
  end

  class RejectingEntities
    attr_reader :add_image_calls

    def initialize
      @add_image_calls = []
    end

    def add_image(*args)
      @add_image_calls << args
      nil
    end
  end

  class RasterModel
    attr_reader :active_entities

    def initialize
      @active_entities = RejectingEntities.new
    end
  end

  class AcceptingImage
    attr_accessor :layer

    def set_attribute(*_args)
      true
    end
  end

  class AcceptingEntities
    attr_reader :add_image_calls

    def initialize
      @add_image_calls = []
    end

    def add_image(*args)
      @add_image_calls << args
      AcceptingImage.new
    end
  end

  class RasterLayers
    def [](_name)
      nil
    end

    def add(name)
      name
    end
  end

  class AcceptingRasterModel
    attr_reader :active_entities, :layers

    def initialize
      @active_entities = AcceptingEntities.new
      @layers = RasterLayers.new
    end
  end

  RasterItem = Struct.new(:source_span_id)

  def temp_pdf(label)
    path = File.join(
      Dir.tmpdir,
      "bc_poppler_active_#{label}_#{Process.pid}_#{rand(1_000_000)}.pdf"
    )
    File.open(path, 'wb') { |file| file.write('%PDF-1.4') }
    path
  end

  def successful_run(stderr = '', stdout = '')
    {
      :ok => true,
      :timed_out => false,
      :exitstatus => 0,
      :stdout => stdout,
      :stderr => stderr,
      :error => nil
    }
  end

  def test_external_text_rejects_each_zero_exit_partial_attempt_and_cleans_it
    pdf = temp_pdf('external')
    calls = []
    artifacts = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_exe = EXTERNAL.method(:pdftotext_executable)
    EXTERNAL.define_singleton_method(:pdftotext_executable) do
      'pdftotext.exe'
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      calls << args
      artifacts << args[-1]
      File.open(args[-1], 'wb') { |file| file.write(VALID_BBOX_HTML) }
      success.call(DIAGNOSTIC_CLUSTER)
    end

    items = EXTERNAL.extract(pdf, 1, :nominal_anchors => [])

    assert_empty items
    assert_equal 2, calls.length,
      'a rejected crop-box attempt must still try the same text representation in media space'
    artifacts.each do |path|
      refute File.exist?(path), "leaked rejected text artifact #{path}"
    end
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    EXTERNAL.define_singleton_method(
      :pdftotext_executable, original_exe
    ) if original_exe
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def test_content_streams_skip_pdf_reparse_for_nominal_anchors
    pdf = temp_pdf('streams_skip_reparse')
    parser_calls = 0
    original_new = NS::PDFParser.method(:new)
    NS::PDFParser.define_singleton_method(:new) do |*args|
      parser_calls += 1
      original_new.call(*args)
    end
    original_exe = EXTERNAL.method(:pdftotext_executable)
    original_run = RUNNER.method(:run)
    success = method(:successful_run)
    EXTERNAL.define_singleton_method(:pdftotext_executable) do
      'pdftotext.exe'
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      File.open(args[-1], 'wb') { |file| file.write(VALID_BBOX_HTML) }
      success.call('')
    end

    items = EXTERNAL.extract(
      pdf, 1, :content_streams => ['BT /F1 12 Tf 10 20 Td (VISIBLE) Tj ET']
    )

    assert_equal 0, parser_calls,
                 'decoded page streams must not trigger a second PDFParser'
    refute_empty items
    assert_equal 'VISIBLE', items.first.text
  ensure
    NS::PDFParser.define_singleton_method(:new, original_new) if original_new
    RUNNER.define_singleton_method(:run, original_run) if original_run
    EXTERNAL.define_singleton_method(
      :pdftotext_executable, original_exe
    ) if original_exe
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_empty_poppler_svg_retries_mutool_without_changing_representation
    pdf = temp_pdf('svg_retry')
    calls = []
    artifacts = []
    success = method(:successful_run)
    original_renderer = SVG.method(:find_svg_renderer)
    original_mutool = SVG.method(:find_mutool)
    original_renderable = SVG.method(:ensure_renderable_pdf)
    original_run = RUNNER.method(:run)
    SVG.define_singleton_method(:find_svg_renderer) do
      { :kind => :pdftocairo, :exe => 'pdftocairo.exe' }
    end
    SVG.define_singleton_method(:find_mutool) { 'mutool.exe' }
    SVG.define_singleton_method(:ensure_renderable_pdf) do |path, _exe|
      path
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      calls << args
      if args[0] == 'pdftocairo.exe'
        output = args[-1]
        stderr = DIAGNOSTIC_CLUSTER
      else
        output = args[args.index('-o') + 1]
        stderr = ''
      end
      artifacts << output
      File.open(output, 'wb') do |file|
        file.write('<svg viewBox="0 0 100 100"></svg>')
      end
      success.call(stderr)
    end

    failure = {}
    result = SVG.render(
      Object.new, pdf, 1, [0.0, 0.0, 100.0, 100.0],
      :failure_info => failure
    )

    assert_nil result
    assert_equal ['pdftocairo.exe', 'mutool.exe'],
      calls.map { |args| args[0] },
      'an unusable Poppler artifact must try the available same-representation renderer'
    assert_equal 'svg_zero_placements', failure[:reason]
    artifacts.each do |path|
      refute File.exist?(path), "leaked rejected SVG artifact #{path}"
    end
  ensure
    SVG.define_singleton_method(:find_svg_renderer, original_renderer) if
      original_renderer
    SVG.define_singleton_method(:find_mutool, original_mutool) if original_mutool
    SVG.define_singleton_method(
      :ensure_renderable_pdf, original_renderable
    ) if original_renderable
    RUNNER.define_singleton_method(:run, original_run) if original_run
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).uniq.each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def test_svg_structure_rejects_missing_placements_or_glyph_definitions
    assert_equal :svg_zero_placements,
      SVG.svg_structure_failure('<svg><path id="glyph-0-1" d="M0 0L1 0Z"/></svg>')
    assert_equal :svg_zero_glyph_defs,
      SVG.svg_structure_failure(
        '<svg><use xlink:href="#glyph-0-1" x="1" y="2"/></svg>'
      )
  end

  def test_salvage_rejects_parseable_zero_exit_partial_pdf_and_cleans_it
    pdf = temp_pdf('salvage')
    outputs = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_find = RESOLVER.method(:find_pdftocairo)
    had_parser = NS.const_defined?(:PDFParser, false)
    original_parser = NS.const_get(:PDFParser) if had_parser
    NS.send(:remove_const, :PDFParser) if had_parser
    NS.const_set(:PDFParser, ParseablePdf)
    RESOLVER.define_singleton_method(:find_pdftocairo) do
      'pdftocairo.exe'
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      outputs << args[-1]
      File.open(args[-1], 'wb') { |file| file.write('%PDF-1.7 partial') }
      success.call(DIAGNOSTIC_CLUSTER)
    end

    result = SALVAGE.send(:salvage_with_poppler, pdf, 'encrypted')

    assert_nil result
    assert_equal 1, outputs.length
    refute File.exist?(outputs[0]), 'rejected salvage artifact leaked'
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    RESOLVER.define_singleton_method(:find_pdftocairo, original_find) if original_find
    NS.send(:remove_const, :PDFParser) if NS.const_defined?(:PDFParser, false)
    NS.const_set(:PDFParser, original_parser) if had_parser
    SALVAGE.instance_variable_set(:@temp_salvages, [])
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(outputs).each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def test_salvage_fallback_captures_stderr_before_validation
    pdf = temp_pdf('salvage_fallback')
    capture_calls = []
    outputs = []
    original_find = RESOLVER.method(:find_pdftocairo)
    original_capture = Open3.method(:capture3)
    runner_value = NS.const_get(:CommandRunner) if
      NS.const_defined?(:CommandRunner, false)
    NS.send(:remove_const, :CommandRunner) if runner_value
    RESOLVER.define_singleton_method(:find_pdftocairo) do
      'fallback-pdftocairo.exe'
    end
    Open3.define_singleton_method(:capture3) do |*args|
      capture_calls << args
      outputs << args[-1]
      File.open(args[-1], 'wb') { |file| file.write('%PDF-1.7 partial') }
      ['', DIAGNOSTIC_CLUSTER, SuccessStatus.new(0)]
    end

    result = SALVAGE.send(:salvage_with_poppler, pdf, 'encrypted')

    assert_nil result
    assert_equal 1, capture_calls.length
    refute File.exist?(outputs[0]), 'fallback rejected salvage artifact leaked'
  ensure
    Open3.define_singleton_method(:capture3, original_capture) if original_capture
    RESOLVER.define_singleton_method(:find_pdftocairo, original_find) if original_find
    NS.const_set(:CommandRunner, runner_value) if runner_value &&
      !NS.const_defined?(:CommandRunner, false)
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(outputs).each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def test_page_raster_rejects_zero_exit_partial_png_before_host_placement
    pdf = temp_pdf('page_raster')
    model = RasterModel.new
    artifacts = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_find = NS.method(:safe_find_pdftocairo)
    original_verify = NS.method(:verify_raster_artifact!)
    NS.define_singleton_method(:safe_find_pdftocairo) { 'pdftocairo.exe' }
    NS.define_singleton_method(:verify_raster_artifact!) do |*_args|
      {
        :page_rotation => 0,
        :pixel_width => 100,
        :pixel_height => 100,
        :render_box => [0.0, 0.0, 72.0, 72.0],
        :render_box_used => :media_box
      }
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      path = args[-1] + '.png'
      artifacts << path
      File.open(path, 'wb') { |file| file.write('partial png') }
      success.call(DIAGNOSTIC_CLUSTER)
    end

    result = NS.import_page_as_raster(
      model, pdf, 1, [0.0, 0.0, 72.0, 72.0],
      { :raster_dpi => 150, :scale => 1.0 }, Time.now
    )

    refute result
    assert_equal 0, model.active_entities.add_image_calls.length,
      'a rejected Poppler artifact must never reach SketchUp'
    artifacts.each do |path|
      refute File.exist?(path), "leaked rejected page raster #{path}"
    end
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    NS.define_singleton_method(:safe_find_pdftocairo, original_find) if original_find
    NS.define_singleton_method(:verify_raster_artifact!, original_verify) if original_verify
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def test_page_raster_cleans_owned_png_when_artifact_verification_crashes
    pdf = temp_pdf('page_raster_verifier_exception')
    model = RasterModel.new
    artifacts = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_find = NS.method(:safe_find_pdftocairo)
    original_verify = NS.method(:verify_raster_artifact!)
    NS.define_singleton_method(:safe_find_pdftocairo) { 'pdftocairo.exe' }
    NS.define_singleton_method(:verify_raster_artifact!) do |*_args|
      raise 'unexpected verifier failure'
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      path = args[-1] + '.png'
      artifacts << path
      File.open(path, 'wb') { |file| file.write('owned png') }
      success.call
    end

    result = NS.import_page_as_raster(
      model, pdf, 1, [0.0, 0.0, 72.0, 72.0],
      { :raster_dpi => 150, :scale => 1.0 }, Time.now
    )

    refute result
    assert_equal 0, model.active_entities.add_image_calls.length
    artifacts.each do |path|
      refute File.exist?(path), "leaked PNG after verifier exception #{path}"
    end
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    NS.define_singleton_method(:safe_find_pdftocairo, original_find) if original_find
    NS.define_singleton_method(:verify_raster_artifact!, original_verify) if original_verify
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def test_page_raster_reports_render_verify_placement_and_cleanup_costs
    pdf = temp_pdf('page_raster_timings')
    model = AcceptingRasterModel.new
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_find = NS.method(:safe_find_pdftocairo)
    original_verify = NS.method(:verify_raster_artifact!)
    NS.define_singleton_method(:safe_find_pdftocairo) { 'pdftocairo.exe' }
    NS.define_singleton_method(:verify_raster_artifact!) do |path, *_args|
      {
        :png_path => path,
        :page_rotation => 0,
        :pixel_width => 100,
        :pixel_height => 100,
        :content_sha256 => 'a' * 64,
        :content_byte_size => File.size(path),
        :visual_pixel_sha256 => 'b' * 64,
        :source_pdf_sha256 => 'c' * 64,
        :render_box => [0.0, 0.0, 72.0, 72.0],
        :render_box_used => :media_box,
        :pixel_proof_ms => 1.25,
        :pixel_proof_temp_bytes => 0,
        :pixel_proof_decoder_backend => :native_zlib_stream
      }
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      File.binwrite(args[-1] + '.png', 'verified png')
      success.call
    end

    delivery = NS.import_page_as_raster(
      model, pdf, 1, [0.0, 0.0, 72.0, 72.0],
      { :raster_dpi => 150, :scale => 1.0 }, Time.now
    )

    refute delivery[:failure], delivery[:error].to_s
    assert_equal 1, model.active_entities.add_image_calls.length
    assert_equal 0, delivery[:performance][:pixel_proof_temp_bytes]
    assert_equal 1.25, delivery[:performance][:pixel_proof_ms]
    [:render_ms, :verify_ms, :add_image_ms, :cleanup_ms, :total_ms].each do |key|
      assert_operator delivery[:performance][key], :>=, 0.0, key.to_s
    end
    assert_operator delivery[:performance][:png_temp_bytes], :>, 0
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    NS.define_singleton_method(:safe_find_pdftocairo, original_find) if original_find
    NS.define_singleton_method(:verify_raster_artifact!, original_verify) if
      original_verify
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_item_raster_rejects_zero_exit_partial_png_before_host_placement
    pdf = temp_pdf('item_raster')
    model = RasterModel.new
    target_entities = RejectingEntities.new
    artifacts = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_find = NS.method(:safe_find_pdftocairo)
    original_crop = NS.method(:item_raster_crop_geometry)
    original_verify = NS.method(:verify_item_raster_artifact!)
    NS.define_singleton_method(:safe_find_pdftocairo) { 'pdftocairo.exe' }
    NS.define_singleton_method(:item_raster_crop_geometry) do |*_args|
      {
        :dpi => 150,
        :pixel_crop => [0, 0, 100, 100],
        :display_box => [0.0, 0.0, 72.0, 72.0],
        :display_width => 72.0,
        :display_height => 72.0
      }
    end
    NS.define_singleton_method(:verify_item_raster_artifact!) do |*_args|
      {
        :source_box => [0.0, 0.0, 72.0, 72.0],
        :pixel_crop => [0, 0, 100, 100],
        :pixel_width => 100,
        :pixel_height => 100
      }
    end
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      path = args[-1] + '.png'
      artifacts << path
      File.open(path, 'wb') { |file| file.write('partial png') }
      success.call(DIAGNOSTIC_CLUSTER)
    end

    result = NS.import_item_as_raster(
      model, target_entities, pdf, 1,
      RasterItem.new('text_span:1:0'),
      [0.0, 0.0, 72.0, 72.0],
      { :raster_dpi => 150, :scale => 1.0 }, Time.now
    )

    refute result
    assert_equal 0, target_entities.add_image_calls.length,
      'a rejected item artifact must never reach SketchUp'
    artifacts.each do |path|
      refute File.exist?(path), "leaked rejected item raster #{path}"
    end
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    NS.define_singleton_method(:safe_find_pdftocairo, original_find) if original_find
    NS.define_singleton_method(:item_raster_crop_geometry, original_crop) if original_crop
    NS.define_singleton_method(
      :verify_item_raster_artifact!, original_verify
    ) if original_verify
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).each do |path|
      File.delete(path) if File.exist?(path)
    end
  end
end
