# visual_semantics.rb — Page source semantics profile (Ruby parity with pdfcadcore).
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.
#
# WHAT THIS IS, AND WHAT IT IS NOT
# --------------------------------
# The Auto fidelity design calls for a closed-world scanner: a bounded PDF operator
# lexer that accounts for every invoked occurrence on a page, so "no unaccounted
# semantics remain" is an equality rather than the absence of a red flag. Only such
# a profile may authorise a native route.
#
# This file does NOT implement that lexer. It implements the profile record, the
# measured resource limits, and the reason-code split. It therefore always reports
# accounting_mode = 'feature_detection' and closed_world = false, and
# profile_is_native_eligible? always returns false.
#
# That distinction is the whole point. A partial scanner that reported 'complete'
# would recreate the exact defect the design exists to kill: a consumer reading
# "no problems detected" as "page fully accounted for". Absence of detected
# features is not proof of completeness, and validate_profile rejects any record
# claiming otherwise.
#
# RESOURCE LIMITS
# ---------------
# Measured, not guessed. Across 270 pages of the pinned corpus (all pages, operands
# excluded, resources walked recursively to depth 8):
#
#   metric                       p50      p99       max   old cap   new cap
#   resolved indirect objects      7      649       904       128      4096
#   decoded content bytes     154556  6590487   7329808     8 MiB    16 MiB
#   operator tokens            11902   493632    753271   1000000  unchanged
#   annotation entries             0        0         1      2048   unchanged
#
# The old object cap was exceeded 7.1x by ordinary municipal map sheets, and the old
# byte cap had 12.6% headroom. Both made a pathology guard into the binding
# constraint on legitimate documents. The real memory bounds are decoded content and
# the semantic worker's RSS ceiling, so these caps sit far above observed usage,
# where a pathology guard belongs.
#
# Caveat of record: the measured corpus skews to municipal/geo maps and every breach
# was on those sheets. Validate against a structural-steel corpus before freezing.
#
# Parity: Ruby mirror of PDFVectorImporter/pdfcadcore/visual_semantics.py (FreeCAD
# canonical, embedded byte-identical in Blender and LibreCAD). Vocabulary, limits and
# laws must stay identical across all four products or the cross-host matrix stops
# meaning anything. Written against the SketchUp 2017 Ruby 2.2 floor, so only
# constructs available in that release appear here.

