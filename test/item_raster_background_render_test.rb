#!/usr/bin/env ruby
# The one item Raster page render starts in the background as soon as a page
# knows some text items step down, and the ladder collects it when the first
# item needs it.
#
# Same plan, argv, environment, source binding and result checks as the
# synchronous render; Esc, the time limit and the import's temp cleanup stop
# the child. The "renderer" here is a Ruby child that copies a made-up PNG;
# nothing is a real drawing.

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'zlib'
require 'rbconfig'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class ItemRasterBackgroundRenderTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  RENDERER = IMP::ItemRasterPageRenderer
  BACKGROUND = RENDERER::BackgroundRender
  MEDIA_BOX = [0, 0, 7.2, 7.2].freeze # 0.1 in: 15 x 15 px at 150 dpi

  def png_chunk(type, data)
    [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
  end

  # A made-up 15 x 15 RGBA picture: transparent with one opaque pixel.
  def made_up_png(width = 15, height = 15)
    rows = Array.new(height) do |row|
      pixels = Array.new(width) { |col| row == 7 && col == 7 ? [0, 0, 0, 255] : [0, 0, 0, 0] }
      [0].pack('C') + pixels.flatten.pack('C*')
    end
    header = [width, height, 8, 6, 0, 0, 0].pack('NNCCCCC')
    "\x89PNG\r\n\x1a\n".dup.force_encoding(Encoding::BINARY) + png_chunk('IHDR', header) +
      png_chunk('IDAT', Zlib::Deflate.deflate(rows.join)) + png_chunk('IEND', '')
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM, RangeError
    false
  end

  # Windows can still open a just-reaped process for a moment; give it 2 s.
  def gone?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    while alive?(pid)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    true
  end

  # Runs the block with a renderer whose plan launches `script` (Ruby source
  # that receives the made-up PNG path and the output path).
  def with_fake_renderer(script, ghostscript = 'made-up-gs.exe')
    Dir.mktmpdir('bc_bg_render') do |folder|
      pdf = File.join(folder, 'made_up.pdf')
      picture = File.join(folder, 'picture.png')
      File.binwrite(pdf, "%PDF-1.4\nmade up\n%%EOF\n")
      File.binwrite(picture, made_up_png)
      plans = []
      plan = lambda do |executable, _source, _page, _dpi, output|
        raise IMP::RepresentationFidelity::ContractError, 'Ghostscript transparent page renderer is unavailable' unless executable
        plans << output
        { :engine => :ghostscript, :renderer => RENDERER::RENDERER,
          :executable => executable, :executable_sha256 => '0' * 64,
          :environment => { 'BC_MADE_UP' => '1' }, :output_path => output,
          :arguments => [RbConfig.ruby, '-e', script, picture, output] }
      end
      synchronous = lambda { |*_args| raise 'the synchronous render must not run' }
      IMP::DependencyResolver.stub(:find_ghostscript, ghostscript) do
        RENDERER.stub(:plan, plan) do
          IMP::CommandRunner.stub(:run, synchronous) do
            yield pdf, plans
          end
        end
      end
    end
  end

  COPY = 'sleep 0.3; File.binwrite(ARGV[1], File.binread(ARGV[0]))'.freeze
  SLOW = 'sleep 60'.freeze

  def import_opts
    opts = { :raster_dpi => 150 }
    IMP.initialize_item_raster_import_cache!(opts, true)
    opts
  end

  def test_the_background_render_is_collected_instead_of_started_again
    with_fake_renderer(COPY) do |pdf, plans|
      opts = import_opts
      job = IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, opts)
      refute_nil job
      assert_equal 1, opts[:item_raster_page_prefetch].length
      assert_nil IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, opts),
                 'one render per page'
      page = IMP.prepare_item_raster_page!(pdf, 1, MEDIA_BOX, 0, opts)
      assert_equal true, page[:render_started_in_background]
      assert_kind_of Numeric, page[:render_wait_ms]
      assert_equal [15, 15], [page[:pixel_width], page[:pixel_height]]
      assert_equal 1, plans.length, 'the page was planned once'
      assert_empty opts[:item_raster_page_prefetch]
      again = IMP.prepare_item_raster_page!(pdf, 1, MEDIA_BOX, 0, opts)
      assert_same page, again, 'later items reuse the cached page'
      folders = page[:owned_temp_directories]
      assert folders.all? { |path| File.directory?(path) }
      IMP.cleanup_item_raster_page_cache!(opts)
      refute folders.any? { |path| File.exist?(path) }
    end
  end

  def test_esc_while_waiting_stops_the_render_and_removes_its_folder
    with_fake_renderer(SLOW) do |pdf, _plans|
      opts = import_opts
      calls = 0
      controller = Object.new
      controller.define_singleton_method(:checkpoint!) do |_stage, _detail = {}|
        calls += 1
        raise IMP::ImportRunControl::ImportCancelled.new([], 1, {}) if calls >= 2
        {}
      end
      opts[:run_controller] = controller
      job = IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, opts)
      pid = job[:render].pid
      folder = job[:owned_temp_dir]
      assert alive?(pid)
      assert_raises(IMP::ImportRunControl::ImportCancelled) do
        IMP.prepare_item_raster_page!(pdf, 1, MEDIA_BOX, 0, opts)
      end
      assert gone?(pid), 'Esc must stop the render'
      refute File.exist?(folder)
      assert_empty opts[:item_raster_page_failures], 'Esc is not a page rejection'
      assert_empty opts[:item_raster_page_cache]
      IMP.cleanup_item_raster_page_cache!(opts)
    end
  end

  def test_import_cleanup_stops_a_running_render_and_deletes_its_folder
    with_fake_renderer(SLOW) do |pdf, _plans|
      opts = import_opts
      job = IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, opts)
      pid = job[:render].pid
      folder = job[:owned_temp_dir]
      IMP.cleanup_item_raster_page_cache!(opts)
      assert gone?(pid)
      refute File.exist?(folder)
      assert_empty opts[:item_raster_page_prefetch]
    end
  end

  def test_a_page_that_did_not_need_raster_discards_only_its_own_render
    with_fake_renderer(SLOW) do |pdf, _plans|
      opts = import_opts
      first = IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, opts)
      second = IMP.start_item_raster_page_prefetch!(pdf, 2, MEDIA_BOX, 0, opts)
      IMP.discard_item_raster_page_prefetch!(opts, 1)
      # The still-running second child holds an inherited handle to the
      # first one on Windows, so the OS check waits for the cleanup below.
      assert first[:render].exited?, 'the unused render was stopped and reaped'
      refute File.exist?(first[:owned_temp_dir])
      assert alive?(second[:render].pid)
      assert_equal [second], opts[:item_raster_page_prefetch].values
      IMP.cleanup_item_raster_page_cache!(opts)
      assert second[:render].exited?
      assert gone?(second[:render].pid)
      assert gone?(first[:render].pid)
    end
  end

  def test_nothing_starts_without_ghostscript_or_an_import_cache
    with_fake_renderer(COPY, nil) do |pdf, _plans|
      opts = import_opts
      made = []
      real_mktmpdir = IMP::SafeTemp.method(:mktmpdir)
      IMP::SafeTemp.stub(:mktmpdir, lambda { |*args| made << real_mktmpdir.call(*args); made.last }) do
        assert_nil IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, opts)
      end
      assert_empty opts[:item_raster_page_prefetch]
      assert_equal 1, made.length
      refute File.exist?(made.first), 'the unused folder is removed'
      assert_nil IMP.start_item_raster_page_prefetch!(pdf, 1, MEDIA_BOX, 0, { :raster_dpi => 150 })
    end
  end

  def test_the_time_limit_stops_the_child_and_the_result_is_rejected_as_before
    Dir.mktmpdir('bc_bg_timeout') do |folder|
      render = BACKGROUND.new([RbConfig.ruby, '-e', SLOW], nil, folder, 0.3)
      run = render.wait!
      assert gone?(render.pid)
      assert_equal true, run[:timed_out]
      assert_equal false, run[:ok]
      plan = { :output_path => File.join(folder, 'page.png') }
      error = assert_raises(IMP::RepresentationFidelity::ContractError) do
        RENDERER.validate_result!(run, plan)
      end
      assert_match(/renderer timed out/, error.message)
    end
  end

  def test_the_result_has_the_synchronous_runner_shape_and_reads_both_streams
    Dir.mktmpdir('bc_bg_shape') do |folder|
      script = '$stdout.write("made up out"); $stderr.write("made up err"); exit 0'
      run = BACKGROUND.new([RbConfig.ruby, '-e', script], nil, folder, 30).wait!
      assert_equal [:error, :exitstatus, :ok, :stderr, :stdout, :timed_out], run.keys.sort
      assert_equal true, run[:ok]
      assert_equal 0, run[:exitstatus]
      assert_equal 'made up out', run[:stdout]
      assert_equal 'made up err', run[:stderr]
      failed = BACKGROUND.new([RbConfig.ruby, '-e', 'exit 3'], nil, folder, 30).wait!
      assert_equal false, failed[:ok]
      assert_equal 3, failed[:exitstatus]
    end
  end

  def test_a_stopped_render_is_never_successful
    Dir.mktmpdir('bc_bg_stop') do |folder|
      render = BACKGROUND.new([RbConfig.ruby, '-e', SLOW], nil, folder, 30)
      render.stop!
      assert gone?(render.pid)
      assert_equal false, render.result[:ok]
      assert_match(/stopped/, render.result[:error])
      render.stop!
    end
  end

  def test_an_error_in_the_wait_tick_stops_the_child_first
    Dir.mktmpdir('bc_bg_tick') do |folder|
      render = BACKGROUND.new([RbConfig.ruby, '-e', SLOW], nil, folder, 30)
      assert_raises(IOError) { render.wait!(lambda { raise IOError, 'made up' }) }
      assert gone?(render.pid)
    end
  end

  def test_item_raster_does_not_turn_esc_into_an_item_failure
    item = Struct.new(:source_span_id, :text).new('text_span:1:0', 'made up')
    cancel = lambda { |*_args| raise IMP::ImportRunControl::ImportCancelled.new([], 1, {}) }
    IMP.stub(:prepare_item_raster_page!, cancel) do
      assert_raises(IMP::ImportRunControl::ImportCancelled) do
        IMP.import_item_as_raster(nil, nil, 'made_up.pdf', 1, item, MEDIA_BOX,
                                  { :item_raster_cache_persistent => true }, Time.now)
      end
    end
  end
end
