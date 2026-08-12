#!/usr/bin/env ruby
# test/ownership_bookkeeping_test.rb
# The ownership-verification helpers were optimized because they dominate text-heavy
# imports: snapshots enumerate the WHOLE entity collection and the text paths take
# them per text item. These tests exist to prove the optimization changed only cost,
# never behavior -- the same identities, the same order, and the same ContractError
# in the same situations. Each optimized method is checked against a reference
# implementation of the code it replaced rather than against hand-written expectations,
# because "identical" is the actual requirement.

require 'minitest/autorun'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity'

class OwnershipBookkeepingTest < Minitest::Test
  RF = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
  ContractError = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError

  # Controls respond_to? precisely so the persistent_id -> entityID fallback order
  # can be exercised, including "responds but returns something unusable".
  class Ent
    def initialize(values)
      @values = values
    end

    def respond_to?(name, include_private = false)
      return true if @values.key?(name)
      super
    end

    def method_missing(name, *args)
      return @values[name] if @values.key?(name)
      super
    end

    def respond_to_missing?(name, include_private = false)
      @values.key?(name) || super
    end
  end

  def pid(value)
    Ent.new(:persistent_id => value)
  end

  # --- reference implementations of the replaced code ----------------------------

  def reference_stable_entity_id(entity)
    raise ContractError, 'entity is nil' if entity.nil?
    candidates = [[:persistent_id, 'persistent_id'], [:entityID, 'entity_id']]
    candidates.each do |method_name, prefix|
      next unless entity.respond_to?(method_name)
      raw = entity.send(method_name)
      next if raw == true || raw == false || raw.nil?
      number = raw.to_i
      next unless number > 0 && raw.to_s.strip =~ /\A\d+\z/
      return "#{prefix}:#{number}"
    end
    raise ContractError, 'entity has no positive numeric stable host identity'
  end

  def reference_created_between(before_snapshot, after_snapshot)
    before_ids = before_snapshot[:by_id].keys
    ids = after_snapshot[:by_id].keys.reject { |identity| before_ids.include?(identity) }
    ids.map { |identity| after_snapshot[:by_id][identity] }
  end

  # Every raw identity shape the host can hand back. The Integer fast path added to
  # stable_entity_id skips a to_s/strip/regex round trip, so the cases that matter
  # most here are the NON-Integer ones that must still be rejected.
  RAW_CASES = [
    1, 2, 7, 0, -3, -1, 10, 4_294_967_296, 2**40,
    true, false, nil,
    '7', ' 8 ', "\t9\n", '007', '0', '-4', '9abc', 'abc', '', '  ',
    5.0, 5.5, 0.0, -2.5, 1e3
  ].freeze

  def test_stable_entity_id_matches_reference_for_every_raw_shape
    RAW_CASES.each do |raw|
      entity = pid(raw)
      expected = begin
        reference_stable_entity_id(entity)
      rescue ContractError => e
        [:raised, e.message]
      end
      actual = begin
        RF.stable_entity_id(entity)
      rescue ContractError => e
        [:raised, e.message]
      end
      assert_equal expected, actual,
                   "stable_entity_id diverged from the replaced implementation " \
                   "for raw=#{raw.inspect} (#{raw.class})"
    end
  end

  def test_stable_entity_id_still_prefers_persistent_id_then_entity_id
    both = Ent.new(:persistent_id => 11, :entityID => 22)
    assert_equal 'persistent_id:11', RF.stable_entity_id(both)

    # persistent_id present but unusable must fall through to entityID, not raise.
    fallback = Ent.new(:persistent_id => nil, :entityID => 22)
    assert_equal 'entity_id:22', RF.stable_entity_id(fallback)

    zero_then_valid = Ent.new(:persistent_id => 0, :entityID => 5)
    assert_equal 'entity_id:5', RF.stable_entity_id(zero_then_valid)
  end

  def test_stable_entity_id_rejects_nil_entity_and_identityless_entity
    err = assert_raises(ContractError) { RF.stable_entity_id(nil) }
    assert_equal 'entity is nil', err.message

    err = assert_raises(ContractError) { RF.stable_entity_id(Ent.new({})) }
    assert_equal 'entity has no positive numeric stable host identity', err.message
  end

  # --- stable_ids: same result, same duplicate error, half the work --------------

  def test_stable_ids_preserves_order_and_content
    entities = [pid(3), pid(1), pid(2)]
    assert_equal %w[persistent_id:3 persistent_id:1 persistent_id:2],
                 RF.stable_ids(entities)
  end

  def test_stable_ids_still_raises_on_duplicate_identity_with_same_message
    entities = [pid(4), pid(4)]
    err = assert_raises(ContractError) { RF.stable_ids(entities) }
    assert_equal 'duplicate stable entity identity persistent_id:4', err.message
  end

  def test_stable_ids_handles_empty_and_nil
    assert_equal [], RF.stable_ids([])
    assert_equal [], RF.stable_ids(nil)
  end

  def test_stable_ids_propagates_identity_failure
    assert_raises(ContractError) { RF.stable_ids([pid(1), Ent.new({})]) }
  end

  # --- created_between: O(n^2) -> O(n), byte-identical result --------------------

  def build_snapshot(entities)
    RF.snapshot(entities)
  end

  def test_created_between_matches_reference_including_order
    before_entities = [pid(1), pid(2), pid(3)]
    # "after" keeps the pre-existing entities and appends new ones out of id order,
    # so a result that merely contains the right entities but sorted would fail.
    after_entities = [pid(1), pid(2), pid(3), pid(9), pid(4), pid(7)]

    before = build_snapshot(before_entities)
    after = build_snapshot(after_entities)

    expected = reference_created_between(before, after)
    actual = RF.created_between(before, after)

    assert_equal expected.length, actual.length
    assert_equal RF.stable_ids(expected), RF.stable_ids(actual)
    assert_equal %w[persistent_id:9 persistent_id:4 persistent_id:7],
                 RF.stable_ids(actual)
  end

  def test_created_between_empty_when_nothing_added
    snap = build_snapshot([pid(1), pid(2)])
    assert_equal [], RF.created_between(snap, snap)
  end

  def test_created_between_from_empty_before_returns_everything
    before = build_snapshot([])
    after = build_snapshot([pid(1), pid(2)])
    assert_equal %w[persistent_id:1 persistent_id:2],
                 RF.stable_ids(RF.created_between(before, after))
  end

  def test_created_between_ignores_entities_that_disappeared
    before = build_snapshot([pid(1), pid(2), pid(3)])
    after = build_snapshot([pid(2), pid(5)])
    assert_equal %w[persistent_id:5],
                 RF.stable_ids(RF.created_between(before, after))
  end

  # --- claimed_created_entities! must keep enforcing the same contract -----------

  def test_claimed_created_entities_rejects_preexisting_claim
    shared = pid(1)
    before = build_snapshot([shared])
    after = build_snapshot([shared, pid(2)])
    err = assert_raises(ContractError) do
      RF.claimed_created_entities!(before, after, [shared])
    end
    assert_includes err.message, 'ownership claim includes pre-existing entities'
  end

  def test_claimed_created_entities_rejects_claim_absent_from_collection
    before = build_snapshot([pid(1)])
    after = build_snapshot([pid(1), pid(2)])
    err = assert_raises(ContractError) do
      RF.claimed_created_entities!(before, after, [pid(99)])
    end
    assert_includes err.message, 'ownership claim is absent from the host collection'
  end

  def test_claimed_created_entities_accepts_a_legitimate_claim
    created = pid(2)
    before = build_snapshot([pid(1)])
    after = build_snapshot([pid(1), created])
    assert_equal [created], RF.claimed_created_entities!(before, after, [created])
  end

  # --- snapshot shape and the instrumentation -----------------------------------

  def test_snapshot_still_returns_entities_and_by_id
    entities = [pid(1), pid(2)]
    snap = RF.snapshot(entities)
    assert_equal entities, snap[:entities]
    assert_equal %w[persistent_id:1 persistent_id:2], snap[:by_id].keys
  end

  def test_snapshot_rejects_non_enumerable_collection
    err = assert_raises(ContractError) { RF.snapshot(Object.new) }
    assert_equal 'entity collection cannot be enumerated', err.message
  end

  def test_snapshot_still_raises_on_duplicate_identity_in_collection
    assert_raises(ContractError) { RF.snapshot([pid(1), pid(1)]) }
  end

  def test_bookkeeping_counters_record_collection_sizes
    RF.reset_bookkeeping_stats!
    RF.snapshot([pid(1), pid(2), pid(3)])
    RF.snapshot([pid(1), pid(2), pid(3), pid(4), pid(5)])
    stats = RF.bookkeeping_stats

    assert_equal 2, stats[:snapshot_calls]
    # The sum of collection sizes is the figure that exposes quadratic bookkeeping:
    # it grows with model size per call, not with the item being verified.
    assert_equal 8, stats[:entities_enumerated]
    assert_equal 3, stats[:first_snapshot_entities]
    assert_equal 5, stats[:last_snapshot_entities]
    assert_equal 5, stats[:max_snapshot_entities]
    assert stats[:snapshot_ms] >= 0.0
  end

  def test_bookkeeping_counters_record_diff_probes
    RF.reset_bookkeeping_stats!
    before = RF.snapshot([pid(1)])
    after = RF.snapshot([pid(1), pid(2), pid(3)])
    RF.created_between(before, after)
    stats = RF.bookkeeping_stats

    assert_equal 1, stats[:diff_calls]
    assert_equal 3, stats[:diff_probes]
  end

  def test_reset_bookkeeping_stats_clears_counters
    RF.snapshot([pid(1), pid(2)])
    RF.reset_bookkeeping_stats!
    stats = RF.bookkeeping_stats
    assert_equal 0, stats[:snapshot_calls]
    assert_equal 0, stats[:entities_enumerated]
    assert_equal 0, stats[:diff_calls]
    assert_nil stats[:first_snapshot_entities]
  end

  def test_instrumentation_never_breaks_a_snapshot
    # A counter failure must degrade to absent numbers, not a failed import.
    RF.reset_bookkeeping_stats!
    RF.instance_variable_set(:@bookkeeping_stats, :not_a_hash)
    entities = [pid(1), pid(2)]
    snap = nil
    begin
      snap = RF.snapshot(entities)
    ensure
      RF.reset_bookkeeping_stats!
    end
    assert_equal entities, snap[:entities]
  end
end
