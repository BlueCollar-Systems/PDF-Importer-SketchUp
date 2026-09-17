#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'

class LoggerIsolationTest < Minitest::Test
  LOG = BlueCollarSystems::PDFVectorImporter::Logger
  TEMP = BlueCollarSystems::PDFVectorImporter::SafeTemp
  SOURCE = File.expand_path(
    '../extracted/sketchup_ext/bc_pdf_vector_importer/logger.rb', __dir__
  )
  CHILD = <<-'RUBY'
    require 'json'
    require ARGV.fetch(0)
    logger = BlueCollarSystems::PDFVectorImporter::Logger
    marker = ARGV.fetch(1)
    logger.reset
    logger.info(marker, 'before peer reset')
    logger.flush_log
    STDOUT.puts(JSON.generate(:path => logger.log_path))
    STDOUT.flush
    STDIN.gets
    logger.info(marker, 'after peer reset')
    logger.flush_log
    logger.send(:close_log)
  RUBY

  def setup
    @root = Dir.mktmpdir('bc_logger_isolation_')
    @prior_override = ENV[TEMP::ENV_OVERRIDE]
    ENV[TEMP::ENV_OVERRIDE] = @root
    TEMP.reset!
    LOG.send(:close_log)
  end

  def teardown
    LOG.send(:close_log)
    ENV[TEMP::ENV_OVERRIDE] = @prior_override
    TEMP.reset!
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_reset_retains_previous_import_and_flushes_buffered_messages
    LOG.reset
    first = LOG.log_path
    LOG.warn('first-import', 'preserve this unflushed warning')
    LOG.error('first-import', 'preserve this unflushed failure')

    LOG.reset
    second = LOG.log_path
    assert File.file?(first), 'reset must preserve the previously returned file'
    refute_equal first, second
    assert_equal 'last_import.log', File.basename(second)
    assert_equal 0, LOG.warning_count
    assert_equal 0, LOG.error_count
    assert_includes File.read(first), 'preserve this unflushed warning'
    assert_includes File.read(first), 'preserve this unflushed failure'
    first_bytes = File.binread(first)

    LOG.info('second-import', 'current import message')
    LOG.flush_log
    assert_equal first_bytes, File.binread(first)
    current = File.read(second)
    assert_includes current, "[INFO] Logger: path=#{second}"
    assert_includes current, 'current import message'
    refute_includes current, 'first-import'
    assert second.ascii_only?, 'controlled ASCII temp root must remain ASCII'
  end

  def test_independent_process_resets_do_not_mix_buffered_logs
    paths = {}
    environment = { TEMP::ENV_OVERRIDE => @root }
    Open3.popen3(environment, RbConfig.ruby, '-e', CHILD, SOURCE, 'process-A') do |ai, ao, ae, aw|
      paths['process-A'] = read_path(ao)
      Open3.popen3(environment, RbConfig.ruby, '-e', CHILD, SOURCE, 'process-B') do |bi, bo, be, bw|
        paths['process-B'] = read_path(bo)
        ai.puts('continue')
        ai.flush
        assert Timeout.timeout(15) { aw.value }.success?, ae.read
        bi.puts('continue')
        bi.flush
        assert Timeout.timeout(15) { bw.value }.success?, be.read
      end
    end

    refute_equal paths['process-A'], paths['process-B']
    paths.each do |marker, path|
      content = File.read(path)
      assert_includes content, "[INFO] #{marker}: before peer reset"
      assert_includes content, "[INFO] #{marker}: after peer reset"
      peer = marker == 'process-A' ? 'process-B' : 'process-A'
      refute_includes content, peer
    end
  end

  private

  def read_path(stream)
    line = Timeout.timeout(15) { stream.gets }
    raise 'logger child ended before reporting its file' unless line
    JSON.parse(line).fetch('path')
  end
end
