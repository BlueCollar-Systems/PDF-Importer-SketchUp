#!/usr/bin/env ruby
# frozen_string_literal: true

# Ruby parity for the binding outcome accounting laws.
#
# These mirror tests/test_outcome_accounting.py in the FreeCAD canonical repo.
# The point is not that Ruby "also has a validator" -- it is that all four
# products refuse the SAME illegal combinations, so a cross-host certification
# matrix compares like with like. A law that only FreeCAD enforces is a law the
# matrix cannot rely on.

require 'minitest/autorun'
require 'json'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/outcome_accounting'

OA = BlueCollarSystems::PDFVectorImporter::OutcomeAccounting

class OutcomeAccountingTest < Minitest::Test
  def recovery_outcome(overrides = {})
    record = OA.new_outcome(
      requested_page_strategy: 'auto',
      effective_page_strategy: 'visual_recovery',
      requested_representation: '3d_text',
      structural_status: 'not_certified',
      visual_status: 'pass',
      requested_representation_status: 'fail',
      cell_status: 'fail',
      visual_recovery: 'certified',
      native_peer_count: 0,
      visual_proof_digest: 'a' * 64
    )
    record.merge(overrides)
  end

  def native_outcome(overrides = {})
    record = OA.new_outcome(
      requested_page_strategy: 'auto',
      effective_page_strategy: 'native',
      requested_representation: '3d_text',
      structural_status: 'pass',
      visual_status: 'pass',
      requested_representation_status: 'pass',
      cell_status: 'pass',
      visual_recovery: 'absent',
      native_peer_count: 42,
      visual_proof_digest: 'b' * 64
    )
    record.merge(overrides)
  end

  # --- shape -----------------------------------------------------------------

  def test_schema_is_versioned_and_matches_python
    assert_equal 'bcs.auto_outcome_accounting/1.0', OA::SCHEMA
    assert_equal OA::SCHEMA, native_outcome['schema']
  end

  def test_legal_records_validate_clean
    assert_empty OA.validate_outcome(native_outcome)
    assert_empty OA.validate_outcome(recovery_outcome)
  end

  def test_unknown_axis_value_is_rejected
    violations = OA.validate_outcome(native_outcome('effective_page_strategy' => 'raster'))
    assert violations.any? { |v| v.include?('effective_page_strategy') }
  end

  # --- Law 2: recovery is not delivery ---------------------------------------

  def test_recovery_cannot_set_requested_representation_pass
    violations = OA.validate_outcome(
      recovery_outcome('requested_representation_status' => 'pass')
    )
    assert violations.any? { |v| v.include?('requested_representation_status') },
           'a page picture must never satisfy a requested editable representation'
  end

  def test_recovery_cannot_carry_delivery_only_fields
    %w(delivered_representation item_transitions).each do |field|
      record = recovery_outcome
      record[field] = field == 'item_transitions' ? [{ 'from' => '3d_text' }] : '3d_text'
      violations = OA.validate_outcome(record)
      assert violations.any? { |v| v.include?(field) }, "#{field} must be rejected"
    end
  end

  # --- Law 3: recovery-page axes ---------------------------------------------

  def test_recovery_forces_structural_not_certified
    violations = OA.validate_outcome(recovery_outcome('structural_status' => 'pass'))
    assert violations.any? { |v| v.include?('structural_status') }
  end

  def test_editable_request_on_recovery_page_must_fail
    OA::EDITABLE_REPRESENTATIONS.each do |mode|
      violations = OA.validate_outcome(
        recovery_outcome('requested_representation' => mode,
                         'requested_representation_status' => 'not_applicable')
      )
      assert violations.any? { |v| v.include?('not_applicable') },
             "#{mode} was requested, so the axis cannot be not_applicable"
    end
  end

  def test_not_applicable_is_legal_only_when_nothing_was_requested
    ok = recovery_outcome('requested_representation' => 'none',
                          'requested_representation_status' => 'not_applicable')
    assert_empty OA.validate_outcome(ok)
  end

  def test_visual_pass_requires_candidate_bound_proof
    violations = OA.validate_outcome(recovery_outcome('visual_proof_digest' => ''))
    assert violations.any? { |v| v.include?('visual_proof_digest') }
  end

  # --- Law 4: the cell conjunction cannot be coerced -------------------------

  def test_certified_recovery_cannot_make_the_cell_pass
    violations = OA.validate_outcome(recovery_outcome('cell_status' => 'pass'))
    assert violations.any? { |v| v.include?('cell_status') },
           'visual pass + certified recovery must not coerce a cell PASS'
  end

  def test_derive_cell_status_refuses_pass_on_recovery
    assert_equal 'fail', OA.derive_cell_status(recovery_outcome)
  end

  def test_derive_cell_status_passes_a_fully_delivered_native_page
    assert_equal 'pass', OA.derive_cell_status(native_outcome)
  end

  def test_cell_pass_requires_structural_and_visual_pass
    %w(structural_status visual_status).each do |axis|
      bad = native_outcome(axis => (axis == 'structural_status' ? 'not_certified' : 'unproved'))
      violations = OA.validate_outcome(bad)
      assert violations.any? { |v| v.include?('cell_status') }, "#{axis} must block a cell PASS"
    end
  end

  # --- Law 5: requested Raster is a different outcome ------------------------

  def test_recovery_label_is_illegal_when_raster_was_requested
    bad = recovery_outcome('requested_representation' => 'raster')
    violations = OA.validate_outcome(bad)
    assert violations.any? { |v| v.include?('raster') },
           'requested Raster certifies through the Raster contract, not visual_recovery'
  end

  # --- Law 6: failed recovery leaves no peers --------------------------------

  def test_failed_recovery_cannot_report_visual_pass
    violations = OA.validate_outcome(
      recovery_outcome('visual_recovery' => 'failed', 'visual_status' => 'pass')
    )
    assert violations.any? { |v| v.include?('visual_status') }
  end

  def test_recovery_page_cannot_retain_native_peers
    violations = OA.validate_outcome(recovery_outcome('native_peer_count' => 17))
    assert violations.any? { |v| v.include?('native_peer_count') },
           'the zero-peer law is the whole point of recovery'
  end

  # --- user-facing wording ---------------------------------------------------

  def test_recovery_wording_never_claims_delivery
    text = OA.completion_class(recovery_outcome)
    assert_equal 'visual recovery created; requested representation not certified', text
    refute_includes text, 'delivered'
  end

  def test_native_wording_reports_delivery
    assert_includes OA.completion_class(native_outcome), 'delivered'
  end

  # --- vocabulary parity with the Python canonical copy ----------------------

  def test_vocabularies_match_the_python_core
    py = File.read(
      File.expand_path(
        '../../1PDF-Importer-FreeCAD/PDFVectorImporter/pdfcadcore/outcome_accounting.py',
        __dir__
      )
    )
    { 'PAGE_STRATEGIES' => OA::PAGE_STRATEGIES,
      'REPRESENTATIONS' => OA::REPRESENTATIONS,
      'STRUCTURAL_STATUSES' => OA::STRUCTURAL_STATUSES,
      'VISUAL_STATUSES' => OA::VISUAL_STATUSES,
      'CELL_STATUSES' => OA::CELL_STATUSES,
      'VISUAL_RECOVERY_STATES' => OA::VISUAL_RECOVERY_STATES,
      'EDITABLE_REPRESENTATIONS' => OA::EDITABLE_REPRESENTATIONS }.each do |name, ruby_values|
      match = py[/^#{name} = \(([^)]*)\)/m]
      refute_nil match, "#{name} not found in the Python core"
      python_values = match.scan(/"([^"]+)"/).flatten
      assert_equal python_values, ruby_values,
                   "#{name} diverged between the Ruby port and the Python core"
    end
  end
end