module BlueCollarSystems
  module PDFVectorImporter
    module VisualSemantics
      SCHEMA = 'bcs.page_source_semantics/2.0'.freeze

      # --- resource limits (measured; see header) ---------------------------
      CAP_FORM_DEPTH = 8
      CAP_RESOLVED_OBJECTS = 4096            # was 128; measured max 904
      CAP_DECODED_BYTES = 16 * 1024 * 1024   # was 8 MiB; measured max ~6.99 MiB
      CAP_OPERATOR_TOKENS = 1_000_000        # unchanged; measured max 753,271
      CAP_ANNOTATIONS = 2048                 # unchanged; measured max 1

      # --- accounting modes -------------------------------------------------
      # Only CLOSED_WORLD may ever authorise a native route. This increment emits
      # the other one, always.
      ACCOUNTING_FEATURE_DETECTION = 'feature_detection'.freeze
      ACCOUNTING_CLOSED_WORLD = 'closed_world'.freeze

      # NOTE: 'complete' is deliberately absent. It belongs to the closed-world
      # scanner and must not be emitable by feature detection.
      SCAN_STATUSES = %w(partial incomplete error).freeze

      STATUS_CODES = %w(
        source_profile_partial
        semantic_scan_incomplete
        resource_budget_incomplete
        semantic_scan_error
      ).freeze

      VISIBLE_FEATURE_CODES = %w(
        pdf_shading_paint
        pdf_shading_pattern_paint
        pdf_tiling_pattern_paint
        pdf_visible_annotation_appearance
        pdf_visible_widget_appearance
        pdf_non_normal_blend
        pdf_fill_alpha
        pdf_stroke_alpha
        pdf_soft_mask_composite
        pdf_image_mask_composite
        pdf_transparency_group
        pdf_knockout_group
        pdf_type3_glyph_program
        pdf_inline_image_paint
        pdf_text_clip
        pdf_nontrivial_clip
        pdf_complex_color_space
        pdf_postscript_xobject
      ).freeze

      # Fields that would turn a source profile into a routing decision. The design
      # keeps source facts, IR capability and host proof strictly separate; a profile
      # carrying a strategy has collapsed that separation.
      ROUTING_FIELDS = %w(
        effective_strategy terminal_raster delivery_scope
        isolated_image_hybrid editable
      ).freeze

      module_function

      # Defaults are pessimistic: 'partial' accounting that cannot authorise native.
      def new_profile(opts = {})
        codes = (opts[:visible_feature_codes] || []).uniq.sort
        {
          'schema' => SCHEMA,
          'accounting_mode' => ACCOUNTING_FEATURE_DETECTION,
          'closed_world' => false,
          'page_index' => opts.fetch(:page_index, 0).to_i,
          'scan_status' => opts.fetch(:scan_status, 'partial'),
          'status_code' => opts.fetch(:status_code, 'source_profile_partial'),
          'visible_feature_codes' => codes,
          'resolved_objects' => opts.fetch(:resolved_objects, 0).to_i,
          'decoded_bytes' => opts.fetch(:decoded_bytes, 0).to_i,
          'operator_tokens' => opts.fetch(:operator_tokens, 0).to_i,
          'annotation_entries' => opts.fetch(:annotation_entries, 0).to_i,
          'limit_breaches' => (opts[:limit_breaches] || []).uniq.sort,
          'limits' => {
            'form_depth' => CAP_FORM_DEPTH,
            'resolved_objects' => CAP_RESOLVED_OBJECTS,
            'decoded_bytes' => CAP_DECODED_BYTES,
            'operator_tokens' => CAP_OPERATOR_TOKENS,
            'annotation_entries' => CAP_ANNOTATIONS
          }
        }
      end

      # Returns every conformance violation; empty means the record is legal.
      def validate_profile(profile)
        violations = []

        if profile['schema'] != SCHEMA
          violations << "schema=#{profile['schema'].inspect} is not #{SCHEMA}"
        end

        mode = profile['accounting_mode']
        if mode == ACCOUNTING_CLOSED_WORLD
          violations << 'accounting_mode=closed_world is not implementable by this ' \
                        'module: the closed operator lexer does not exist yet, and ' \
                        'claiming it would let a partial scan authorise a native route'
        elsif mode != ACCOUNTING_FEATURE_DETECTION
          violations << "accounting_mode=#{mode.inspect} is not #{ACCOUNTING_FEATURE_DETECTION}"
        end

        if profile['closed_world']
          violations << 'closed_world must be false for a feature-detection profile'
        end

        status = profile['scan_status']
        if status == 'complete'
          violations << 'scan_status=complete is reserved for the closed-world ' \
                        'scanner; feature detection cannot prove completeness ' \
                        '(absence of detected features is not proof)'
        elsif !SCAN_STATUSES.include?(status)
          violations << "scan_status=#{status.inspect} is not one of #{SCAN_STATUSES.join(', ')}"
        end

        unless STATUS_CODES.include?(profile['status_code'])
          violations << "status_code=#{profile['status_code'].inspect} is not one of " \
                        "#{STATUS_CODES.join(', ')}"
        end

        codes = profile['visible_feature_codes']
        if !codes.is_a?(Array)
          violations << 'visible_feature_codes must be an array'
        else
          codes.each do |code|
            next if VISIBLE_FEATURE_CODES.include?(code)
            violations << "unknown visible feature code #{code.inspect}"
          end
          if codes != codes.uniq.sort
            violations << 'visible_feature_codes must be sorted and unique'
          end
        end

        ROUTING_FIELDS.each do |field|
          next unless profile.key?(field)
          violations << "#{field} must not appear in a source profile: source facts, " \
                        'IR capability and host proof stay separate'
        end

        violations
      end

      # Whether this profile may authorise a native (non-recovery) route.
      #
      # Always false in this increment. Native eligibility requires closed-world
      # accounting -- every invoked occurrence classified, zero unknowns -- which
      # feature detection cannot supply. Expressed as a method rather than an
      # implicit absence so a caller cannot forget to ask.
      def profile_is_native_eligible?(profile)
        return false unless profile['accounting_mode'] == ACCOUNTING_CLOSED_WORLD
        return false unless profile['scan_status'] == 'complete'
        codes = profile['visible_feature_codes']
        codes.nil? || codes.empty?
      end

      # Flag any measured value over its cap, and mark the profile
      # resource_budget_incomplete rather than semantic_scan_incomplete. Conflating
      # the two hides limit regressions inside a semantic count, and they have
      # different remedies and different user meanings.
      def record_limit_breaches(profile)
        breaches = []
        [['resolved_objects', CAP_RESOLVED_OBJECTS],
         ['decoded_bytes', CAP_DECODED_BYTES],
         ['operator_tokens', CAP_OPERATOR_TOKENS],
         ['annotation_entries', CAP_ANNOTATIONS]].each do |key, cap|
          breaches << key if profile[key].to_i > cap
        end
        unless breaches.empty?
          profile['limit_breaches'] = breaches.uniq.sort
          profile['scan_status'] = 'incomplete'
          profile['status_code'] = 'resource_budget_incomplete'
        end
        profile
      end
    end
  end
end
