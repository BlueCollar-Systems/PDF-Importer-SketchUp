# pdf_salvage.rb -- normalize hostile PDFs before import (Round 18).
#
# The owner contract is "import any PDF file/PDF type". The internal Ruby
# parser is fast but strict: it cannot decrypt encrypted files (even the
# empty-user-password kind every viewer opens silently) and it refuses
# damaged cross-reference tables that viewers repair on the fly.
#
# Poppler can do both. When the internal parser cannot make sense of a
# file, we round-trip it through the bundled pdftocairo (-pdf) which
# re-emits a clean, decrypted, repaired PDF with the SAME vector content,
# then import that. Password-protected files (real password) still refuse,
# but with a clear message instead of a crash.
#
# Ruby 2.2 compatible (SketchUp Make 2017).

require 'tmpdir'
require 'fileutils'

module BlueCollarSystems
  module PDFVectorImporter
    module PdfSalvage
      # Raised only when the file cannot be imported at all; message is
      # user-readable and reported without a backtrace.
      class SalvageError < StandardError; end

      SALVAGE_TIMEOUT_S = 120

      class << self
        # Returns [path_to_import, note_or_nil]. Never raises for the
        # "file is fine" path; raises SalvageError only when the file is
        # genuinely unimportable (e.g. password-protected). Memoized per
        # (path, mtime, size) so the open gate and the pipeline share one
        # pdftocairo run.
        def prepare_if_needed(pdf_path)
          key = memo_key(pdf_path)
          @memo ||= {}
          cached = key ? @memo[key] : nil
          if cached
            raise SalvageError, cached[:error] if cached[:error]
            return [cached[:path], cached[:note]]
          end
          begin
            result = prepare_uncached(pdf_path)
            @memo[key] = { :path => result[0], :note => result[1] } if key
            result
          rescue SalvageError => e
            @memo[key] = { :error => e.message } if key
            raise
          end
        end

        def memo_key(pdf_path)
          st = File.stat(pdf_path)
          pdf_path.to_s + '|' + st.mtime.to_f.to_s + '|' + st.size.to_s
        rescue StandardError
          nil
        end

        def prepare_uncached(pdf_path)
          reason = needs_salvage_reason(pdf_path)
          return [pdf_path, nil] unless reason

          out = salvage_with_poppler(pdf_path, reason)
          if out
            note = "salvaged via poppler (#{reason})"
            log_info("#{File.basename(pdf_path)}: #{note}")
            return [out, note]
          end

          if reason == 'encrypted'
            raise SalvageError,
                  'This PDF is password-protected. Remove the password ' \
                  '(File > Save As in a PDF viewer with the password ' \
                  'entered) and import again.'
          end
          # Unrepairable but not encrypted: let the normal pipeline try;
          # its existing failure paths stay authoritative.
          [pdf_path, nil]
        end

        # Cheap trailer sniff; false positives only cost a salvage attempt.
        def encrypted?(pdf_path)
          raw = File.binread(pdf_path)
          i = raw.rindex('trailer')
          tail = i ? raw[i, 4096] : raw[[raw.bytesize - 4096, 0].max, 4096]
          return true if tail && tail.include?('/Encrypt')
          # xref-stream files have no classic trailer keyword
          !!(raw.index('/Encrypt') && raw.index('/Filter/Standard') ||
             raw.index('/Encrypt') && raw.index('/Filter /Standard'))
        rescue StandardError
          false
        end

        private

        def needs_salvage_reason(pdf_path)
          return 'encrypted' if encrypted?(pdf_path)
          parser = PDFParser.new(pdf_path)
          begin
            parser.parse
          rescue StandardError => e
            return "parse failed: #{e.class}"
          end
          return 'zero pages' if parser.page_count == 0
          data = begin
            parser.page_data(1)
          rescue StandardError
            nil
          end
          streams = data ? (data[:content_streams] || []) : []
          usable = false
          streams.each do |s|
            usable = true if s.is_a?(String) && !s.empty?
          end
          return 'no readable content streams' unless usable
          nil
        end

        # Track all temporary salvaged files so they can be removed at
        # process exit (CLI) and on demand (long-running SketchUp host).
        begin
          at_exit { BlueCollarSystems::PDFVectorImporter::PdfSalvage.cleanup_all }
        rescue StandardError
          # at_exit is unavailable in some embedded hosts; cleanup is still
          # available explicitly.
        end

        def salvage_with_poppler(pdf_path, reason)
          exe = begin
            DependencyResolver.find_pdftocairo
          rescue StandardError
            nil
          end
          unless exe
            log_warn("cannot salvage (#{reason}): pdftocairo unavailable")
            return nil
          end
          out = File.join(Dir.tmpdir,
                          'bc_salvaged_' + Process.pid.to_s + '_' +
                          File.basename(pdf_path))
          File.delete(out) if File.file?(out)
          ok = run_pdftocairo(exe, pdf_path, out)
          return nil unless ok && File.file?(out) && File.size(out) > 0

          check = PDFParser.new(out)
          begin
            check.parse
          rescue StandardError
            File.delete(out) if File.file?(out)
            return nil
          end
          if check.page_count > 0
            temp_salvages << out
            out
          else
            File.delete(out) if File.file?(out)
            nil
          end
        end

        public

        # Remove one salvaged temp file after the host has finished parsing.
        # Salvaged temp files created this session (never user files).
        def temp_salvages
          @temp_salvages ||= []
        end

        # MEMBERSHIP-GUARDED: a path this module did not create is
        # never deleted, so callers may pass the import path
        # unconditionally (it is usually the user's original PDF).
        def cleanup(path)
          return nil unless path.is_a?(String)
          return nil unless temp_salvages.delete(path)
          File.delete(path) if File.file?(path)
          nil
        rescue StandardError
          nil
        end

        # Remove all salvaged temp files. Safe to call on exit.
        def cleanup_all
          paths = temp_salvages.dup
          temp_salvages.clear
          paths.each do |p|
            File.delete(p) if File.file?(p)
          end
          nil
        rescue StandardError
          nil
        end

        private

        def run_pdftocairo(exe, input, output)
          if defined?(CommandRunner) && CommandRunner.respond_to?(:run)
            res = CommandRunner.run(
              [exe, '-pdf', input, output],
              :timeout_s => SALVAGE_TIMEOUT_S, :context => 'PdfSalvage')
            return !!(res && res[:ok])
          end
          system(exe, '-pdf', input, output)
        rescue StandardError => e
          log_warn("pdftocairo salvage run failed: #{e.message}")
          false
        end

        def log_info(msg)
          Logger.info('PdfSalvage', msg) if defined?(Logger) &&
                                            Logger.respond_to?(:info)
        end

        def log_warn(msg)
          Logger.warn('PdfSalvage', msg) if defined?(Logger) &&
                                            Logger.respond_to?(:warn)
        end
      end
    end
  end
end
