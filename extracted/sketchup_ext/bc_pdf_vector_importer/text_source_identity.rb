# bc_pdf_vector_importer/text_source_identity.rb
#
# Deterministic source-span identity for text items (corrective design
# 2026-07-12 §1 / RB-01).
#
# The import pipeline calls TextSourceIdentity.assign_and_validate exactly
# ONCE per page, after final extractor selection, merging, and angle-hint
# replacement, but BEFORE stats[:page_text_map] is built and before
# GeometryBuilder consumes the array. Both PartsBootstrap (row span_ids) and
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

      # Assign and then audit every FINAL extracted item.  source_count is the
      # array cardinality, never the number of IDs that happened to survive
      # assignment: an extractor object with a missing/broken writer must not
      # make positive source text disappear into the zero-source contract path.
      def assign_and_validate(items, page_number)
        list = Array(items)
        page = page_number.to_i
        failures = []
        valid_ids = []
        seen = {}

        list.each_with_index do |item, idx|
          expected = "text_span:#{page}:#{idx}"
          unless item
            failures << identity_failure(page, idx, expected, 'nil_item')
            next
          end

          unless item.respond_to?(:source_span_id=)
            failures << identity_failure(
              page, idx, expected, 'source_span_id_writer_missing'
            )
            next
          end

          begin
            item.source_span_id = expected
          rescue StandardError => e
            failures << identity_failure(
              page, idx, expected, 'source_span_id_write_failed', nil, e
            )
            next
          end

          unless item.respond_to?(:source_span_id)
            failures << identity_failure(
              page, idx, expected, 'source_span_id_reader_missing'
            )
            next
          end

          actual = nil
          begin
            actual = item.source_span_id
          rescue StandardError => e
            failures << identity_failure(
              page, idx, expected, 'source_span_id_read_failed', nil, e
            )
            next
          end
          actual_text = actual.to_s.strip
          if actual_text.empty?
            failures << identity_failure(
              page, idx, expected, 'source_span_id_empty', actual_text
            )
            next
          end
          if actual_text != expected
            failures << identity_failure(
              page, idx, expected, 'source_span_id_mismatch', actual_text
            )
          end
          if seen.key?(actual_text)
            failures << identity_failure(
              page, idx, expected, 'source_span_id_duplicate', actual_text
            )
            next
          end
          seen[actual_text] = idx
          valid_ids << actual_text if actual_text == expected
        end

        {
          items: items,
          page: page,
          source_count: list.length,
          source_span_ids: valid_ids,
          failures: failures
        }
      rescue StandardError => e
        {
          items: items,
          page: page_number.to_i,
          source_count: Array(items).length,
          source_span_ids: [],
          failures: [
            identity_failure(
              page_number.to_i, nil, nil,
              'source_identity_validation_failed', nil, e
            )
          ]
        }
      end

      def identity_failure(page, index, expected, reason, actual = nil,
                           error = nil)
        entry = {
          page: page,
          index: index,
          expected_source_span_id: expected,
          reason: reason.to_s
        }
        entry[:actual_source_span_id] = actual unless actual.nil?
        if error
          entry[:error_class] = error.class.to_s
          entry[:error] = error.message.to_s
        end
        entry
      end

      def apply_result_to_stats!(stats, result)
        raise ArgumentError, 'stats must be a Hash' unless stats.is_a?(Hash)

        payload = result.is_a?(Hash) ? result : nil
        failures = []
        unless payload && payload.key?(:page) && payload.key?(:source_count) &&
               payload.key?(:source_span_ids) && payload.key?(:failures)
          payload = {} unless payload
          failures << identity_failure(
            payload[:page].to_i, nil, nil,
            'source_identity_result_invalid'
          )
        end

        page = payload[:page].to_i
        raw_count = payload[:source_count]
        count = raw_count.is_a?(Integer) && raw_count >= 0 ? raw_count : 0
        unless raw_count.is_a?(Integer) && raw_count >= 0
          failures << identity_failure(
            page, nil, nil, 'source_identity_count_invalid', raw_count
          )
        end
        failures.concat(Array(payload[:failures]))
        ids = payload[:source_span_ids]
        ids = ids.is_a?(Array) ? ids.map { |value| value.to_s.strip } : []
        expected_ids = (0...count).map do |index|
          "text_span:#{page}:#{index}"
        end
        unless payload[:source_span_ids].is_a?(Array) && ids == expected_ids &&
               ids.uniq.length == ids.length
          failures << identity_failure(
            page, nil, expected_ids,
            'source_span_id_ledger_mismatch', ids
          )
        end

        stats[:source_text_count] = stats[:source_text_count].to_i + count
        stats[:source_text_span_ids] ||= []
        unless stats[:source_text_span_ids].is_a?(Array)
          failures << identity_failure(
            page, nil, nil, 'source_span_id_ledger_not_array'
          )
          stats[:source_text_span_ids] = []
        end
        candidate_ids = stats[:source_text_span_ids] + ids
        if candidate_ids.uniq.length != candidate_ids.length
          failures << identity_failure(
            page, nil, nil, 'source_span_id_ledger_duplicate', ids
          )
        end
        stats[:source_text_span_ids].concat(ids) if failures.empty?
        stats[:source_text_identity_failures] ||= []
        failures.each do |failure|
          stats[:source_text_identity_failures] << failure
        end
        stats[:source_text_identity_failure_count] =
          stats[:source_text_identity_failure_count].to_i + failures.length
        return true if failures.empty?

        stats[:import_report_failures] ||= []
        stats[:import_report_failures] << {
          stage: :source_text_identity,
          reason: "#{failures.length} final text item identity failure(s)",
          count: failures.length
        }
        false
      rescue StandardError => e
        if stats.is_a?(Hash)
          stats[:source_text_identity_failure_count] =
            stats[:source_text_identity_failure_count].to_i + 1
          stats[:source_text_identity_failures] ||= []
          stats[:source_text_identity_failures] << {
            reason: 'source_identity_stats_record_failed',
            error_class: e.class.to_s,
            error: e.message.to_s
          }
          stats[:import_report_failures] ||= []
          stats[:import_report_failures] << {
            stage: :source_text_identity,
            reason: 'source identity stats recording failed',
            count: 1
          }
        end
        false
      end
    end
  end
end
