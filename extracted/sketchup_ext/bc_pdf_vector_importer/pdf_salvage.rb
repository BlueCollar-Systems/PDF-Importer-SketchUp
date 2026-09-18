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

require 'fileutils'
require 'open3'
require 'digest'
require File.join(File.dirname(__FILE__), 'safe_temp')
require File.join(File.dirname(__FILE__), 'poppler_result_validator')

module BlueCollarSystems
  module PDFVectorImporter
    module PdfSalvage
      # Raised only when the file cannot be imported at all; message is
      # user-readable and reported without a backtrace.
      class SalvageError < StandardError; end

      SALVAGE_TIMEOUT_S = 120
      ANNOTATION_SECONDS_PER_PAGE = 5
      ANNOTATION_MAX_TIMEOUT_S = 1800

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
          source_sha256 = Digest::SHA256.file(pdf_path).hexdigest
          if valid_cached_result?(cached, source_sha256)
            return [cached[:path], cached[:note]]
          end
          @memo.delete(key) if key
          begin
            result = prepare_uncached(pdf_path)
            unless Digest::SHA256.file(pdf_path).hexdigest == source_sha256
              raise SalvageError, 'PDF changed during import preparation.'
            end
            @memo[key] = { :path => result[0], :note => result[1],
              :source_sha256 => source_sha256,
              :normalized_sha256 => Digest::SHA256.file(result[0]).hexdigest } if key
            result
          rescue SalvageError => e
            # A repaired helper or source must be retryable in the same session.
            @memo.delete(key) if key
            raise
          end
        rescue SalvageError
          raise
        rescue StandardError => error
          raise SalvageError, 'PDF preparation could not be verified: ' + error.message
        end

        def valid_cached_result?(cached, source_sha256)
          cached && cached[:source_sha256] == source_sha256 &&
            File.file?(cached[:path].to_s) &&
            Digest::SHA256.file(cached[:path]).hexdigest == cached[:normalized_sha256]
        rescue StandardError
          false
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

          if reason == 'page annotations'
            out = normalize_annotation_appearances(pdf_path)
            return [out, 'visible annotation appearances normalized as vector page content']
          end

          out = salvage_with_poppler(pdf_path, reason)
          if out
            # Cairo is a page-count recovery oracle only: its PDF output uses
            # print flags, so importing it could lose visible non-print notes.
            # Normalize the ORIGINAL source with screen visibility instead.
            begin
              inventory = PDFParser.new(out)
              inventory.parse
              normalized = normalize_annotation_appearances(pdf_path, inventory.page_count)
              note = "recovered PDF with screen-visible annotation appearances (#{reason})"
              log_info("#{File.basename(pdf_path)}: #{note}")
              return [normalized, note]
            ensure
              inventory.release if inventory
              cleanup(out)
            end
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
          begin
            return 'page annotations' if (1..parser.page_count).any? { |page| parser.page_has_annotation_appearances?(page) }
          rescue StandardError => error
            raise SalvageError, 'PDF annotation inventory could not be verified: ' + error.message
          end
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
        ensure
          parser.release if parser
        end

        # pdfwrite preserves text/vectors and image resolution. Screen flags
        # matter: pdftocairo -pdf uses print visibility and drops non-printing
        # visible notes (or exposes print-only hidden notes). Never use it here.
        def normalize_annotation_appearances(pdf_path, recovered_page_count = nil)
          exe = DependencyResolver.find_ghostscript
          raise SalvageError, 'Visible PDF annotations require the bundled Ghostscript helper; repair the importer installation.' unless exe
          before = Digest::SHA256.file(pdf_path).hexdigest
          count = recovered_page_count
          unless count
            source = PDFParser.new(pdf_path)
            source.parse
            count = source.page_count
          end
          raise SalvageError, 'Source page count was not verified.' unless count.is_a?(Integer) && count > 0
          timeout_s = annotation_timeout_s(count)
          log_info('Preserving annotation appearances for ' + count.to_s +
            ' pages; helper time limit ' + timeout_s.to_s + 's.')
          out = SafeTemp.join('bc_annotations_' + Process.pid.to_s + '_' + Time.now.to_i.to_s + '_' + rand(1_000_000).to_s + '.pdf')
          input = pdf_path
          if source
            navigation_copy = out.sub(/\.pdf\z/, '_appearance_input.pdf')
            navigation_copy_created = source.write_annotation_appearance_copy(navigation_copy)
            if navigation_copy_created
              input = navigation_copy
              navigation_copy_sha = Digest::SHA256.file(navigation_copy).hexdigest
            end
          end
          accepted = false
          args = [exe, '-q', '-dSAFER', '-dBATCH', '-dNOPAUSE', '-dPDFSTOPONERROR',
                  '-sDEVICE=pdfwrite', '-dCompatibilityLevel=1.7',
                  '-dPrinted=false', '-dPreserveAnnots=false', '-dShowAnnots=true',
                  '-dAutoRotatePages=/None', '-dDownsampleColorImages=false',
                  '-dDownsampleGrayImages=false', '-dDownsampleMonoImages=false',
                  '-sOutputFile=' + out, '-f', input]
          run = if defined?(CommandRunner) && CommandRunner.respond_to?(:run)
                  CommandRunner.run(args, :timeout_s=>timeout_s, :context=>'PdfAnnotationNormalization')
                else
                  fallback_run_pdftocairo(args)
                end
          validation = PopplerResultValidator.validate(run, :executable=>exe,
            :argv=>args, :context=>'PdfAnnotationNormalization', :attempt=>1,
            :representation=>:vector_pdf_annotation_normalization,
            :artifacts=>[out], :artifact_policy=>:all_nonempty)
          unless validation && validation[:ok]
            PopplerResultValidator.log_rejection(validation, 'PdfAnnotationNormalization')
            detail = if run && run[:timed_out]
                       'time limit of ' + timeout_s.to_s + 's reached for ' + count.to_s + ' pages'
                     else
                       'helper failed; see the import log for the exact process evidence'
                     end
            raise SalvageError, 'Could not preserve visible PDF annotations: vector normalization failed (' +
              detail + '). No incomplete import was created.'
          end
          unless run[:stderr].to_s.strip.empty? && run[:stdout].to_s.strip.empty?
            raise SalvageError, 'Annotation normalization reported a PDF/font warning; repair the reported source or helper problem before importing. ' +
              (run[:stderr].to_s + ' ' + run[:stdout].to_s).strip[0,600]
          end
          raise SalvageError, 'PDF changed during annotation normalization.' unless Digest::SHA256.file(pdf_path).hexdigest == before
          if navigation_copy_sha && Digest::SHA256.file(navigation_copy).hexdigest != navigation_copy_sha
            raise SalvageError, 'Annotation appearance preparation copy changed during normalization.'
          end
          check = PDFParser.new(out)
          check.parse
          remaining = (1..check.page_count).select { |page| check.page_has_annotations?(page) }
          unless check.page_count == count && remaining.empty?
            raise SalvageError, 'Annotation normalization did not preserve every page as complete page content ' +
              '(expected ' + count.to_s + ' pages, found ' + check.page_count.to_s +
              '; remaining annotation pages: ' + remaining.join(',') + ').'
          end
          temp_salvages << out
          accepted = true
          out
        rescue SalvageError
          raise
        rescue StandardError => error
          raise SalvageError, 'Could not preserve visible PDF annotations: ' + error.message
        ensure
          source.release if source
          check.release if check
          begin
            File.delete(out) if out && !accepted && File.file?(out)
            File.delete(navigation_copy) if navigation_copy_created && File.file?(navigation_copy)
          rescue StandardError => cleanup_error
            log_warn('Rejected annotation artifact cleanup failed: ' + cleanup_error.message)
          end
        end

        # A full-document screen normalization must preserve every page, even
        # when the operator will import only one. A fixed two-minute helper
        # budget rejected valid large drawing sets. Retain a finite upper bound
        # and the existing floor for complex single pages; no quality setting or
        # annotation/page completeness check is relaxed.
        def annotation_timeout_s(page_count)
          raise ArgumentError, 'positive verified page count required' unless
            page_count.is_a?(Integer) && page_count > 0
          [SALVAGE_TIMEOUT_S,
           [page_count * ANNOTATION_SECONDS_PER_PAGE, ANNOTATION_MAX_TIMEOUT_S].min].max
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
          # SafeTemp root AND a sanitised basename: this is the pdftocairo
          # OUTPUT path, and folding the customer's own PDF filename into it
          # meant a damaged 'Détail_acier.pdf' failed salvage on a plain ASCII
          # machine -- silently, because poppler's byte-oriented fopen wrote a
          # mojibake leaf the caller then couldn't find.
          out = SafeTemp.join(
                          'bc_salvaged_' + Process.pid.to_s + '_' +
                          Time.now.to_i.to_s + '_' + rand(100000).to_s + '_' +
                          SafeTemp.ascii_component(File.basename(pdf_path), 'doc.pdf'))
          begin
            File.delete(out) if File.file?(out)
            accepted = false
            validation = run_pdftocairo(exe, pdf_path, out)
            return nil unless validation && validation[:ok]

            check = PDFParser.new(out)
            begin
              check.parse
            rescue StandardError
              return nil
            end
            return nil unless check.page_count > 0

            temp_salvages << out
            accepted = true
            out
          ensure
            begin
              File.delete(out) if !accepted && File.file?(out)
            rescue StandardError => e
              log_warn("cleanup rejected salvage artifact failed: #{e.message}")
            end
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
          @memo.delete_if { |_key, value| value[:path] == path } if @memo
          File.delete(path) if File.file?(path)
          nil
        rescue StandardError
          nil
        end

        # Remove all salvaged temp files. Safe to call on exit.
        def cleanup_all
          paths = temp_salvages.dup
          temp_salvages.clear
          @memo.delete_if { |_key, value| paths.include?(value[:path]) } if @memo
          paths.each do |p|
            File.delete(p) if File.file?(p)
          end
          nil
        rescue StandardError
          nil
        end

        private

        def run_pdftocairo(exe, input, output)
          args = [exe, '-pdf', input, output]
          if defined?(CommandRunner) && CommandRunner.respond_to?(:run)
            res = CommandRunner.run(
              args,
              :timeout_s => SALVAGE_TIMEOUT_S, :context => 'PdfSalvage')
          else
            res = fallback_run_pdftocairo(args)
          end
          validation = PopplerResultValidator.validate(
            res,
            :executable => exe,
            :argv => args,
            :context => 'PdfSalvage',
            :attempt => 1,
            :representation => :pdf_salvage,
            :artifacts => [output],
            :artifact_policy => :all_nonempty
          )
          PopplerResultValidator.log_rejection(
            validation, 'PdfSalvage'
          ) unless validation[:ok]
          validation
        rescue StandardError => e
          log_warn("pdftocairo salvage run failed: #{e.message}")
          {
            :ok => false,
            :reason => :process_failed,
            :incomplete_output => false,
            :rejection_scope => :helper_attempt,
            :evidence => {
              :executable => exe.to_s,
              :stdout => '',
              :stderr => e.message,
              :artifacts => []
            }
          }
        end

        def fallback_run_pdftocairo(args)
          stdout, stderr, status = Open3.capture3(*args)
          ok = status && status.respond_to?(:success?) && status.success?
          {
            :ok => !!ok,
            :timed_out => false,
            :exitstatus => status && status.respond_to?(:exitstatus) ?
              status.exitstatus : nil,
            :stdout => stdout.to_s,
            :stderr => stderr.to_s,
            :error => nil
          }
        rescue StandardError => e
          {
            :ok => false,
            :timed_out => false,
            :exitstatus => nil,
            :stdout => '',
            :stderr => '',
            :error => e.message
          }
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
