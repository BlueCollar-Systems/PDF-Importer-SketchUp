require 'minitest/autorun'
require 'minitest/mock'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

# Pure-Ruby diagnostics tests. No SketchUp model or helper process is launched.
class WhiteMaskProgressTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  MASK = IMP::PlanarWhiteKnockout
  LOG = IMP::Logger
  CONTROL = IMP::ImportRunControl

  def setup
    @now = 0.0
    @lines = []
    @flushes = 0
    @fail_info = false
    @fail_flush = false
  end

  def progress_opts(extra = {})
    { :page_number => 1, :mask_progress => { :started_at => 0.0 } }.merge(extra)
  end

  def with_progress
    write = lambda do |context, message|
      raise IOError, 'fictional log write failure' if @fail_info
      @lines << [context, message]
    end
    flush = lambda do
      raise IOError, 'fictional log flush failure' if @fail_flush
      @flushes += 1
    end
    MASK.stub(:white_mask_progress_clock, lambda { @now }) do
      LOG.stub(:info, write) do
        LOG.stub(:flush_log, flush) { yield }
      end
    end
  end

  def test_absent_progress_state_does_not_write_or_flush
    with_progress do
      assert_equal false, MASK.log_progress!({}, :ignored, {}, true)
      assert_empty @lines
      assert_equal 0, @flushes
    end
  end

  def test_forced_stage_start_flushes_immediately
    with_progress do
      assert_equal true, MASK.log_progress!(progress_opts, :page_started, {}, true)
      assert_equal 1, @lines.length
      assert_equal 1, @flushes
      assert_includes @lines.first[1], 'event=page_started'
    end
  end

  def test_thousand_coarse_checkpoints_do_not_write_per_cell
    with_progress do
      opts = progress_opts
      MASK.log_progress!(opts, :page_started, {}, true)
      @now = 9.99
      1000.times { |index| MASK.run_checkpoint!(opts, :white_mask_cells, index, 1000) }
      assert_equal 1, @lines.length
      assert_equal 1, @flushes
      @now = 10.0
      assert_equal false, MASK.run_checkpoint!(opts, :white_mask_cells, 1000, 1000)
      assert_equal 2, @lines.length
      assert_equal 2, @flushes
      assert_includes @lines.last[1], 'completed=1000'
    end
  end

  def test_attempt_records_actual_source_orders_and_elapsed_time
    with_progress do
      opts = progress_opts(:page_number => 2, :mask_progress => {
        :started_at => 0.0, :mask_started_at => 1.0,
        :mask_index => 4, :mask_total => 19,
        :pdf_paint_order => [0,2398820], :svg_paint_order => [0,7670653] })
      @now = 12.5
      MASK.log_progress!(opts, :mask_attempt, { :phase => :exact_partition }, true)
      ['page=2', 'mask_index=4', 'mask_total=19',
       'pdf_paint_order=[0, 2398820]', 'svg_paint_order=[0, 7670653]',
       'mask_elapsed_s=11.5'].each { |part| assert_includes @lines.last[1], part }
      assert_equal 1, @flushes
    end
  end

  def test_existing_planar_checkpoint_delegates_once_with_unchanged_arguments
    calls = []
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |*args| calls << args; :actual_return }
    with_progress do
      assert_equal true, MASK.run_checkpoint!({ :run_controller => controller }, :white_mask, 1, 9)
      assert_equal [[:white_mask, { :completed => 1, :total => 9, :page => nil }]], calls
    end
  end

  def test_planar_checkpoint_keeps_terminal_exception_identity
    error = CONTROL::ImportCancelled.new([1], 2, { :stage => :white_mask })
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |*_args| raise error }
    with_progress do
      caught = assert_raises(CONTROL::ImportCancelled) do
        MASK.run_checkpoint!(progress_opts(:run_controller => controller), :white_mask, 1, 9)
      end
      assert_same error, caught
      assert_empty @lines
      assert_equal 0, @flushes
    end
  end

  def test_write_and_flush_failure_do_not_fail_progress_call
    with_progress do
      @fail_info = true
      assert_equal false, MASK.log_progress!(progress_opts, :mask_attempt, {}, true)
      @fail_info = false
      @fail_flush = true
      assert_equal false, MASK.log_progress!(progress_opts, :mask_attempt, {}, true)
    end
  end

  def test_error_detail_is_bounded_and_redacts_local_path
    with_progress do
      MASK.log_progress!(progress_opts, :page_interrupted,
        { :detail => "C:/fictional/private-file.pdf\n" + 'x' * 1000 }, true)
      refute_includes @lines.last[1], 'private-file.pdf'
      assert_operator @lines.last[1].length, :<, 300
    end
  end

  def test_main_interruption_logs_and_rethrows_same_terminal_object
    error = CONTROL::RollbackFailure.new('fictional uncertain rollback')
    failure = lambda { |*_args| raise error }
    with_progress do
      IMP.stub(:collect_page_composition_inventory!, failure) do
        caught = assert_raises(CONTROL::RollbackFailure) do
          IMP.compose_page_white_masks!(Object.new, [], [], :page_number => 3)
        end
        assert_same error, caught
      end
      assert_equal 2, @lines.length
      assert_equal 2, @flushes
      assert_includes @lines.last[1], 'event=page_interrupted'
    end
  end

  def test_proxy_preserves_stage_detail_and_return_object_identity
    calls, returned = [], Object.new
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |stage, detail| calls << [stage, detail]; returned }
    with_progress do
      proxy = MASK.progress_controller(controller, progress_opts)
      stage = 'fictional-source-stage'
      detail = { :page => 1, :completed => 4, :total => 12 }.freeze
      assert_same returned, proxy.checkpoint!(stage, detail)
      assert_equal 1, calls.length
      assert_same stage, calls.first[0]
      assert_same detail, calls.first[1]
      refute proxy.respond_to?(:retain_page!)
    end
  end

  def test_nil_unsupported_and_disabled_controllers_remain_same_objects
    with_progress do
      [nil, false, Object.new].each do |controller|
        assert_same controller, MASK.progress_controller(controller, progress_opts)
      end
      controller = Object.new
      controller.define_singleton_method(:checkpoint!) { |*_args| :value }
      assert_same controller, MASK.progress_controller(controller, {})
      assert_empty @lines
      assert_equal 0, @flushes
    end
  end

  def test_proxy_preserves_cancel_mismatch_and_rollback_exception_identity
    errors = [CONTROL::ImportCancelled.new([1], 2, { :stage => :white_mask_partition }),
      CONTROL::ResumeMismatch.new('fictional changed resume'),
      CONTROL::RollbackFailure.new('fictional uncertain rollback')]
    with_progress do
      errors.each do |error|
        controller = Object.new
        controller.define_singleton_method(:checkpoint!) { |*_args| raise error }
        proxy = MASK.progress_controller(controller, progress_opts)
        caught = assert_raises(error.class) do
          proxy.checkpoint!(:white_mask_partition, :completed => 0, :total => 9)
        end
        assert_same error, caught
      end
      assert_empty @lines
      assert_equal 0, @flushes
    end
  end

  def test_proxy_and_planar_calls_share_ten_second_sampler_and_nil_return
    count = 0
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |*_args| count += 1; nil }
    with_progress do
      opts = progress_opts
      proxy = MASK.progress_controller(controller, opts)
      opts[:run_controller] = proxy
      assert_nil proxy.checkpoint!(:white_mask_partition, :completed => 0, :total => 64)
      @now = 9.99
      1000.times { |index| MASK.run_checkpoint!(opts, :white_mask_cells, index, 1000) }
      assert_equal 1001, count
      assert_equal 1, @lines.length
      assert_equal 1, @flushes
      @now = 10.0
      proxy.checkpoint!(:white_mask_partition, :completed => 32, :total => 64)
      assert_equal 2, @lines.length
      assert_equal 2, @flushes
      assert_includes @lines.last[1], 'phase=:white_mask_partition'
    end
  end

  def test_unchanged_boundary_checkpoint_reports_actual_partition_phase
    calls, returned = [], Object.new
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |*args| calls << args; returned }
    with_progress do
      opts = progress_opts(:page_number => 4)
      opts[:run_controller] = MASK.progress_controller(controller, opts)
      result = IMP::SvgRegionBoundary.run_checkpoint!(opts, :white_mask_partition, 16, 96)
      assert_same returned, result
      assert_equal [[:white_mask_partition, { :completed => 16, :total => 96, :page => 4 }]], calls
      assert_equal 1, @lines.length
      assert_equal 1, @flushes
    end
  end

  def test_logging_failure_does_not_replace_successful_proxy_return
    returned = Object.new
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |*_args| returned }
    with_progress do
      proxy = MASK.progress_controller(controller, progress_opts)
      @fail_info = true
      assert_same returned, proxy.checkpoint!(:white_mask_partition, {})
    end
  end

  def test_diagnostic_preparation_failure_does_not_replace_controller_return
    returned = Object.new
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |*_args| returned }
    detail_type = Class.new(Hash) do
      def merge(*_args); raise ArgumentError, 'fictional diagnostic copy failure'; end
    end
    with_progress do
      proxy = MASK.progress_controller(controller, progress_opts)
      assert_same returned, proxy.checkpoint!(:white_mask_partition, detail_type.new)
    end
  end
end
