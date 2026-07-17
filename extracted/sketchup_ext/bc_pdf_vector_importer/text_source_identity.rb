# bc_pdf_vector_importer/text_source_identity.rb
#
# Deterministic source-span identity for text items (corrective design
# 2026-07-12 §1 / RB-01).
#
# The import pipeline calls TextSourceIdentity.assign! exactly ONCE per page,
# after final extractor selection, merging, and angle-hint replacement, but
# BEFORE stats[:page_text_map] is built and before GeometryBuilder consumes
# the array. Both PartsBootstrap (row span_ids) and
# GeometryBuilder#record_text_span_provenance (provenance span_id) then emit
# the SAME "text_span:<page>:<final-page-item-index>" string, so the
# parts_bootstrap and source_provenance sidecars join deterministically.
# Ruby memory identity (object_id) is nondeterministic and must never be used
# as a join key.
#
# Ruby 2.2 safe (SketchUp Make 2017 host, RB22).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module TextSourceIdentity
      module_function

      class IdentityError < StandardError; end

      # Assign "text_span:<page>:<index>" to each item's source_span_id,
      # where <index> is the item's position in the FINAL per-page array.
      # Mutates the items in place and returns the same array so the exact
      # objects flow on to PartsBootstrap and GeometryBuilder.
      def assign!(items, page_number)
        raise IdentityError, 'text source collection must be an Array' unless items.is_a?(Array)
        page = page_number.to_i
        raise IdentityError, 'text source page must be positive' unless page > 0

        # Prove the entire page can carry a readable/writable identity before
        # mutating any item.  A malformed later item must not leave an earlier
        # item with a partially committed source ledger.
        items.each_with_index do |item, idx|
          unless item && item.respond_to?(:source_span_id) &&
                 item.respond_to?(:source_span_id=)
            raise IdentityError, "text item #{idx} cannot carry source identity"
          end
        end
        previous = items.map { |item| item.source_span_id }

        begin
          items.each_with_index do |item, idx|
            item.source_span_id = "text_span:#{page}:#{idx}"
          end
          validate!(items, page)
        rescue StandardError => e
          items.each_with_index do |item, idx|
            begin
              item.source_span_id = previous[idx]
            rescue StandardError
              # Preserve the original assignment/validation error. A carrier
              # whose setter cannot restore is already invalid and will abort.
            end
          end
          raise e if e.is_a?(IdentityError)
          raise IdentityError, "text source identity assignment failed: #{e.message}"
        end
        items
      end

      def validate!(items, page_number)
        raise IdentityError, 'text source collection must be an Array' unless items.is_a?(Array)
        page = page_number.to_i
        raise IdentityError, 'text source page must be positive' unless page > 0
        seen = {}
        items.each_with_index do |item, idx|
          unless item && item.respond_to?(:source_span_id)
            raise IdentityError, "text item #{idx} cannot expose source identity"
          end
          observed = item.source_span_id.to_s.strip
          expected = "text_span:#{page}:#{idx}"
          raise IdentityError, "text item #{idx} source identity mismatch" unless observed == expected
          raise IdentityError, "duplicate text source identity #{observed}" if seen.key?(observed)
          seen[observed] = true
        end
        true
      end
    end
  end
end
