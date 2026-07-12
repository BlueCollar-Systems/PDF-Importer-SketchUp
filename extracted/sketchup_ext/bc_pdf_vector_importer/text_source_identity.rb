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

      # Assign "text_span:<page>:<index>" to each item's source_span_id,
      # where <index> is the item's position in the FINAL per-page array.
      # Mutates the items in place and returns the same array so the exact
      # objects flow on to PartsBootstrap and GeometryBuilder.
      def assign!(items, page_number)
        return items unless items.is_a?(Array)

        page = page_number.to_i
        items.each_with_index do |item, idx|
          next unless item && item.respond_to?(:source_span_id=)
          item.source_span_id = "text_span:#{page}:#{idx}"
        end
        items
      end
    end
  end
end
