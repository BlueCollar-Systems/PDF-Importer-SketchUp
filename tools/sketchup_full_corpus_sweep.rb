#!/usr/bin/env ruby

require 'json'
require 'digest'
require 'fileutils'
require 'find'
require 'optparse'
require 'time'

require File.expand_path('sketchup_host_launcher', __dir__)

module SketchupFullCorpusSweep
  IMPORT_MODES = %w[auto vector raster hybrid].freeze
  TEXT_MODES = %w[text labels text3d glyphs geometry raster].freeze
  GENERATED_EVIDENCE_SEGMENT = 'imported evidence'.freeze

  module_function

  def default_source_root
    File.expand_path('../extracted/sketchup_ext', __dir__)
  end

  def discover_pdfs(root)
    expanded = File.expand_path(root.to_s)
    raise ArgumentError, "corpus directory not found: #{expanded}" unless
      File.directory?(expanded)

    pdfs = []
    Find.find(expanded) do |path|
      if File.directory?(path)
        if path != expanded &&
           File.basename(path).downcase == GENERATED_EVIDENCE_SEGMENT
          Find.prune
        end
        next
      end
      next unless File.file?(path)
      next unless File.extname(path).downcase == '.pdf'
      pdfs << File.expand_path(path)
    end
    pdfs.sort
  end

  def matrix(import_modes = IMPORT_MODES, text_modes = TEXT_MODES)
    Array(import_modes).flat_map do |import_mode|
      Array(text_modes).map do |text_mode|
        {
          'import_mode' => import_mode.to_s,
          'text_mode' => text_mode.to_s
        }
      end
    end
  end

  def safe_source_id(relative_path, sha256)
    stem = relative_path.to_s.tr('\\', '/')
    stem = stem.sub(/\.pdf\z/i, '')
    stem = stem.gsub(/[^0-9A-Za-z._-]+/, '-')
    stem = stem.gsub(/\A[-.]+|[-.]+\z/, '')
    stem = 'pdf' if stem.empty?
    "#{stem[0, 96]}--#{sha256.to_s[0, 12]}"
  end

  def source_tree_sha256(root)
    expanded = root.to_s.strip
    return nil if expanded.empty?
    SketchupHostEvidence.source_tree_sha256(expanded)
  end

  def exit_code(summary)
    return 1 if summary['failed'].to_i > 0
    return 0 if summary['paused'] == true
    return 1 if summary['skp_export_only'] == true
    complete = summary['not_run'].to_i == 0 &&
      summary['exported'].to_i == 0 &&
      summary['passed'].to_i == summary['total'].to_i
    complete ? 0 : 1
  end

  def atomic_write_json(path, payload)
    expanded = File.expand_path(path.to_s)
    FileUtils.mkdir_p(File.dirname(expanded))
    temporary = "#{expanded}.tmp-#{$$}-#{rand(1_000_000)}"
    File.open(temporary, 'wb') do |file|
      file.write(JSON.pretty_generate(payload))
      file.write("\n")
      file.flush
      begin
        file.fsync
      rescue StandardError
      end
    end
    FileUtils.mv(temporary, expanded, :force => true)
    expanded
  ensure
    File.delete(temporary) if temporary && File.file?(temporary)
  end

  class Runner
    def initialize(options)
      @corpus_root = File.expand_path(options.fetch(:corpus_root))
      @evidence_root = File.expand_path(options.fetch(:evidence_root))
      @import_modes = Array(
        options.fetch(:import_modes, IMPORT_MODES)
      ).map(&:to_s)
      @text_modes = Array(
        options.fetch(:text_modes, TEXT_MODES)
      ).map(&:to_s)
      @max_jobs = options[:max_jobs].to_i
      @max_jobs = nil unless @max_jobs > 0
      @skp_export_only = options.fetch(:skp_export_only, false) == true
      @pause_file = options[:pause_file].to_s
      @pause_file = File.expand_path(@pause_file) unless @pause_file.empty?
      configured_source = if options.key?(:source_root)
                            options[:source_root]
                          else
                            SketchupFullCorpusSweep.default_source_root
                          end
      @source_root = configured_source.to_s
      @source_root = File.expand_path(@source_root) unless @source_root.empty?
      @sketchup_exe = options[:sketchup_exe].to_s
      @launcher = options[:launcher] || method(:launch_host_job)
    end

    def run
      started_at = Time.now.utc.iso8601
      @source_tree_sha256 = SketchupFullCorpusSweep.source_tree_sha256(
        @source_root
      )
      pdfs = SketchupFullCorpusSweep.discover_pdfs(@corpus_root)
      raise ArgumentError, "corpus contains no PDF files: #{@corpus_root}" if
        pdfs.empty?
      cells = SketchupFullCorpusSweep.matrix(@import_modes, @text_modes)
      summary = {
        'schema' => 'bcs.sketchup_full_corpus_sweep/1.2',
        'started_at' => started_at,
        'corpus_root' => @corpus_root,
        'evidence_root' => @evidence_root,
        'pdf_count' => pdfs.length,
        'matrix_cells_per_pdf' => cells.length,
        'total' => pdfs.length * cells.length,
        'passed' => 0,
        'exported' => 0,
        'failed' => 0,
        'resumed' => 0,
        'not_run' => 0,
        'skp_export_only' => @skp_export_only,
        'source_tree_sha256' => @source_tree_sha256,
        'results' => []
      }
      attempted = 0
      pdfs.each do |pdf_path|
        source_sha256 = Digest::SHA256.file(pdf_path).hexdigest
        relative = relative_path(pdf_path)
        source_id = SketchupFullCorpusSweep.safe_source_id(
          relative, source_sha256
        )
        cells.each do |cell|
          if pause_requested?
            summary['paused'] = true
            summary['paused_at'] = Time.now.utc.iso8601
            summary['not_run'] = summary['total'] -
              summary['passed'] - summary['exported'] - summary['failed']
            persist_summary(summary)
            return summary
          end
          if @max_jobs && attempted >= @max_jobs
            summary['not_run'] += 1
            next
          end
          result_path = cell_result_path(source_id, cell)
          assert_source_tree_unchanged!
          prior = resumable_result(
            result_path, source_sha256, cell, @source_tree_sha256
          )
          if prior
            if prior['status'] == 'PASS'
              summary['passed'] += 1
            else
              summary['exported'] += 1
            end
            summary['resumed'] += 1
            summary['results'] << compact_result(prior, result_path)
            next
          end
          attempted += 1
          result = run_cell(
            pdf_path, relative, source_sha256, source_id, cell
          )
          if result['status'] == 'PASS'
            summary['passed'] += 1
          elsif result['status'] == 'EXPORTED'
            summary['exported'] += 1
          else
            summary['failed'] += 1
          end
          summary['results'] << compact_result(result, result_path)
          persist_summary(summary)
        end
      end
      summary['completed_at'] = Time.now.utc.iso8601
      persist_summary(summary)
      summary
    end

    private

    def relative_path(pdf_path)
      pdf_path.sub(
        /\A#{Regexp.escape(@corpus_root)}[\\\/]?/i, ''
      )
    end

    def cell_directory(source_id, cell)
      File.join(
        @evidence_root, 'cells', source_id,
        "#{cell.fetch('import_mode')}--#{cell.fetch('text_mode')}"
      )
    end

    def cell_result_path(source_id, cell)
      File.join(cell_directory(source_id, cell), 'cell_result.json')
    end

    def compact_result(result, result_path)
      {
        'status' => result['status'],
        'source_pdf_relative_path' => result['source_pdf_relative_path'],
        'source_pdf_sha256' => result['source_pdf_sha256'],
        'import_mode' => result['import_mode'],
        'text_mode' => result['text_mode'],
        'started_at' => result['started_at'],
        'completed_at' => result['completed_at'],
        'elapsed_seconds' => result['elapsed_seconds'],
        'skp_export_only' => result['skp_export_only'],
        'source_tree_sha256' => result['source_tree_sha256'],
        'cell_result_path' => File.expand_path(result_path)
      }
    end

    def pause_requested?
      !@pause_file.empty? && File.file?(@pause_file)
    end

    def resumable_result(path, source_sha256, cell, source_tree_sha256)
      return nil unless File.file?(path)
      parsed = JSON.parse(File.read(path, :encoding => 'UTF-8'))
      expected_status = @skp_export_only ? 'EXPORTED' : 'PASS'
      return nil unless parsed['status'] == expected_status
      return nil unless parsed['source_pdf_sha256'] == source_sha256
      return nil unless parsed['import_mode'] == cell['import_mode']
      return nil unless parsed['text_mode'] == cell['text_mode']
      return nil unless parsed['source_tree_sha256'] == source_tree_sha256
      recorded_export_only = if parsed.key?('skp_export_only')
                               parsed['skp_export_only']
                             elsif parsed['host_result'].is_a?(Hash)
                               parsed['host_result']['skp_export_only']
                             end
      return nil unless recorded_export_only == @skp_export_only
      acceptance_path = parsed['host_acceptance_path'].to_s
      acceptance_sha256 = parsed['host_acceptance_sha256'].to_s
      return nil unless File.file?(acceptance_path)
      return nil unless acceptance_sha256 =~ /\A[0-9a-f]{64}\z/
      return nil unless Digest::SHA256.file(acceptance_path).hexdigest ==
                        acceptance_sha256
      acceptance = JSON.parse(File.read(acceptance_path, :encoding => 'UTF-8'))
      return nil unless acceptance['status'] == 'OK'
      return nil unless acceptance['skp_export_only'] == @skp_export_only
      requested_mode = cell['import_mode'] == 'raster' ?
        'raster' : cell['text_mode']
      return nil unless acceptance['requested_text_mode'] == requested_mode
      return nil unless acceptance['source_pdf_sha256'] == source_sha256
      return nil unless acceptance['original_pdf_sha256'] == source_sha256
      return nil unless acceptance['immutable_pdf_sha256'] == source_sha256
      return nil unless verified_artifact_reference?(
        acceptance['original_pdf_path'], acceptance['original_pdf_sha256']
      )
      return nil unless verified_artifact_reference?(
        acceptance['immutable_pdf_path'], acceptance['immutable_pdf_sha256']
      )
      return nil unless verified_artifact_reference?(
        acceptance['normalized_pdf_path'], acceptance['normalized_pdf_sha256']
      )
      if source_tree_sha256
        return nil unless acceptance['source_tree_sha256_before_load'] ==
                          source_tree_sha256
        return nil unless acceptance['source_tree_sha256_after_import'] ==
                          source_tree_sha256
      end
      return nil unless verified_artifact_reference?(
        acceptance['model_path'], acceptance['model_sha256']
      )
      return nil unless verified_artifact_reference?(
        acceptance['import_report_path'], acceptance['import_report_sha256']
      )
      unless @skp_export_only
        return nil unless verified_artifact_reference?(
          acceptance['entity_manifest_path'],
          acceptance['entity_manifest_sha256']
        )
      end
      return nil unless resumable_report_valid?(
        acceptance, requested_mode, source_sha256, source_tree_sha256
      )
      return nil unless @skp_export_only || resumable_manifest_valid?(
        acceptance, requested_mode, source_sha256, source_tree_sha256
      )
      parsed
    rescue StandardError
      nil
    end

    def verified_artifact_reference?(path, sha256)
      return false unless sha256.to_s =~ /\A[0-9a-f]{64}\z/
      expanded = File.expand_path(path.to_s)
      File.file?(expanded) && File.size(expanded).to_i > 0 &&
        Digest::SHA256.file(expanded).hexdigest == sha256
    rescue StandardError
      false
    end

    def resumable_report_valid?(acceptance, requested_mode, source_sha256,
                                source_tree_sha256)
      report = JSON.parse(File.read(
        acceptance['import_report_path'], :encoding => 'UTF-8'
      ))
      input = report['input']
      extra = report['extra']
      return false unless input.is_a?(Hash) && extra.is_a?(Hash)
      return false unless input['sha256'] == source_sha256
      return false unless extra['requested_text_mode'] == requested_mode
      return false unless extra['source_lineage'] ==
                          acceptance_lineage(acceptance)
      if source_tree_sha256
        return false unless extra['source_tree_sha256_before_load'] ==
                            source_tree_sha256
        return false unless extra['source_tree_sha256_after_import'] ==
                            source_tree_sha256
      end
      true
    rescue StandardError
      false
    end

    def resumable_manifest_valid?(acceptance, requested_mode, source_sha256,
                                  source_tree_sha256)
      manifest = JSON.parse(File.read(
        acceptance['entity_manifest_path'], :encoding => 'UTF-8'
      ))
      return false unless manifest['source_pdf_sha256'] == source_sha256
      return false unless manifest['source_lineage'] ==
                          acceptance_lineage(acceptance)
      if manifest.key?('requested_text_mode')
        return false unless manifest['requested_text_mode'] == requested_mode
      end
      if source_tree_sha256
        return false unless manifest['source_tree_sha256_before_load'] ==
                            source_tree_sha256
        return false unless manifest['source_tree_sha256_after_import'] ==
                            source_tree_sha256
      end
      true
    rescue StandardError
      false
    end

    def acceptance_lineage(acceptance)
      {
        'original_pdf_path' => acceptance['original_pdf_path'],
        'original_pdf_sha256' => acceptance['original_pdf_sha256'],
        'immutable_pdf_path' => acceptance['immutable_pdf_path'],
        'immutable_pdf_sha256' => acceptance['immutable_pdf_sha256'],
        'normalized_pdf_path' => acceptance['normalized_pdf_path'],
        'normalized_pdf_sha256' => acceptance['normalized_pdf_sha256'],
        'salvage_note' => acceptance['salvage_note']
      }
    end

    def run_cell(pdf_path, relative, source_sha256, source_id, cell)
      output_dir = cell_directory(source_id, cell)
      FileUtils.mkdir_p(output_dir)
      job_path = File.join(output_dir, 'host_job.json')
      job = {
        'pdf_path' => pdf_path,
        'original_pdf_path' => pdf_path,
        'original_pdf_sha256' => source_sha256,
        'output_dir' => output_dir,
        'text_mode' => cell.fetch('text_mode'),
        'import_mode' => cell.fetch('import_mode'),
        'pages' => 'all',
        'skp_export_only' => @skp_export_only,
        'source_tree_sha256' => @source_tree_sha256
      }
      SketchupFullCorpusSweep.atomic_write_json(job_path, job)
      before_sha256 = Digest::SHA256.file(pdf_path).hexdigest
      raise 'source PDF changed before host execution' unless
        before_sha256 == source_sha256
      assert_source_tree_unchanged!
      started = Time.now
      host_result = @launcher.call(job_path)
      acceptance_path = File.join(output_dir, 'host_acceptance.json')
      SketchupFullCorpusSweep.atomic_write_json(acceptance_path, host_result)
      acceptance_sha256 = Digest::SHA256.file(acceptance_path).hexdigest
      after_sha256 = Digest::SHA256.file(pdf_path).hexdigest
      raise 'source PDF changed during host execution' unless
        after_sha256 == source_sha256
      assert_source_tree_unchanged!
      result = {
        'schema' => 'bcs.sketchup_full_corpus_cell/1.2',
        'status' => if host_result['status'] == 'OK'
                      @skp_export_only ? 'EXPORTED' : 'PASS'
                    else
                      'FAIL'
                    end,
        'source_pdf_relative_path' => relative,
        'source_pdf_path' => pdf_path,
        'source_pdf_sha256' => source_sha256,
        'import_mode' => cell.fetch('import_mode'),
        'text_mode' => cell.fetch('text_mode'),
        'started_at' => started.utc.iso8601,
        'completed_at' => Time.now.utc.iso8601,
        'elapsed_seconds' => (Time.now - started).round(3),
        'skp_export_only' => @skp_export_only,
        'source_tree_sha256' => @source_tree_sha256,
        'host_acceptance_path' => File.expand_path(acceptance_path),
        'host_acceptance_sha256' => acceptance_sha256,
        'host_acceptance_bytes' => File.size(acceptance_path),
        'host_result_summary' => compact_host_result(host_result)
      }
      result_path = cell_result_path(source_id, cell)
      SketchupFullCorpusSweep.atomic_write_json(result_path, result)
      if result['status'] != 'FAIL' && !resumable_result(
        result_path, source_sha256, cell, @source_tree_sha256
      )
        result['status'] = 'FAIL'
        result['error'] =
          'host returned OK without complete hash-bound acceptance artifacts'
        SketchupFullCorpusSweep.atomic_write_json(result_path, result)
      end
      result
    rescue Exception => error
      result = {
        'schema' => 'bcs.sketchup_full_corpus_cell/1.1',
        'status' => 'FAIL',
        'source_pdf_relative_path' => relative,
        'source_pdf_path' => pdf_path,
        'source_pdf_sha256' => source_sha256,
        'import_mode' => cell.fetch('import_mode'),
        'text_mode' => cell.fetch('text_mode'),
        'skp_export_only' => @skp_export_only,
        'source_tree_sha256' => @source_tree_sha256,
        'completed_at' => Time.now.utc.iso8601,
        'error' => "#{error.class}: #{error.message}",
        'backtrace' => Array(error.backtrace)
      }
      SketchupFullCorpusSweep.atomic_write_json(
        cell_result_path(source_id, cell), result
      )
      result
    end

    def compact_host_result(host_result)
      keys = %w[
        status error host_version importer_version requested_text_mode
        effective_text_mode model_path model_sha256 report_path report_sha256
        entity_manifest_path entity_manifest_sha256
        reopen_persistent_id_verified host_heal_preservation_verified
        representation_contract_ready skp_export_only
        source_pdf_sha256 original_pdf_sha256 immutable_pdf_sha256
        source_tree_sha256_before_load source_tree_sha256_after_import
      ]
      keys.each_with_object({}) do |key, summary|
        value = host_result[key]
        summary[key] = value if value.nil? || value.is_a?(String) ||
                                value.is_a?(Numeric) || value == true ||
                                value == false
      end
    end

    def persist_summary(summary)
      SketchupFullCorpusSweep.atomic_write_json(
        File.join(@evidence_root, 'full_sweep_summary.latest.json'),
        summary
      )
    end

    def assert_source_tree_unchanged!
      current = SketchupFullCorpusSweep.source_tree_sha256(@source_root)
      return true if current == @source_tree_sha256
      raise 'importer source tree changed during sweep; refusing mixed-build evidence'
    end

    def launch_host_job(job_path)
      options = {}
      options[:sketchup_exe] = @sketchup_exe unless @sketchup_exe.empty?
      options[:source_root] = @source_root unless @source_root.empty?
      SketchupHostLauncher.run(job_path, options)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    :corpus_root =>
      'C:/Users/Rowdy Payton/Desktop/PDFTest Files',
    :evidence_root =>
      'C:/Users/Rowdy Payton/Desktop/PDFTest Files/Imported Evidence/' \
      'SketchUp/full-corpus-host-sweep',
    :import_modes => SketchupFullCorpusSweep::IMPORT_MODES,
    :text_modes => SketchupFullCorpusSweep::TEXT_MODES,
    :skp_export_only => false,
    :source_root => SketchupFullCorpusSweep.default_source_root
  }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby tools/sketchup_full_corpus_sweep.rb [options]'
    opts.on('--corpus DIR', 'PDF corpus root') do |value|
      options[:corpus_root] = value
    end
    opts.on('--evidence DIR', 'Evidence output root') do |value|
      options[:evidence_root] = value
    end
    opts.on('--import-mode MODE', 'Repeat to select import modes') do |value|
      options[:import_modes] = [] if
        options[:import_modes] == SketchupFullCorpusSweep::IMPORT_MODES
      options[:import_modes] << value
    end
    opts.on('--text-mode MODE', 'Repeat to select representations') do |value|
      options[:text_modes] = [] if
        options[:text_modes] == SketchupFullCorpusSweep::TEXT_MODES
      options[:text_modes] << value
    end
    opts.on('--max-jobs COUNT', Integer, 'Bound new host jobs') do |value|
      options[:max_jobs] = value
    end
    opts.on('--full-verification', 'Include entity/reopen verification') do
      options[:skp_export_only] = false
    end
    opts.on('--export-only', 'Save diagnostic SKP without release acceptance') do
      options[:skp_export_only] = true
    end
    opts.on('--pause-file PATH', 'Stop safely between host cells when present') do |value|
      options[:pause_file] = value
    end
    opts.on('--sketchup-exe PATH', 'SketchUp executable') do |value|
      options[:sketchup_exe] = value
    end
    opts.on('--source-root DIR', 'Importer source/install root') do |value|
      options[:source_root] = value
    end
  end
  parser.parse!(ARGV)
  invalid_import_modes =
    options[:import_modes] - SketchupFullCorpusSweep::IMPORT_MODES
  invalid_text_modes =
    options[:text_modes] - SketchupFullCorpusSweep::TEXT_MODES
  unless invalid_import_modes.empty? && invalid_text_modes.empty?
    warn "ERROR: unsupported modes: " \
      "#{(invalid_import_modes + invalid_text_modes).join(', ')}"
    exit 2
  end
  summary = SketchupFullCorpusSweep::Runner.new(options).run
  puts JSON.pretty_generate(
    summary.reject { |key, _value| key == 'results' }
  )
  exit SketchupFullCorpusSweep.exit_code(summary)
end
