# outcome_accounting.rb — Binding outcome accounting (Ruby parity with pdfcadcore).
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.
#
# Phase 1 of the Auto fidelity design: the record shape and the six laws that stop
# a *picture of a page* being reported as *the editable representation the user
# asked for*. No page scanning, no routing, no rendering lives here.
#
# The motivating defect is already in the record: 278 certification cells were
# marked PASS on a return code with no delivery evidence. That never happens by
# intent -- it happens when a roll-up folds "an artifact exists" into "the cell
# passed". Documenting axes does not prevent it; only refusing the combination
# does, which is what validate_outcome does below.
#
# Law 4 is the one that matters most: a *certified* recovery image may pass the
# visual axis while the cell still fails. That pairing is legal and expected, and
# it must survive every summary layer untouched.
#
# Parity: this is the Ruby 2.2-compatible mirror of
# PDFVectorImporter/pdfcadcore/outcome_accounting.py (FreeCAD canonical, embedded
# byte-identical in Blender and LibreCAD). Vocabulary and laws must stay identical
# across all four products or the cross-host matrix stops meaning anything.
# Written against the SketchUp 2017 Ruby 2.2 floor: this file deliberately uses
# only constructs available in that release, so none of the post-2.2 conveniences
# appear here.

module BlueCollarSystems
  module PDFVectorImporter
    module OutcomeAccounting
      SCHEMA = 'bcs.auto_outcome_accounting/1.0'.freeze

      # --- axis vocabularies -------------------------------------------------
      # Fixed tokens only. An unrecognised status is exactly how an unearned PASS
      # slips through a downstream comparison, so it is a conformance error.
      PAGE_STRATEGIES = %w(native host_proved_hybrid visual_recovery incomplete).freeze
      REPRESENTATIONS = %w(text labels 3d_text glyphs geometry raster none).freeze
      STRUCTURAL_STATUSES = %w(pass fail not_certified).freeze
      VISUAL_STATUSES = %w(pass fail unproved).freeze
      REQUESTED_REPRESENTATION_STATUSES = %w(pass fail not_applicable).freeze
      CELL_STATUSES = %w(pass fail).freeze
      VISUAL_RECOVERY_STATES = %w(absent attempted certified failed).freeze

      # The five editable rungs. Raster is excluded deliberately: requested Raster
      # is a different binding outcome that certifies through the existing Raster
      # contract (Law 5). "none" means no representation was requested at all.
      # NOTE: SketchUp spells the 3D rung "text3d" at its host boundary; this
      # shared vocabulary uses the campaign spelling "3d_text" so the four
      # products compare byte-identically. Translate at the host edge, not here.
      EDITABLE_REPRESENTATIONS = %w(text labels 3d_text glyphs geometry).freeze

      # A recovery artifact has page/source/render/placement proof -- no item
      # identities, no ladder edges. Either field appearing on a recovery record
      # means something upstream confused a picture with a delivery.
      DELIVERY_ONLY_FIELDS = %w(delivered_representation item_transitions).freeze

      REQUIRED_FIELDS = %w(
        requested_page_strategy effective_page_strategy requested_representation
        structural_status visual_status requested_representation_status
        cell_status visual_recovery
      ).freeze

      COMPLETION_RECOVERY =
        'visual recovery created; requested representation not certified'.freeze

      module_function

      # Every default is the pessimistic value: a caller that forgets an axis gets
      # fail/unproved/not_certified, never an accidental pass.
      def new_outcome(opts = {})
        {
          'schema' => SCHEMA,
          'requested_page_strategy' => opts.fetch(:requested_page_strategy, 'auto'),
          'effective_page_strategy' => opts.fetch(:effective_page_strategy, 'incomplete'),
          'requested_representation' => opts.fetch(:requested_representation, 'none'),
          'structural_status' => opts.fetch(:structural_status, 'not_certified'),
          'visual_status' => opts.fetch(:visual_status, 'unproved'),
          'requested_representation_status' =>
            opts.fetch(:requested_representation_status, 'not_applicable'),
          'cell_status' => opts.fetch(:cell_status, 'fail'),
          'visual_recovery' => opts.fetch(:visual_recovery, 'absent'),
          'native_peer_count' => opts.fetch(:native_peer_count, 0).to_i,
          'visual_proof_digest' => opts.fetch(:visual_proof_digest, '')
        }
      end

      def check_vocabulary(record)
        violations = []
        REQUIRED_FIELDS.each do |field|
          violations << "missing required field #{field}" unless record.key?(field)
        end
        pairs = [
          ['effective_page_strategy', PAGE_STRATEGIES],
          ['requested_representation', REPRESENTATIONS],
          ['structural_status', STRUCTURAL_STATUSES],
          ['visual_status', VISUAL_STATUSES],
          ['requested_representation_status', REQUESTED_REPRESENTATION_STATUSES],
          ['cell_status', CELL_STATUSES],
          ['visual_recovery', VISUAL_RECOVERY_STATES]
        ]
        pairs.each do |field, allowed|
          value = record[field]
          next if value.nil?
          next if allowed.include?(value)
          violations << "#{field}=#{value.inspect} is not one of #{allowed.join(', ')}"
        end
        violations
      end

      # Returns every law violation; an empty array means the record is legal.
      # A list (rather than an exception) lets a report writer record all the ways
      # a roll-up went wrong in one pass.
      def validate_outcome(record)
        violations = check_vocabulary(record)
        # Vocabulary is a precondition: comparing unknown tokens below would only
        # produce misleading follow-on violations.
        return violations unless violations.empty?

        strategy = record['effective_page_strategy']
        requested = record['requested_representation']
        req_status = record['requested_representation_status']
        recovery = record['visual_recovery']
        visual = record['visual_status']

        is_recovery = (strategy == 'visual_recovery')
        editable_requested = EDITABLE_REPRESENTATIONS.include?(requested)

        # --- Law 5: requested Raster is a different binding outcome ------------
        if requested == 'raster' && (is_recovery || recovery != 'absent')
          violations << 'requested_representation=raster cannot use the ' \
                        'visual_recovery label; requested Raster certifies ' \
                        'through the Raster contract (Law 5)'
        end

        if is_recovery
          # --- Law 2: recovery is not delivery ---------------------------------
          DELIVERY_ONLY_FIELDS.each do |field|
            value = record[field]
            next if value.nil?
            next if value.respond_to?(:empty?) && value.empty?
            violations << "#{field} must be absent on a visual_recovery page: a " \
                          'recovery artifact has no item identities or ladder ' \
                          'edges (Law 2)'
          end
          if req_status == 'pass'
            violations << 'requested_representation_status=pass is illegal on a ' \
                          'visual_recovery page: a page image never satisfies a ' \
                          'requested representation (Law 2)'
          end

          # --- Law 3: recovery-page axes ---------------------------------------
          if record['structural_status'] != 'not_certified'
            violations << 'structural_status must be not_certified on a ' \
                          'visual_recovery page (Law 3)'
          end
          if editable_requested && req_status != 'fail'
            violations << "requested_representation=#{requested} was requested but " \
                          "requested_representation_status=#{req_status.inspect}; it " \
                          'must be fail on a recovery page, and not_applicable only ' \
                          'when nothing editable was requested (Law 3)'
          end

          # --- Law 6: a recovery page keeps no native peers ---------------------
          if record['native_peer_count'].to_i != 0
            violations << "native_peer_count=#{record['native_peer_count']} on a " \
                          'visual_recovery page: the recovery artifact must have ' \
                          'zero native peers (Law 6)'
          end
        end

        if visual == 'pass'
          digest = record['visual_proof_digest']
          if digest.nil? || digest.to_s.empty?
            violations << 'visual_status=pass requires a candidate-bound ' \
                          'visual_proof_digest; existence, dimensions, or a return ' \
                          'code are not proof (Law 3)'
          end
          if recovery == 'failed'
            violations << 'visual_status=pass is illegal while ' \
                          'visual_recovery=failed (Law 6)'
          end
        end

        # --- Law 4: the cell conjunction, never coerced -------------------------
        if record['cell_status'] == 'pass' && derive_cell_status(record) != 'pass'
          violations << 'cell_status=pass is not supported by its axes ' \
                        "(structural=#{record['structural_status']}, " \
                        "requested_representation=#{req_status}, visual=#{visual}). " \
                        'A certified recovery artifact may pass the visual axis ' \
                        'while the cell still fails; no roll-up may coerce that to ' \
                        'PASS (Law 4)'
        end

        violations
      end

      # Law 4: a required cell passes only when structural requirements pass, the
      # requested representation was delivered through a legal certified chain, and
      # visual requirements pass. There is no "partial" and no "pass with notes" --
      # those are the shapes that let an unearned PASS survive.
      def derive_cell_status(record)
        # Stated explicitly because this is the case a summary layer is most
        # tempted to round up.
        return 'fail' if record['effective_page_strategy'] == 'visual_recovery'
        return 'fail' if record['structural_status'] != 'pass'
        unless %w(pass not_applicable).include?(record['requested_representation_status'])
          return 'fail'
        end
        return 'fail' if record['visual_status'] != 'pass'
        'pass'
      end

      # Fixed wording that cannot be misread as delivery. Part of the contract,
      # not cosmetic copy.
      def completion_class(record)
        return COMPLETION_RECOVERY if record['effective_page_strategy'] == 'visual_recovery'
        return 'requested representation delivered and certified' if derive_cell_status(record) == 'pass'
        'requested representation not certified'
      end

      # Raise when the record breaks any law, for delivery-path call sites that
      # must fail closed rather than accumulate violations.
      def assert_outcome_legal(record)
        violations = validate_outcome(record)
        return true if violations.empty?
        raise ArgumentError,
              "illegal outcome accounting record:\n  " + violations.join("\n  ")
      end
    end
  end
end
