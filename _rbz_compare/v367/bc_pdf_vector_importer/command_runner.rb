# bc_pdf_vector_importer/command_runner.rb
# Safe subprocess execution with timeout and captured output.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'open3'
require 'timeout'

module BlueCollarSystems
  module PDFVectorImporter
    module CommandRunner
      DEFAULT_TIMEOUT = 90.0

      # Run an external command safely.
      #
      # args: Array command + args (no shell).
      # opts:
      #   :timeout_s => Float seconds
      #   :context   => log context string
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
        stdout_s = ""
        stderr_s = ""
        status = nil
        timed_out = false
        error = nil

        begin
          Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
            begin
              stdin.close
            rescue StandardError
              # ignore close errors
            end

            out_thread = Thread.new { stdout.read.to_s }
            err_thread = Thread.new { stderr.read.to_s }

            begin
              Timeout.timeout(timeout_s) { status = wait_thr.value }
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
