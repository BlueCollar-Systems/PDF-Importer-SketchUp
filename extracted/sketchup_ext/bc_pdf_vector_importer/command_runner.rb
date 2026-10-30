# bc_pdf_vector_importer/command_runner.rb
# Safe subprocess execution with timeout and captured output.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'open3'
require 'timeout'
require File.join(File.dirname(__FILE__), 'safe_temp')

module BlueCollarSystems
  module PDFVectorImporter
    module CommandRunner
      DEFAULT_TIMEOUT = 90.0
      LEGACY_REAP_SECONDS = 2.0
      class CaptureWaitError < StandardError; end

      # Run an external command safely.
      #
      # args: Array command + args (no shell).
      # opts:
      #   :timeout_s => Float seconds
      #   :context   => log context string
      #   :env       => per-process String => String/nil overrides (optional)
      #
      # Returns:
      #   {
      #     ok: Boolean,
      #     timed_out: Boolean,
      #     exitstatus: Integer|nil,
      #     stdout: String,
      #     stderr: String,
      #     error: String|nil
      #   }
      def self.run(args, opts = {})
        timeout_s = (opts[:timeout_s] || DEFAULT_TIMEOUT).to_f
        timeout_s = DEFAULT_TIMEOUT if timeout_s <= 0.0
        context = (opts[:context] || "CommandRunner").to_s

        raise ArgumentError, "args must be a non-empty Array" unless args.is_a?(Array) && !args.empty?

        cmd = args.map(&:to_s)
        environment = opts[:env]
        unless environment.nil? || (environment.is_a?(Hash) && environment.all? do |key, value|
          key.is_a?(String) && (value.nil? || value.is_a?(String))
        end)
          raise ArgumentError, 'env must contain String keys and String or nil values'
        end
        if legacy_bundled_capture?(cmd)
          return run_legacy_bundled_capture(cmd, environment, timeout_s, context)
        end
        spawn_args = environment.nil? ? cmd : [environment] + cmd
        stdout_s = ""
        stderr_s = ""
        status = nil
        timed_out = false
        error = nil

        begin
          Open3.popen3(*spawn_args) do |stdin, stdout, stderr, wait_thr|
            begin
              stdin.close
            rescue StandardError
              # ignore close errors
            end

            out_thread = Thread.new { stdout.read.to_s }
            err_thread = Thread.new { stderr.read.to_s }

            begin
              # During an import the wait keeps SketchUp's window answering
              # Windows (a page render can take several seconds).
              unless wait_for_child(wait_thr, timeout_s)
                raise Timeout::Error, "command exceeded #{timeout_s}s"
              end
              status = wait_thr.value
            rescue Timeout::Error
              timed_out = true
              pid = nil
              begin
                pid = wait_thr.pid
              rescue StandardError
                pid = nil
              end
              if pid
                begin
                  if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
                    # On Windows, terminate process tree to avoid orphaned children.
                    system("taskkill", "/PID", pid.to_s, "/T", "/F",
                           out: File::NULL, err: File::NULL)
                  else
                    Process.kill("KILL", pid)
                  end
                rescue StandardError
                  begin
                    Process.kill(9, pid)
                  rescue StandardError
                    # best effort
                  end
                end
              end
              begin
                status = wait_thr.value
              rescue StandardError
                # process may already be gone
              end
            end

            begin
              stdout_s = out_thread.value
            rescue StandardError
              stdout_s = ""
            end
            begin
              stderr_s = err_thread.value
            rescue StandardError
              stderr_s = ""
            end
          end
        rescue StandardError => e
          error = e
        end

        ok = (!timed_out &&
              status &&
              status.respond_to?(:success?) &&
              status.success?)

        if timed_out
          safe_warn(context, "Command timed out after #{timeout_s.round(1)}s: #{cmd.join(' ')}")
        elsif error
          safe_warn(context, "Command launch failed: #{error.class}: #{error.message}")
        elsif !ok
          code = status && status.respond_to?(:exitstatus) ? status.exitstatus : nil
          detail = stderr_s.to_s.strip
          detail = detail.lines.first.to_s.strip unless detail.empty?
          msg = "Command failed with exit status #{code}"
          msg += " — #{detail}" unless detail.empty?
          safe_warn(context, msg)
        end

        {
          ok: !!ok,
          timed_out: timed_out,
          exitstatus: status && status.respond_to?(:exitstatus) ? status.exitstatus : nil,
          stdout: stdout_s,
          stderr: stderr_s,
          error: error ? error.message : nil
        }
      end

      # Only the three bundled native Poppler CLIs use this direct-child path.
      # SketchUp 2017's Ruby 2.2 can stall in the Open3/thread capture path even
      # when a direct spawn of the same helper completes. This does not change
      # execution or process-tree cleanup for external programs or wrappers.
      def self.legacy_bundled_capture?(cmd)
        legacy_native_runtime? && bundled_native_cli_path?(cmd.first)
      end
      private_class_method :legacy_bundled_capture?

      def self.legacy_native_runtime?
        defined?(Sketchup) && Sketchup.respond_to?(:version) &&
          Sketchup.version.to_s.split('.').first == '17' &&
          RUBY_VERSION.start_with?('2.2.') && RUBY_PLATFORM =~ /mswin|mingw/
      end
      private_class_method :legacy_native_runtime?

      def self.bundled_native_cli_path?(path)
        name = File.basename(path.to_s.tr('\\', '/')).downcase
        return false unless %w[pdftotext.exe pdffonts.exe pdftocairo.exe].include?(name)
        expected = File.expand_path(File.join(File.dirname(__FILE__), 'Library', 'bin', name))
        actual = File.expand_path(path.to_s)
        return false unless actual.tr('\\', '/').casecmp(expected.tr('\\', '/')) == 0
        return false unless File.file?(actual) && !File.symlink?(actual)
        File.realpath(actual).tr('\\', '/').casecmp(expected.tr('\\', '/')) == 0
      rescue StandardError
        false
      end
      private_class_method :bundled_native_cli_path?

      def self.capture_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      private_class_method :capture_clock

      # This call is the exclusive waiter for its Process.spawn child. On
      # Windows Ruby 2.2 retains that child's creation handle until waitpid
      # reaps it; kill(KILL, pid) uses that retained child record. Never detach,
      # globally reap, or kill after a successful reap/ECHILD.
      def self.wait_capture_child(pid, deadline, pulse = true)
        loop do
          if pulse && defined?(ImportRunControl) && ImportRunControl.respond_to?(:heartbeat!)
            ImportRunControl.heartbeat!(:external_program)
          end
          left = deadline - capture_clock
          return nil if left <= 0.0
          value = poll_capture_child(pid)
          return value if value
          sleep([left, 0.025].min)
        end
      end
      private_class_method :wait_capture_child

      def self.poll_capture_child(pid)
        value = Process.waitpid2(pid, Process::WNOHANG)
        value && value.last
      rescue SystemCallError => error
        # Ruby can discard its retained child record on any failed status
        # query, not only ECHILD. No subsequent PID-based kill is safe then.
        raise CaptureWaitError, "Native helper child wait is unverified: #{error.class}: #{error.message}"
      end
      private_class_method :poll_capture_child

      def self.terminal_capture_error?(error)
        !error.is_a?(StandardError) ||
          (defined?(ImportRunControl::ImportCancelled) && error.is_a?(ImportRunControl::ImportCancelled)) ||
          (defined?(ImportRunControl::ResumeMismatch) && error.is_a?(ImportRunControl::ResumeMismatch))
      end
      private_class_method :terminal_capture_error?

      def self.run_legacy_bundled_capture(cmd, environment, timeout_s, context)
        timeout_s = DEFAULT_TIMEOUT unless timeout_s.finite? && timeout_s > 0.0
        directory = nil
        pid = status = failure = nil
        reaped = false
        ownership_lost = false
        timed_out = false
        stdout_s = stderr_s = ''
        begin
          directory = SafeTemp.mktmpdir('bc-command-')
          out_path = File.join(directory, 'stdout.bin')
          err_path = File.join(directory, 'stderr.bin')
          flags = File::WRONLY | File::CREAT | File::EXCL | File::BINARY
          deadline = capture_clock + timeout_s
          File.open(out_path, flags) do |out_file|
            File.open(err_path, flags) do |err_file|
              # An explicit executable/argv0 pair also prevents shell parsing.
              spawn_args = [[cmd.first, cmd.first]] + cmd.drop(1)
              spawn_args.unshift(environment) if environment
              spawn_args << { :in => File::NULL, :out => out_file, :err => err_file, :close_others => true }
              pid = Process.spawn(*spawn_args)
            end
          end
          status = wait_capture_child(pid, deadline)
          reaped = !status.nil?
          timed_out = !reaped
        rescue CaptureWaitError => error
          # The retained child record is uncertain: no PID-based fallback.
          pid = nil
          ownership_lost = true
          failure = error
        rescue Exception => error
          failure = error
        ensure
          if pid && !reaped
            begin
              cleanup_deadline = capture_clock + LEGACY_REAP_SECONDS
              # Final adjacent poll: if exit won the race, reap without kill.
              # No heartbeat or other callback separates a nil poll from kill.
              status = poll_capture_child(pid)
              if status
                reaped = true
              else
                begin
                  Process.kill('KILL', pid)
                rescue Errno::ESRCH, Errno::EPERM
                  # A natural exit can win the race; verify with our waiter.
                end
                status = wait_capture_child(pid, cleanup_deadline, false)
                reaped = !status.nil?
              end
              failure ||= RuntimeError.new('Native helper did not exit within bounded cleanup; capture files retained') unless reaped
            rescue CaptureWaitError => error
              pid = nil
              ownership_lost = true
              failure ||= error
            rescue StandardError => error
              failure ||= error
            end
          end
          if directory
            begin
              if (pid.nil? && !ownership_lost) || reaped
                stdout_s = File.binread(out_path) if out_path && File.file?(out_path)
                stderr_s = File.binread(err_path) if err_path && File.file?(err_path)
                # Delete only our two files and the now-empty owned directory.
                [out_path, err_path].compact.each { |path| File.delete(path) if File.exist?(path) }
                Dir.rmdir(directory)
              end
            rescue StandardError => error
              failure ||= error
            end
          end
        end
        retained = directory && !reaped && (pid || ownership_lost)
        safe_warn(context, "Native helper exit is unverified; capture files retained at #{directory}") if retained
        raise failure if failure && terminal_capture_error?(failure)
        ok = !timed_out && !failure && status && status.success?
        if timed_out
          safe_warn(context, "Command timed out after #{timeout_s.round(1)}s: #{cmd.join(' ')}")
        elsif failure
          safe_warn(context, "Command launch failed: #{failure.class}: #{failure.message}")
        elsif !ok
          detail = stderr_s.to_s.strip.lines.first.to_s.strip
          # Decode only the display copy; the result retains the exact bytes.
          detail = detail.dup.force_encoding(Encoding::UTF_8).scrub
          message = "Command failed with exit status #{status && status.exitstatus}"
          message += " — #{detail}" unless detail.empty?
          safe_warn(context, message)
        end
        { :ok => !!ok, :timed_out => timed_out,
          :exitstatus => status && status.exitstatus, :stdout => stdout_s, :stderr => stderr_s,
          :error => failure ? failure.message + (retained ? "; capture files retained at #{directory}" : '') : nil }
      end
      private_class_method :run_legacy_bundled_capture

      # true when the child finished within timeout_s.
      def self.wait_for_child(wait_thr, timeout_s)
        if defined?(ImportRunControl) &&
           ImportRunControl.respond_to?(:wait_with_heartbeat)
          return ImportRunControl.wait_with_heartbeat(
            wait_thr, timeout_s, :external_program
          )
        end
        !wait_thr.join(timeout_s).nil?
      end
      private_class_method :wait_for_child

      def self.safe_warn(context, msg)
        begin
          Logger.warn(context, msg)
        rescue StandardError
          # logger might be unavailable in minimal contexts
        end
      end
      private_class_method :safe_warn
    end
  end
end
