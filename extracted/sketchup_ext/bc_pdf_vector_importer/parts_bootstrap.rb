# bc_pdf_vector_importer/parts_bootstrap.rb
#
# BOM row extractor — R5-2 parts_bootstrap implementation.
#
# Scans extracted text items for tabular BOM data and returns a structured
# sidecar hash conforming to bcs.parts_bootstrap/1.0. Uses the same
# BOM column heuristics as GeometryBuilder but operates offline on the
# raw text items, so it runs in the headless CLI and in-host paths equally.
#
# Output schema excerpt:
#   { schema: 'bcs.parts_bootstrap/1.0',
#     generated_at: ISO8601,
#     tables: [
#       { page: 1,
#         rows: [
#           { piece_mark: 'p1019', quantity: 2, description: 'PL1/2X8X24',
#             profile_hint: 'PL', length_in: 24.0, span_ids: ['t_0042'] }
#         ] }
#     ] }

require 'time'
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module PartsBootstrap
      SCHEMA = 'bcs.parts_bootstrap/1.0'.freeze

      BOM_HEADER_RE  = /\A(?:QUAN(?:TITY)?|MARK|DESCRIPTION|LENGTH|QTY|TOTAL\s*WT\.?|REMARKS)\z/i
      BOM_QUANTITY_RE = /\A\d{1,4}\z/
      MEMBER_RE = /\b(W|S|M|HP|WT|MT|ST|C|MC)\s?(\d{1,3})\s?[xX]\s?(\d{1,3}(?:\.\d+)?)\b|
                   \b(L)\s?(\d{1,2})\s?[xX]\s?(\d{1,2})\s?[xX]\s?([\d\/\s]+)\b|
                   \b(HSS)\s?(\d{1,2}(?:\.\d+)?)\s?[xX]\s?(\d{1,2}(?:\.\d+)?)\s?[xX]\s?([\d\/\s]+)\b|
                   \b(PIPE)\s?(\d{1,2})\s?(STD|XS|XXS)\b/xi
      PLATE_RE  = /\bPL\s*[\d\/\s]+"?\s*[xX]/i
      MARK_RE   = /\b([a-zA-Z]{0,2}\d{3,5}(?:[A-Z]{1,3}\d{0,3})?)\b/
      FEET_INCH = /(\d+)'\s*-?\s*(\d+(?:\s+\d+\/\d+|\/\d+)?(?:\.\d+)?)?\s*"?/
      FRACTION  = /(?:\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?)/

      module_function

      # Build the full sidecar hash from a hash of page_num => [text_items].
      # text_items must respond to: #text (String), #page_number (Integer),
      #   #bbox_x0 (Float), #bbox_y0 (Float), #id or #object_id (String).
      def build(pages_text_map, session_id: nil)
        tables = []
        pages_text_map.each do |page_num, items|
          rows = extract_rows(items, page_num)
          tables << { page: page_num, rows: rows } unless rows.empty?
        end

        {
          schema: SCHEMA,
          generated_at: Time.now.utc.iso8601,
          import_session_id: session_id,
          table_count: tables.length,
          row_count: tables.map { |t| t[:rows].length }.inject(0, :+),
          tables: tables
        }
      end

      # Write sidecar JSON next to [base_path] as <base>_parts_bootstrap.json.
      def write_sidecar(sidecar, base_path)
        dir  = File.dirname(base_path)
        base = File.basename(base_path, File.extname(base_path))
        out  = File.join(dir, "#{base}_parts_bootstrap.json")
        File.write(out, JSON.pretty_generate(sidecar) + "\n", encoding: 'utf-8')
        out
      rescue StandardError
        nil
      end

      # ── Private helpers ──────────────────────────────────────────────────────

      def extract_rows(items, page_num)
        return [] if items.nil? || items.empty?

        ctx = bom_context(items)
        return [] unless ctx[:active]

        # Group items into row bands by Y coordinate
        row_bands = {}
        items.each do |item|
          t = item.text.to_s.strip
          next if t.empty?
          next if t =~ BOM_HEADER_RE

          y = item.respond_to?(:bbox_y0) ? item.bbox_y0.to_f : 0.0
          next unless ctx[:y0] && ctx[:y1] && y.between?(ctx[:y0], ctx[:y1])

          band = (y / 6.0).floor
          row_bands[band] ||= []
          row_bands[band] << item
        end

        rows = []
        row_bands.keys.sort.reverse_each do |band|
          band_items = row_bands[band]
          row = assemble_row(band_items, ctx, page_num)
          rows << row if row
        end
        rows
      end

      def bom_context(items)
        ctx = { active: false }
        quan_item = items.find { |it| it.text.to_s.strip =~ /\AQUAN\z/i }
        mark_item = items.find { |it| it.text.to_s.strip =~ /\AMARK\z/i }
        headers   = items.select { |it| it.text.to_s.strip =~ BOM_HEADER_RE }
        return ctx if headers.empty?

        ctx[:quan_x] = (quan_item ? quan_item.bbox_x0 : nil).to_f
        ctx[:mark_x] = (mark_item ? mark_item.bbox_x0 : nil).to_f
        anchor = quan_item ? quan_item.bbox_y0.to_f : headers.map { |h| h.bbox_y0.to_f }.max
        ctx[:y0] = anchor - 320.0
        ctx[:y1] = anchor + 12.0
        ctx[:active] = true
        ctx
      rescue StandardError
        { active: false }
      end

      def assemble_row(band_items, ctx, page_num)
        # Identify quantity cell (closest to QUAN column)
        quantity = nil
        mark_text = nil
        description = nil
        span_ids = []

        band_items.each do |item|
          t = item.text.to_s.strip
          id = item_id(item)
          span_ids << id if id

          x = item.respond_to?(:bbox_x0) ? item.bbox_x0.to_f : 0.0

          if ctx[:quan_x] && (x - ctx[:quan_x]).abs < 24.0 && t =~ BOM_QUANTITY_RE
            quantity = t.to_i
          elsif ctx[:mark_x] && (x - ctx[:mark_x]).abs < 32.0 && t =~ MARK_RE
            mark_text = t
          else
            description = [description, t].compact.join(' ')
          end
        end

        return nil unless quantity || mark_text

        desc = (description || '').strip
        {
          page: page_num,
          piece_mark: mark_text,
          quantity: quantity,
          description: desc.empty? ? nil : desc,
          profile_hint: profile_hint(desc),
          length_in: extract_length(desc),
          span_ids: span_ids.compact.uniq
        }
      rescue StandardError
        nil
      end

      def profile_hint(text)
        t = text.to_s
        return 'PL' if t =~ PLATE_RE
        return 'W'  if t =~ /\bW\d{1,3}[xX]\d/i
        return 'HSS' if t =~ /\bHSS/i
        return 'L'  if t =~ /\bL\d[xX]\d/i
        return 'C'  if t =~ /\b(C|MC)\d{1,3}[xX]/i
        return 'PIPE' if t =~ /\bPIPE/i
        nil
      end

      def extract_length(text)
        m = FEET_INCH.match(text.to_s)
        return nil unless m
        feet   = m[1].to_i
        frac   = m[2].to_s
        inches = parse_fraction(frac) || 0.0
        (feet * 12.0 + inches).round(4)
      end

      def parse_fraction(s)
        s = s.to_s.strip.gsub('"', '')
        return nil if s.empty?
        if s =~ /\A(\d+)\s+(\d+)\/(\d+)\z/
          d = Regexp.last_match(3).to_i
          return nil if d == 0
          return Regexp.last_match(1).to_i + Regexp.last_match(2).to_f / d
        end
        if s =~ /\A(\d+)\/(\d+)\z/
          d = Regexp.last_match(2).to_i
          return nil if d == 0
          return Regexp.last_match(1).to_f / d
        end
        s.to_f if s =~ /\A\d+(?:\.\d+)?\z/
      end

      def item_id(item)
        if item.respond_to?(:id) && item.id
          "t_#{item.id}"
        elsif item.respond_to?(:object_id)
          "t_#{item.object_id}"
        end
      end
    end
  end
end
