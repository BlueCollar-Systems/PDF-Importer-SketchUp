require 'minitest/autorun'
require 'tmpdir'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/poppler_result_validator'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

unless defined?(Geom)
  module Geom; end
end
unless defined?(Geom::Point3d)
  class Geom::Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end
  end
end

class MainRasterPopplerValidationTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  RUNNER = IMP::CommandRunner

  PROVEN_ADOBE_GB1_DIAGNOSTICS = [
    "Syntax Error: Missing language pack for 'Adobe-GB1' mapping",
    "Syntax Error: Unknown font tag 'china-s'",
    'Syntax Error (44846): No font in show/space'
  ].join("\n") + "\n"

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

  class Model
    attr_reader :active_entities

    def initialize
      @active_entities = RejectingEntities.new
    end
  end

  def temp_pdf(label)
    path = File.join(Dir.tmpdir,
      "bc_main_raster_#{label}_#{Process.pid}_#{rand(1_000_000)}.pdf")
    File.open(path, 'wb') { |file| file.write('%PDF-1.4') }
    path
  end

  def run_result(ok, stderr = '', exitstatus = nil)
    {
      ok: ok,
      timed_out: false,
      exitstatus: exitstatus.nil? ? (ok ? 0 : 1) : exitstatus,
      stdout: '',
      stderr: stderr,
      error: nil
    }
  end

  def install_renderer_stubs(poppler, mutool)
    @original_poppler = IMP.method(:safe_find_pdftocairo)
    @had_mutool = IMP.respond_to?(:safe_find_mutool)
    @original_mutool = IMP.method(:safe_find_mutool) if @had_mutool
    IMP.define_singleton_method(:safe_find_pdftocairo) { poppler }
    IMP.define_singleton_method(:safe_find_mutool) { mutool }
  end

  def restore_renderer_stubs
    IMP.define_singleton_method(:safe_find_pdftocairo, @original_poppler) if @original_poppler
    if @had_mutool
      IMP.define_singleton_method(:safe_find_mutool, @original_mutool)
    elsif IMP.singleton_class.method_defined?(:safe_find_mutool)
      IMP.singleton_class.send(:remove_method, :safe_find_mutool)
    end
  end

  def test_partial_poppler_png_is_rejected_before_placement_then_mutool_is_tried
    pdf = temp_pdf('fallback')
    model = Model.new
    calls = []
    artifacts = []
    success = method(:run_result)
    original_run = RUNNER.method(:run)
    install_renderer_stubs('pdftocairo.exe', 'mutool.exe')
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      calls << args
      if args[0] == 'pdftocairo.exe'
        out = args[-1] + '.png'
      result = success.call(true, PROVEN_ADOBE_GB1_DIAGNOSTICS)
      else
        out = args[args.index('-o') + 1]
        result = success.call(true)
      end
      artifacts << out
      File.open(out, 'wb') { |file| file.write('nonempty png') }
      result
    end

    imported = IMP.import_page_as_raster(
      model, pdf, 1, [0, 0, 72, 72],
      { raster_dpi: 150, scale: 1.0 }, Time.now
    )

    refute imported
    assert_equal ['pdftocairo.exe', 'mutool.exe'], calls.map { |args| args[0] }
    assert_equal 1, model.active_entities.add_image_calls.length,
      'only the accepted same-representation artifact may reach SketchUp'
    artifacts.uniq.each { |path| refute File.exist?(path), "leaked raster artifact #{path}" }
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    restore_renderer_stubs
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).uniq.each { |path| File.delete(path) if File.exist?(path) }
  end

  def test_failed_process_with_partial_png_cleans_before_early_return
    pdf = temp_pdf('failure_cleanup')
    model = Model.new
    artifacts = []
    failure = method(:run_result)
    original_run = RUNNER.method(:run)
    install_renderer_stubs('pdftocairo.exe', nil)
    RUNNER.define_singleton_method(:run) do |args, _opts = {}|
      out = args[-1] + '.png'
      artifacts << out
      File.open(out, 'wb') { |file| file.write('partial png') }
      failure.call(false, 'ordinary failure', 9)
    end

    imported = IMP.import_page_as_raster(
      model, pdf, 1, [0, 0, 72, 72],
      { raster_dpi: 150, scale: 1.0 }, Time.now
    )

    refute imported
    assert_equal 0, model.active_entities.add_image_calls.length
    refute File.exist?(artifacts[0]), 'failed-process early return leaked PNG'
  ensure
    RUNNER.define_singleton_method(:run, original_run) if original_run
    restore_renderer_stubs
    File.delete(pdf) if pdf && File.exist?(pdf)
    Array(artifacts).each { |path| File.delete(path) if File.exist?(path) }
  end
end
