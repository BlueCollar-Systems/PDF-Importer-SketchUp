# bc_pdf_vector_importer/glyph_code_report.rb
# Reports text this PDF delivers as raw glyph codes rather than characters.
#
# A /Type0 font with an Identity CMap and no /ToUnicode leaves the content
# stream holding glyph indices into an embedded subset, and nothing in the PDF
# says what they mean. The importer draws them anyway, because that is all the
# document gives it. The bytes are frequently printable ASCII, so what lands on
# the sheet is legible and WRONG - a member mark reads "06-3" where the drawing
# says "MS-3" - and no scan for control characters finds it.
#
# This module changes nothing about what is drawn. It names the fonts, counts
# the affected items, records the codes exactly as the content stream carried
# them, and says so once, loudly, so the operator knows which strings on that
# sheet cannot be trusted.
#
# What it deliberately does NOT do:
#
# * It does not fire on "no /ToUnicode". Plenty of fonts carry none and decode
#   perfectly, because WinAnsi and MacRoman are real encodings. Measured on 120
#   corpus sheets: 297 fonts on page 1, 4 affected, and 155 that have no
#   /ToUnicode and are correctly left alone.
# * It does not scan the delivered text for control characters. That check
#   misses exactly the spans that read as plausible, which are the dangerous
#   ones. The verdict comes from the PDF's own font dictionaries.
# * It does not recover the characters. Recovering them needs the embedded
#   subset's outlines compared against a reference face, which is its own
#   change; on the measured sheet the subset carries neither a cmap nor a post
#   table, so nothing cheaper can succeed.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module GlyphCodeReport

      SCHEMA = 'bcs.text_glyph_codes/1.0'.freeze

      # Per-item records are only available when this host parsed the content
      # stream itself. Poppler's -bbox-layout output carries no font identity,
      # so on that path the fonts are named and the items are not. That is a
      # limit of the run, not something the document failed to say, and the two
      # are never reported in the same sentence.
      ATTRIBUTION_PER_ITEM = 'per_item'.freeze
      ATTRIBUTION_FONTS_ONLY = 'fonts_only'.freeze

      # A sheet of thousands of affected spans must not produce a report nobody
      # can open. The counts above the list are always complete.
      ITEM_CAP = 200

      module_function

      # One page's findings. font_rows come from
      # PDFParser#page_font_glyph_code_status; span_rows from
      # TextParser#glyph_code_spans (empty when this host did not parse).
      def page_record(page_number, font_rows, span_rows, attribution)
        affected = Array(font_rows).select do |row|
          row[:status].to_s == 'unmapped_glyph_codes'
        end
        spans = Array(span_rows)
        {
          :page_number => page_number.to_i,
          :attribution => attribution.to_s,
          :fonts => affected.map { |row| font_entry(row) },
          :fonts_examined => Array(font_rows).length,
          :items => spans.map { |row| item_entry(page_number, row) },
          :glyphs => spans.inject(0) { |sum, row| sum + row[:glyphs].to_i }
        }
      end

      def font_entry(row)
        {
          :resource => row[:resource].to_s,
          :base_font => row[:base_font].to_s,
          :subtype => row[:subtype].to_s,
          :encoding => row[:encoding].to_s,
          :has_to_unicode => row[:has_to_unicode] == true,
          :reason => row[:reason].to_s
        }
      end

      def item_entry(page_number, row)
        {
          :page_number => page_number.to_i,
          :font => row[:font].to_s,
          :x => row[:x].to_f,
          :y => row[:y].to_f,
          # Hex, because the bytes are frequently printable ASCII and a record
          # that printed them as text would read as if the drawing said that.
          :raw_codes => row[:raw_codes].to_s,
          :glyphs => row[:glyphs].to_i,
          :characters_drawn => row[:delivered_characters].to_i
        }
      end

      # One block for the whole import.
      def delivery_block(page_records)
        records = Array(page_records).select { |r| r.is_a?(Hash) }
        affected = records.reject { |r| Array(r[:fonts]).empty? }
        items = []
        affected.each { |r| items.concat(Array(r[:items])) }
        fonts = []
        affected.each { |r| fonts.concat(Array(r[:fonts])) }

        {
          :schema => SCHEMA,
          :pages_examined => records.length,
          :pages_affected => affected.map { |r| r[:page_number] }.sort,
          :fonts_affected => unique_fonts(fonts),
          :items_affected => items.length,
          :glyphs_affected => affected.inject(0) { |sum, r| sum + r[:glyphs].to_i },
          :attribution => overall_attribution(affected),
          :items => items[0, ITEM_CAP],
          :items_truncated => items.length > ITEM_CAP,
          :recovery_attempted => false,
          :note => 'These characters were drawn exactly as the PDF delivered ' \
                   'them. This importer does not yet recover them.'
        }
      end

      def unique_fonts(fonts)
        seen = {}
        out = []
        Array(fonts).each do |f|
          key = [f[:base_font], f[:resource], f[:encoding]].join('|')
          next if seen[key]
          seen[key] = true
          out << f
        end
        out
      end

      # A single page that could only be examined at font level makes the whole
      # import's item list incomplete, and the report has to say so.
      def overall_attribution(affected)
        return ATTRIBUTION_PER_ITEM if affected.empty?
        all_per_item = affected.all? do |r|
          r[:attribution].to_s == ATTRIBUTION_PER_ITEM
        end
        all_per_item ? ATTRIBUTION_PER_ITEM : ATTRIBUTION_FONTS_ONLY
      end

      # One line for the operator. '' when nothing was affected: a sheet whose
      # text decodes is a clean delivery and says nothing.
      def summary_line(block, see = 'See text_glyph_codes in the import report.')
        return '' unless block.is_a?(Hash)
        fonts = Array(block[:fonts_affected])
        return '' if fonts.empty?

        pages = Array(block[:pages_affected])
        names = fonts.map { |f| display_font_name(f) }.uniq
        where = pages.length == 1 ? "page #{pages[0]}" : "pages #{pages.join(', ')}"

        if block[:attribution].to_s == ATTRIBUTION_PER_ITEM
          scope = "#{block[:items_affected].to_i} text item" \
                  "#{block[:items_affected].to_i == 1 ? '' : 's'} " \
                  "(#{block[:glyphs_affected].to_i} glyph" \
                  "#{block[:glyphs_affected].to_i == 1 ? '' : 's'})"
        else
          scope = 'every text item drawn from ' \
                  "#{names.length == 1 ? 'it' : 'them'} on that page"
        end

        subject = names.length == 1 ?
          'That font carries no Unicode map' :
          'Those fonts carry no Unicode map'

        "Text on #{where} is raw glyph codes, not characters: #{scope} " \
          "from #{names.join(', ')}. #{subject}, so the characters shown are " \
          "the PDF's internal glyph numbers and are wrong - they can read as " \
          "ordinary text. Nothing was recovered. #{see}"
      end

      def display_font_name(font)
        name = font[:base_font].to_s.sub(/\A\//, '')
        name = font[:resource].to_s if name.empty?
        name.empty? ? '(unnamed font)' : name
      end
    end
  end
end
