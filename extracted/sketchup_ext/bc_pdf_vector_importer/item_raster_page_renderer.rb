# Transparent whole-page rendering for native item Images. Ruby 2.2 compatible.
require 'digest'
require File.join(File.dirname(__FILE__), 'representation_fidelity')

module BlueCollarSystems
  module PDFVectorImporter
    module ItemRasterPageRenderer
      RENDERER = 'ghostscript_transparent_page_crop'.freeze
      # PDF's standard 14 fonts need not be embedded. Only these exact built-in
      # Ghostscript font programs are accepted; a missing arbitrary font is not.
      STANDARD_FONT_PROGRAMS = {
        'Courier' => 'NimbusMonoPS-Regular', 'Courier-Bold' => 'NimbusMonoPS-Bold',
        'Courier-Oblique' => 'NimbusMonoPS-Italic', 'Courier-BoldOblique' => 'NimbusMonoPS-BoldItalic',
        'Helvetica' => 'NimbusSans-Regular', 'Helvetica-Bold' => 'NimbusSans-Bold',
        'Helvetica-Oblique' => 'NimbusSans-Italic', 'Helvetica-BoldOblique' => 'NimbusSans-BoldItalic',
        'Times-Roman' => 'NimbusRoman-Regular', 'Times-Bold' => 'NimbusRoman-Bold',
        'Times-Italic' => 'NimbusRoman-Italic', 'Times-BoldItalic' => 'NimbusRoman-BoldItalic',
        'Symbol' => 'StandardSymbolsPS', 'ZapfDingbats' => 'D050000L'
      }.freeze

      def self.arguments(executable, source, page, dpi, output)
        unless page.is_a?(Integer) && page > 0 && dpi.is_a?(Integer) && dpi > 0
          fail_contract('item Raster page and resolution must be positive integers')
        end
        [executable.to_s, '-dSAFER', '-dBATCH', '-dNOPAUSE',
         '-dPDFSTOPONWARNING', '-dPDFNOCIDFALLBACK',
         '-sDEVICE=pngalpha', "-r#{dpi}", '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
         "-dFirstPage=#{page}", "-dLastPage=#{page}", '-o', output.to_s,
         '-f', source.to_s]
      end

      def self.plan(executable, source, page, dpi, output)
        if executable.to_s.empty? || !File.file?(executable.to_s)
          fail_contract('Ghostscript transparent page renderer is unavailable; repair the importer runtime')
        end
        { :engine => :ghostscript, :renderer => RENDERER,
          :executable => executable.to_s,
          :executable_sha256 => Digest::SHA256.file(executable.to_s).hexdigest,
          :environment => environment(executable),
          :output_path => output.to_s,
          :arguments => arguments(executable, source, page, dpi, output) }
      end

      # A verified argv is insufficient if inherited GS_OPTIONS can filter text
      # or GS_DLL / GS_LIB can replace the implementation and its ROM resources.
      # These overrides are passed only to this child; the host ENV is untouched.
      def self.environment(executable, inherited = ENV)
        result = {}
        inherited.keys.each { |key| result[key] = nil if key.upcase.start_with?('GS_') }
        result['GS_OPTIONS'] = ''
        result['GS_FONTPATH'] = ''
        separator = RUBY_PLATFORM =~ /mswin|mingw|cygwin/ ? ';' : ':'
        result['GS_LIB'] = "%rom%Resource/Init/#{separator}%rom%lib/"
        result['GS_DLL'] = nil
        if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
          dll_name = File.basename(executable.to_s).downcase.include?('32') ? 'gsdll32.dll' : 'gsdll64.dll'
          dll = File.expand_path(File.join(File.dirname(executable.to_s), dll_name))
          result['GS_DLL'] = dll if File.file?(dll)
          system_root = inherited['SystemRoot'] || inherited['SYSTEMROOT']
          unless system_root.to_s.empty?
            result['PATH'] = File.join(system_root.to_s, 'System32')
          end
        end
        result
      end

      def self.ghostscript_command?(argv)
        Array(argv).map(&:to_s).include?('-sDEVICE=pngalpha')
      end

      # Exact allowlist: one original MediaBox canvas with original CropBox
      # clipping and intrinsic PDF rotation,
      # transparent RGBA device, requested DPI, and no extra PostScript code,
      # crop/fit/media overrides, or per-item rendering arguments.
      def self.verify_command!(argv, source, page, dpi)
        args = Array(argv).map(&:to_s)
        unless args.length == 16 && !args[0].empty? && !args[-3].empty? &&
               File.expand_path(args[-1]).downcase == File.expand_path(source.to_s).downcase &&
               args == arguments(args[0], args[-1], page, dpi, args[-3])
          fail_contract('item Raster Ghostscript command is not bound to one transparent MediaBox page')
        end
        true
      end

      def self.validate_result!(run, plan)
        unless run.is_a?(Hash) && run[:ok] == true && run[:exitstatus] == 0 &&
               !run[:timed_out] && run[:error].to_s.empty?
          output = run.is_a?(Hash) ? [run[:stdout], run[:stderr]].map(&:to_s).join("\n") : ''
          detail = output.each_line.find { |line| line =~ /\A\s*Error:/i }.to_s.strip
          if detail.empty? && run.is_a?(Hash)
            detail = run[:timed_out] ? 'renderer timed out' : run[:error].to_s.strip
          end
          detail = detail[0, 300]
          exit_code = run.is_a?(Hash) ? run[:exitstatus] : nil
          message = "transparent item Raster page renderer did not complete successfully (exit #{exit_code.inspect})"
          message += ": #{detail}" unless detail.empty?
          fail_contract(message)
        end
        # Do not certify a repaired, font-substituted, or otherwise warned render
        # as complete merely because the process wrote a PNG and exited zero.
        diagnostics = [run[:stdout], run[:stderr]].map(&:to_s).join("\n")
        diagnostics = diagnostics.lines.reject do |line|
          match = /\ALoading font ([^\r\n]+) \(or substitute\) from %rom%Resource\/Font\/([^\s]+)\s*\z/.match(line)
          match && STANDARD_FONT_PROGRAMS[match[1]] == match[2]
        end.join
        if diagnostics =~ /\b(?:error|warning|unrecoverable|substitut\w*|repair\w*)\b/i
          fail_contract('transparent item Raster renderer reported unverified PDF interpretation')
        end
        output = plan[:output_path].to_s
        unless File.file?(output) && File.size(output) > 0
          fail_contract('transparent item Raster page PNG is missing or empty')
        end
        true
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, message
      end

      # The one page render, started in the background while the import goes
      # on with other work, then collected when the first item needs it.
      # Same argv and environment as the synchronous CommandRunner.run; the
      # output goes to two log files in the render's own temp folder instead
      # of pipes, so nothing has to read while the import is busy. #result
      # answers in CommandRunner.run's shape, so validate_result! decides
      # exactly as before. #stop! ends the child (Esc, timeout, cleanup).
      class BackgroundRender
        POLL_SECONDS = 0.05
        STOP_WAIT_SECONDS = 5.0

        attr_reader :pid, :timeout_s, :stdout_path, :stderr_path

        def self.monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def initialize(args, environment, log_dir, timeout_s)
          cmd = Array(args).map { |value| value.to_s }
          raise ArgumentError, 'background render needs a command' if cmd.empty?
          @timeout_s = timeout_s.to_f
          @timeout_s = 180.0 unless @timeout_s > 0.0
          @stdout_path = File.join(log_dir.to_s, 'render_stdout.txt')
          @stderr_path = File.join(log_dir.to_s, 'render_stderr.txt')
          @status = nil
          @timed_out = false
          @stopped = false
          @killed = false
          @error = nil
          @started_at = self.class.monotonic
          spawn_args = environment.nil? ? cmd : [environment] + cmd
          @pid = Process.spawn(
            *spawn_args,
            :in => File::NULL,
            :out => [@stdout_path, 'w'],
            :err => [@stderr_path, 'w']
          )
        end

        def elapsed_s
          self.class.monotonic - @started_at
        end

        # Non-blocking: true once the child has exited and been reaped.
        def finished?
          return true if @status || @stopped
          reaped = Process.wait(@pid, Process::WNOHANG)
          @status = $? if reaped
          !@status.nil?
        rescue Errno::ECHILD
          @stopped = true
          @error ||= 'background render process was already reaped'
          true
        end

        def running?
          !finished?
        end

        # True once the child has exited and its exit status was collected.
        def exited?
          finished? && !@status.nil?
        end

        # Blocks until the child exits or its time is up. tick (optional) is
        # called between polls; an exception from it (Esc) stops the child
        # before it propagates.
        def wait!(tick = nil)
          until finished?
            if elapsed_s >= @timeout_s
              @timed_out = true
              stop!
              break
            end
            tick.call if tick
            sleep(POLL_SECONDS)
          end
          result
        rescue Exception
          stop!
          raise
        end

        # Ends the child if it is still running and reaps it. Safe to call
        # more than once.
        def stop!
          return true if finished?
          # Windows may report a killed child with exit code 0; a stopped
          # render is never a successful one.
          @killed = true
          @error ||= 'background render was stopped before it finished'
          begin
            Process.kill('KILL', @pid)
          rescue StandardError
            nil
          end
          unless reaped_within?(STOP_WAIT_SECONDS)
            kill_tree!
            reaped_within?(STOP_WAIT_SECONDS)
          end
          @stopped = true
          true
        end

        def result
          ok = !@timed_out && !@killed && @status &&
            @status.respond_to?(:success?) && @status.success?
          {
            :ok => ok ? true : false,
            :timed_out => @timed_out,
            :exitstatus => @status && @status.respond_to?(:exitstatus) ?
              @status.exitstatus : nil,
            :stdout => read_log(@stdout_path),
            :stderr => read_log(@stderr_path),
            :error => @timed_out ? nil : (ok ? nil : @error)
          }
        end

        private

        def reaped_within?(seconds)
          deadline = self.class.monotonic + seconds
          until finished?
            return false if self.class.monotonic >= deadline
            sleep(POLL_SECONDS)
          end
          true
        end

        def kill_tree!
          if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
            system('taskkill', '/PID', @pid.to_s, '/T', '/F',
                   :out => File::NULL, :err => File::NULL)
          else
            Process.kill('KILL', @pid)
          end
        rescue StandardError
          nil
        end

        def read_log(path)
          return '' unless File.file?(path)
          text = File.binread(path)
          text.force_encoding(Encoding::UTF_8)
          text = text.scrub('?') unless text.valid_encoding?
          text
        rescue StandardError
          ''
        end
      end
    end
  end
end
