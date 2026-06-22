# bc_pdf_vector_importer/pdf_open_gate.rb
# Open-time gate for malformed/unsupported PDFs.
#
# Mirrors the Python hosts' shared `safe_open` / PdfOpenError contract
# (FreeCAD / LibreCAD / Blender) so SketchUp refuses bad input with the
# same actionable, user-facing message instead of a Ruby traceback.
#
# This module is intentionally pure: it performs only cheap byte-level
# sniffing and returns a structured result. Logging, the SketchUp
# message box, and import_report.json recording are handled by the
# caller (see main.rb#handle_open_gate) so the gate stays headless and
# unit-testable without a SketchUp runtime.
#
# Reason codes match the Python enum: 'encrypted', 'not_a_pdf',
# 'empty_or_truncated' (plus 'file_missing' for an absent path).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module PdfOpenGate

      # User-facing sentences, one per reason code. Kept deliberately
      # short and plain so they read well in a single UI.messagebox.
      REASON_MESSAGES = {
        'file_missing'       => 'The selected file could not be found.',
        'not_a_pdf'          => 'This file is not a valid PDF.',
        'empty_or_truncated' => 'This PDF appears to be empty or truncated and cannot be imported.',
        'encrypted'          => 'This PDF is password-protected and cannot be imported. ' \
                                'Remove the password protection and try again.'
      }.freeze

      # How far into the file a conforming %PDF- header may appear.
      HEADER_SCAN_BYTES = 1024
      # Trailer / startxref live at the end of a conforming PDF.
      TAIL_SCAN_BYTES   = 4096

      module_function

      # Inspect a path and decide whether it is safe to open.
      # Returns a Hash: { ok: true } when the file looks importable, or
      # { ok: false, reason: <code>, message: <sentence> } when it should
      # be refused. Never raises.
      def inspect_path(path)
        return failure('file_missing') unless path && File.file?(path)

        size = file_size(path)
        return failure('empty_or_truncated') if size <= 0

        header = leading_bytes(path, HEADER_SCAN_BYTES)
        return failure('not_a_pdf') unless header && header.include?('%PDF-')

        return failure('encrypted') if encrypted?(path)

        return failure('empty_or_truncated') if truncated?(path)

        { ok: true, reason: nil, message: nil }
      rescue StandardError
        # A pure sniff should never abort the import on its own bugs;
        # let the normal parser path produce its own diagnostics.
        { ok: true, reason: nil, message: nil }
      end

      def message_for(reason)
        REASON_MESSAGES[reason.to_s] || 'This PDF could not be imported.'
      end

      def failure(reason)
        code = reason.to_s
        { ok: false, reason: code, message: message_for(code) }
      end

      def file_size(path)
        File.size(path)
      rescue StandardError
        0
      end

      def leading_bytes(path, count)
        File.open(path, 'rb') { |f| f.read(count) }
      rescue StandardError
        nil
      end

      def trailing_bytes(path, count)
        size = file_size(path)
        return nil if size <= 0
        offset = size > count ? size - count : 0
        File.open(path, 'rb') do |f|
          f.seek(offset)
          f.read
        end
      rescue StandardError
        nil
      end

      def chunk_at(path, offset, count)
        return nil if offset < 0
        File.open(path, 'rb') do |f|
          f.seek(offset)
          f.read(count)
        end
      rescue StandardError
        nil
      end

      # A conforming PDF records its cross-reference location with a
      # trailing `startxref` keyword. Its absence is the clearest
      # byte-level signal that the file was cut off mid-write.
      def truncated?(path)
        tail = trailing_bytes(path, TAIL_SCAN_BYTES)
        return true unless tail
        !(tail =~ /startxref/)
      end

      # Detect the trailer/xref-stream encryption dictionary without a
      # full parse. The /Encrypt entry is an indirect reference (or, more
      # rarely, an inline dict) and only appears in trailer context, so
      # scanning the tail and the startxref target is both cheap and
      # specific enough to avoid false positives from compressed content.
      def encrypted?(path)
        tail = trailing_bytes(path, TAIL_SCAN_BYTES)
        return false unless tail
        return true if mentions_encrypt?(tail)

        if tail =~ /startxref\s+(\d+)/
          chunk = chunk_at(path, $1.to_i, TAIL_SCAN_BYTES)
          return true if chunk && mentions_encrypt?(chunk)
        end
        false
      rescue StandardError
        false
      end

      def mentions_encrypt?(bytes)
        return false unless bytes
        return true if bytes =~ /\/Encrypt\s+\d+\s+\d+\s+R/
        !!(bytes =~ /\/Encrypt\s*<</)
      end

    end
  end
end
