require 'minitest/autorun'
require 'tmpdir'
require 'open3'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/poppler_result_validator'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_salvage'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class PopplerBoundaryValidationTest < Minitest::Test
  NS = BlueCollarSystems::PDFVectorImporter
  RUNNER = NS::CommandRunner
  EXTERNAL = NS::ExternalTextExtractor
  SVG = NS::SvgTextRenderer
  SALVAGE = NS::PdfSalvage
  RESOLVER = NS::DependencyResolver
  PROOF = NS::PopplerSemanticProof

  PROVEN_ADOBE_GB1_DIAGNOSTICS = [
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

  PDFFONTS_UNEMBEDDED = [
    'name                 type        encoding   emb sub uni object ID',
    '-------------------- ----------- ---------- --- --- --- ---------',
    'Symbol               Type 1      Builtin    no  no  no      12  0'
  ].join("\n") + "\n"

  VALID_SEMANTIC_SVG = '<svg viewBox="0 0 100 100"><defs>' \
    '<path id="glyph-0-1" d="M0 0L1 0L1 1Z"/>' \
    '</defs><use xlink:href="#glyph-0-1" x="10" y="20"/></svg>'

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

  class SemanticPoint
    attr_reader :x, :y, :z
    def initialize(x, y, z = 0.0)
      @x = x; @y = y; @z = z
    end
    def transform(_transformation); self; end
    def distance(other)
      dx = x.to_f - other.x.to_f
      dy = y.to_f - other.y.to_f
      dz = z.to_f - other.z.to_f
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
  end

  class SemanticTransformation
    def initialize(*_args); end
  end

  class SemanticVector
    def initialize(*_args); end
  end

  class SemanticEdge
    attr_accessor :layer
  end

  class SemanticEntities
    def model
      @model ||= Object.new
    end
    def add_edges(points)
      Array.new([points.length - 1, 0].max) { SemanticEdge.new }
    end
  end

  def temp_pdf(label)
    path = File.join(Dir.tmpdir,
      "bc_poppler_boundary_#{label}_#{Process.pid}_#{rand(1_000_000)}.pdf")
    File.open(path, 'wb') { |file| file.write('%PDF-1.4') }
    path
  end

  def successful_run(stderr = '', stdout = '')
    {
      ok: true,
      timed_out: false,
      exitstatus: 0,
      stdout: stdout,
      stderr: stderr,
      error: nil
    }
  end

  def test_external_text_rejects_both_partial_page_attempts_and_cleans_artifacts
    pdf = temp_pdf('external')
    calls = []
    artifacts = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_exe = EXTERNAL.method(:pdftotext_executable)
    EXTERNAL.define_singleton_method(:pdftotext_executable) { 'pdftotext.exe' }
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      calls << args
      artifacts << args[-1]
      File.open(args[-1], 'wb') { |file| file.write(VALID_BBOX_HTML) }
      success.call(PROVEN_ADOBE_GB1_DIAGNOSTICS)
    end

    items = EXTERNAL.extract(pdf, 1, nominal_anchors: [])

    assert_empty items
    assert_equal 2, calls.length, 'cropbox rejection must try the media-box text route'
    artifacts.each { |path| refute File.exist?(path), "leaked rejected artifact #{path}" }
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    EXTERNAL.define_singleton_method(:pdftotext_executable, original_exe) if original_exe
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).each { |path| File.delete(path) if File.exist?(path) }
  end

  def test_svg_rejects_partial_poppler_page_and_uses_mutool_for_same_geometry_representation
    pdf = temp_pdf('svg')
    calls = []
    artifacts = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_poppler = SVG.method(:find_pdftocairo)
    original_mutool = SVG.method(:find_mutool)
    original_renderable = SVG.method(:ensure_renderable_pdf)
    SVG.define_singleton_method(:find_pdftocairo) { 'pdftocairo.exe' }
    SVG.define_singleton_method(:find_mutool) { 'mutool.exe' }
    SVG.define_singleton_method(:ensure_renderable_pdf) { |path, _exe| path }
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      calls << args
      if args[0] == 'pdftocairo.exe'
        out = args[-1]
        stderr = PROVEN_ADOBE_GB1_DIAGNOSTICS
      else
        out = args[args.index('-o') + 1]
        stderr = ''
      end
      artifacts << out
      File.open(out, 'wb') { |file| file.write('<svg viewBox="0 0 100 100"></svg>') }
      success.call(stderr)
    end

    failure = {}
    result = SVG.render(Object.new, pdf, 1, [0, 0, 100, 100],
      :failure_info => failure)

    assert_nil result
    assert_equal ['pdftocairo.exe', 'mutool.exe'], calls.map { |args| args[0] }
    assert_equal 'svg_zero_placements', failure[:reason]
    artifacts.each { |path| refute File.exist?(path), "leaked rejected artifact #{path}" }
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    SVG.define_singleton_method(:find_pdftocairo, original_poppler) if original_poppler
    SVG.define_singleton_method(:find_mutool, original_mutool) if original_mutool
    SVG.define_singleton_method(:ensure_renderable_pdf, original_renderable) if original_renderable
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).uniq.each { |path| File.delete(path) if File.exist?(path) }
  end

  def test_svg_accepts_diagnostic_cluster_only_after_active_semantic_proof
    pdf = temp_pdf('svg_semantic_complete')
    original_run = RUNNER.method(:run)
    original_poppler = SVG.method(:find_pdftocairo)
    original_mutool = SVG.method(:find_mutool)
    original_renderable = SVG.method(:ensure_renderable_pdf)
    success = method(:successful_run)
    had_geom = Object.const_defined?(:Geom)
    original_geom = Object.const_get(:Geom) if had_geom
    had_sketchup = Object.const_defined?(:Sketchup)
    original_sketchup = Object.const_get(:Sketchup) if had_sketchup
    original_certificate = PROOF.const_get(:ADOBE_GB1_PAGE_CERTIFICATE)
    Object.send(:remove_const, :Geom) if had_geom
    Object.send(:remove_const, :Sketchup) if had_sketchup
    geom = Module.new
    geom.const_set(:Point3d, SemanticPoint)
    geom.const_set(:Transformation, SemanticTransformation)
    geom.const_set(:Vector3d, SemanticVector)
    Object.const_set(:Geom, geom)
    sketchup = Module.new
    class << sketchup
      attr_accessor :status_text
    end
    Object.const_set(:Sketchup, sketchup)

    SVG.define_singleton_method(:find_pdftocairo) { 'pdftocairo.exe' }
    SVG.define_singleton_method(:find_mutool) { nil }
    SVG.define_singleton_method(:ensure_renderable_pdf) { |path, _exe| path }
    svg_output = VALID_SEMANTIC_SVG
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      File.open(args[-1], 'wb') { |file| file.write(svg_output) }
      success.call(PROVEN_ADOBE_GB1_DIAGNOSTICS)
    end

    evidence = {
      :renderer => :pdftocairo,
      :representation => :glyph_geometry,
      :glyphs => SVG.parse_glyph_defs(VALID_SEMANTIC_SVG),
      :placements => SVG.parse_use_placements(VALID_SEMANTIC_SVG)
    }
    test_certificate = {
      :pdf_sha256 => PROOF.file_sha256(pdf),
      :page => 1,
      :glyph_count => evidence[:glyphs].length,
      :placement_count => evidence[:placements].length,
      :semantic_sha256 => PROOF.semantic_fingerprint(evidence),
      :allowed_unoutlined_glyph_ids => []
    }.freeze
    PROOF.send(:remove_const, :ADOBE_GB1_PAGE_CERTIFICATE)
    PROOF.const_set(:ADOBE_GB1_PAGE_CERTIFICATE, test_certificate)

    result = NS.render_svg_text_with_semantic_proof(
      SemanticEntities.new, pdf, 1, [0, 0, 100, 100],
      :raw_edge_glyphs => true)

    refute_nil result
    assert_equal :pdftocairo, result[:renderer]
    assert_equal 1, result[:glyphs]

    svg_output = VALID_SEMANTIC_SVG.sub('x="10"', 'x="11"')
    rejected = NS.render_svg_text_with_semantic_proof(
      SemanticEntities.new, pdf, 1, [0, 0, 100, 100],
      :raw_edge_glyphs => true)
    assert_nil rejected,
      'a page with some valid glyphs but a non-certified span set must be rejected'
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    SVG.define_singleton_method(:find_pdftocairo, original_poppler) if original_poppler
    SVG.define_singleton_method(:find_mutool, original_mutool) if original_mutool
    SVG.define_singleton_method(:ensure_renderable_pdf, original_renderable) if original_renderable
    Object.send(:remove_const, :Geom) if Object.const_defined?(:Geom)
    Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
    Object.const_set(:Geom, original_geom) if had_geom
    Object.const_set(:Sketchup, original_sketchup) if had_sketchup
    if defined?(PROOF) && original_certificate
      PROOF.send(:remove_const, :ADOBE_GB1_PAGE_CERTIFICATE) if
        PROOF.const_defined?(:ADOBE_GB1_PAGE_CERTIFICATE, false)
      PROOF.const_set(:ADOBE_GB1_PAGE_CERTIFICATE, original_certificate)
    end
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_pdffonts_rejects_only_the_proven_combined_cluster
    pdf = temp_pdf('pdffonts_bad')
    original_run = RUNNER.method(:run)
    original_find = SVG.method(:find_pdffonts)
    success = method(:successful_run)
    SVG.instance_variable_set(:@font_check_cache, {})
    SVG.define_singleton_method(:find_pdffonts) { |_exe| 'pdffonts.exe' }
    RUNNER.define_singleton_method(:run) do |_args, _opts = {}|
      success.call(PROVEN_ADOBE_GB1_DIAGNOSTICS, PDFFONTS_UNEMBEDDED)
    end

    refute SVG.pdf_needs_embedding?(pdf, 'pdftocairo.exe')
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    SVG.define_singleton_method(:find_pdffonts, original_find) if original_find
    SVG.instance_variable_set(:@font_check_cache, {})
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_pdffonts_accepts_language_pack_warning_alone_for_valid_inventory
    pdf = temp_pdf('pdffonts_benign')
    original_run = RUNNER.method(:run)
    original_find = SVG.method(:find_pdffonts)
    success = method(:successful_run)
    SVG.instance_variable_set(:@font_check_cache, {})
    SVG.define_singleton_method(:find_pdffonts) { |_exe| 'pdffonts.exe' }
    RUNNER.define_singleton_method(:run) do |_args, _opts = {}|
      success.call(
        "Syntax Error: Missing language pack for 'Adobe-GB1' mapping\n",
        PDFFONTS_UNEMBEDDED
      )
    end

    assert SVG.pdf_needs_embedding?(pdf, 'pdftocairo.exe')
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    SVG.define_singleton_method(:find_pdffonts, original_find) if original_find
    SVG.instance_variable_set(:@font_check_cache, {})
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_salvage_rejects_parseable_partial_pdf_and_deletes_only_attempt_output
    pdf = temp_pdf('salvage')
    outputs = []
    success = method(:successful_run)
    original_run = RUNNER.method(:run)
    original_find = RESOLVER.method(:find_pdftocairo)
    had_parser = NS.const_defined?(:PDFParser, false)
    original_parser = NS.const_get(:PDFParser) if had_parser
    NS.send(:remove_const, :PDFParser) if had_parser
    NS.const_set(:PDFParser, ParseablePdf)
    RESOLVER.define_singleton_method(:find_pdftocairo) { 'pdftocairo.exe' }
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      outputs << args[-1]
      File.open(args[-1], 'wb') { |file| file.write('%PDF-1.7 partial') }
      success.call(PROVEN_ADOBE_GB1_DIAGNOSTICS)
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
    Array(outputs).each { |path| File.delete(path) if File.exist?(path) }
  end

  def test_salvage_fallback_captures_stderr_before_validation
    pdf = temp_pdf('salvage_fallback')
    capture_calls = []
    outputs = []
    original_find = RESOLVER.method(:find_pdftocairo)
    original_capture = Open3.method(:capture3)
    runner_value = NS.const_get(:CommandRunner) if NS.const_defined?(:CommandRunner, false)
    NS.send(:remove_const, :CommandRunner) if runner_value
    RESOLVER.define_singleton_method(:find_pdftocairo) { 'fallback-pdftocairo.exe' }
    Open3.define_singleton_method(:capture3) do |*args|
      capture_calls << args
      outputs << args[-1]
      File.open(args[-1], 'wb') { |file| file.write('%PDF-1.7 partial') }
        ['', PROVEN_ADOBE_GB1_DIAGNOSTICS, SuccessStatus.new(0)]
    end

    result = SALVAGE.send(:salvage_with_poppler, pdf, 'encrypted')

    assert_nil result
    assert_equal 1, capture_calls.length
    refute File.exist?(outputs[0]), 'fallback rejected salvage artifact leaked'
  ensure
    Open3.define_singleton_method(:capture3, original_capture) if original_capture
    RESOLVER.define_singleton_method(:find_pdftocairo, original_find) if original_find
    NS.const_set(:CommandRunner, runner_value) if runner_value && !NS.const_defined?(:CommandRunner, false)
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(outputs).each { |path| File.delete(path) if File.exist?(path) }
  end
end
