# bc_pdf_vector_importer/glyph_code_join.rb
# Binds a delivered text item to the content-stream span that drew it, so the
# recovered characters can reach the drawing.
#
# WHY THIS IS NOT THE OBVIOUS THING
#
# The obvious rule is: a delivered word's character ordinals ARE the glyph ids,
# so recover any word whose ordinals are all glyph ids the font declares a /W
# width for. That rule was measured on a real sheet before it was written, and
# it CORRUPTS THE DRAWING. It recovered 23 affected words correctly and also
# turned an RFI number "16" into "NS", a sheet number "3" into "P", and two
# detail numbers "1" into "N". The affected font declared widths for 55 glyph
# ids and that set contained 0x31 0x32 0x33 0x37 0x39 0x2d - the byte values an
# ordinary WinAnsi number is made of. The rule cannot tell "this word is glyph
# ids" from "this word is text that happens to use those bytes", and a legible
# wrong number on a shop drawing is worse than obvious garbage.
#
# So the binding is positional and it is evidence-based. The external extractor
# (Poppler pdftotext) carries no font identity in its output, but this host
# also parses the content stream itself for angle hints, and that parse knows
# exactly which spans were drawn from a font whose codes carry no meaning, what
# those codes were, and where the span was drawn. A delivered item is bound to
# such a span only when:
#
#   * the item's character ordinals equal the span's glyph ids EXACTLY, in
#     order - not a subsequence, not a prefix; and
#   * the span is within the same proximity the angle-hint join already uses;
#     and
#   * exactly ONE span qualifies. Two candidates is a refusal, not a coin toss.
#
# A word with no positioned evidence behind it is never touched. "16", "3" and
# "1" survive because no affected span was drawn where they sit, which is a
# property of the document rather than of how they happen to be spelled.
#
# Anything not bound is left exactly as delivered and is still reported by
# glyph_code_report as unproven. Recovery is all-or-nothing per item.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'glyph_code_recovery')

module BlueCollarSystems
  module PDFVectorImporter
    module GlyphCodeJoin

      module_function

      # Distance within which a delivered item and the span that drew it are
      # taken to be the same thing. Deliberately the same notion the
      # angle-hint join already uses, rather than a second opinion.
      def proximity_threshold(item)
        size = item.respond_to?(:font_size) ? item.font_size.to_f : 0.0
        size = 1.0 if size <= 0.0
        [size * 2.5, 24.0].max
      end

      def anchor(item)
        [item.x.to_f, item.y.to_f]
      rescue StandardError
        nil
      end

      # Character ordinals of a delivered item's text.
      def ordinals(text)
        return [] if text.nil?
        text.to_s.unpack('U*')
      rescue StandardError
        []
      end

      # Spans the content-stream parse recorded as drawn from a font whose
      # codes carry no meaning, keyed by their glyph-id sequence.
      def index_spans(source_items)
        index = {}
        Array(source_items).each do |candidate|
          next unless candidate.respond_to?(:glyph_code_raw)
          codes = candidate.glyph_code_raw
          next if codes.nil? || codes.to_s.empty?
          gids = GlyphCodeRecovery.glyph_ids_from_hex(codes)
          next if gids.empty?
          index[gids] ||= []
          index[gids] << candidate
        end
        index
      end

      # The one span that drew this item, or nil. Two candidates is a refusal.
      def bound_span(item, index)
        gids = ordinals(item.text)
        return nil if gids.empty?
        candidates = index[gids]
        return nil if candidates.nil? || candidates.empty?

        here = anchor(item)
        return nil if here.nil?
        threshold = proximity_threshold(item)
        limit = threshold * threshold

        near = []
        candidates.each do |candidate|
          there = anchor(candidate)
          next if there.nil?
          dx = there[0] - here[0]
          dy = there[1] - here[1]
          near << candidate if ((dx * dx) + (dy * dy)) <= limit
        end
        near.length == 1 ? near[0] : nil
      end

      # Replace the text of every delivered item that a span proves, and
      # report what happened. Returns [items, records].
      #
      # items are returned as given when nothing is proven, so a sheet with no
      # affected font pays nothing and is byte-identical.
      def apply(items, source_items, proofs)
        records = []
        return [items, records] if items.nil? || Array(items).empty?
        return [items, records] if proofs.nil? || proofs.empty?
        index = index_spans(source_items)
        return [items, records] if index.empty?

        out = Array(items).map do |item|
          next item unless item && item.respond_to?(:text)

          # An item that carries its own codes IS its own evidence - this host
          # parsed the content stream and drew that item from it, so there is
          # nothing to bind and nothing to infer. That is the strict-fidelity
          # path. Only an item delivered by an extractor that cannot say which
          # font drew it needs the positional bind below.
          own = item.respond_to?(:glyph_code_raw) ? item.glyph_code_raw : nil
          span = own.nil? || own.to_s.empty? ? bound_span(item, index) : item
          next item if span.nil?

          font = span.respond_to?(:font_name) ? span.font_name.to_s : ''
          proof = proofs[font] || proofs[font.sub(/\A\//, '')]
          next item if proof.nil?

          # The codes are the span's own, never re-derived from the delivered
          # characters: this host's text doubles every two-byte code into two
          # characters, and reading those back as glyph ids would fabricate.
          gids = GlyphCodeRecovery.glyph_ids_from_hex(span.glyph_code_raw)
          gids = ordinals(item.text) if gids.empty?
          recovered = GlyphCodeRecovery.recover_span(proof, gids)
          if recovered.nil?
            records << {
              :status => 'unproven',
              :font => font,
              :raw_codes => span.glyph_code_raw.to_s,
              :glyphs => gids.length
            }
            next item
          end

          records << {
            :status => 'recovered',
            :font => font,
            :route => recovered[1],
            :raw_codes => span.glyph_code_raw.to_s,
            :glyphs => gids.length
          }
          replace_text(item, recovered[0])
        end

        [out, records]
      rescue StandardError
        # Nothing here may cost the import. An item left as delivered is the
        # same outcome this host had before the recovery existed.
        [items, records]
      end

      # A copy carrying the recovered characters. The item's geometry,
      # identity and every other field are untouched: this changes what the
      # text SAYS, never where or how it is drawn.
      def replace_text(item, text)
        copy = item.dup
        copy.text = text
        copy
      rescue StandardError
        item
      end
    end
  end
end
