# bc_pdf_vector_importer/logger.rb
# Centralized logging — replaces bare rescue blocks.
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'tmpdir'
require 'fileutils'

module BlueCollarSystems
  module PDFVectorImporter
    module Logger
      @warnings = []
      @errors = []
      @debug = false
      @log_file = nil
      @log_path = nil

      def self.debug=(val); @debug = val; end
      def self.debug?; @debug; end

      def self.reset
        @warnings = []
        @errors = []
        close_log

        # Open a log file for post-session diagnosis.
        # Previous log is overwritten each import so it stays small.
        candidate_dirs = []
        begin
          candidate_dirs << File.join(Dir.tmpdir, 'bc_pdf_importer')
        rescue StandardError
          # continue with env/home fallbacks below
        end
        if ENV['LOCALAPPDATA'] && !ENV['LOCALAPPDATA'].empty?
          candidate_dirs << File.join(ENV['LOCALAPPDATA'], 'bc_pdf_importer')
        end
        if ENV['TEMP'] && !ENV['TEMP'].empty?
          candidate_dirs << File.join(ENV['TEMP'], 'bc_pdf_importer')
        end
        begin
          candidate_dirs << File.join(File.expand_path('~'), 'bc_pdf_importer_logs')
        rescue StandardError
          # ignore home expansion failure
        end

        candidate_dirs.uniq.each do |dir|
          begin
            FileUtils.mkdir_p(dir)
            path = File.join(dir, 'last_import.log')
            file = File.open(path, 'w')
            file.sync = true
            @log_file = file
            @log_path = path
            write_line("--- PDF Vector Importer log #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ---")
            write_line("[INFO] Logger: path=#{@log_path}")
            break
          rescue StandardError
            @log_file = nil
            @log_path = nil
          end
        end
      end

      def self.warn(context, msg)
        entry = "[WARN] #{context}: #{msg}"
        @warnings << entry
        puts entry if @debug
        write_line(entry)
      end

      def self.error(context, msg, exception = nil)
        entry = "[ERR] #{context}: #{msg}"
        entry += " (#{exception.class}: #{exception.message})" if exception
        @errors << entry
        puts entry if @debug
        write_line(entry)
        if exception && exception.backtrace
          bt = "  " + exception.backtrace.first(3).join("\n  ")
          puts bt if @debug
          write_line(bt)
        end
      end

      def self.info(context, msg)
        entry = "[INFO] #{context}: #{msg}"
        puts entry if @debug
        write_line(entry)
      end

      def self.flush_log
        @log_file.flush if @log_file
      rescue StandardError
        # ignore flush errors
      end

      def self.warnings; @warnings.dup; end
      def self.errors; @errors.dup; end
      def self.warning_count; @warnings.length; end
      def self.error_count; @errors.length; end

      def self.summary
        lines = []
        lines << "#{@warnings.length} warnings, #{@errors.length} errors"
        @errors.first(5).each { |e| lines << "  #{e}" }
        @warnings.first(5).each { |w| lines << "  #{w}" }
        lines.join("\n")
      end

      # Returns the path to the log file (for user diagnosis)
      def self.log_path
        @log_path
      end

      def self.write_line(entry)
        return unless @log_file
        @log_file.puts(entry)
      rescue StandardError
        @log_file = nil
      end
      private_class_method :write_line

      def self.close_log
        return unless @log_file
        begin
          @log_file.flush
        rescue StandardError
          # ignore flush errors while closing
        end
        begin
          @log_file.close unless @log_file.closed?
        rescue StandardError
          # ignore close errors
        end
      ensure
        @log_file = nil
        @log_path = nil
      end
      private_class_method :close_log
    end
  end
end
