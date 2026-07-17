#!/usr/bin/env ruby
# test/mesh_text_width_fidelity_test.rb
#
# Round 22 locks — width-faithful 3D Text (condensed title-block parity).
# Owner-evidence reopen of SIZE-1's WIDTH dimension ONLY: condensed
# title-block text declares run widths at measured 0.5864..0.7996 of the
# host font's natural width (up to 1.4365 expanded), so long strings
# overlapped. The fix compresses/expands each generated run to the
# PDF-declared span extent along its PRE-ROTATION run axis (local X).
#
# The source height remains authoritative.  Delivery is certified from the
# actual host bounds after width/height fit, translation, and rotation.

require_relative 'mesh_text_scaling_test'

# Entities stub whose scaling transform raises, to lock exact owned-artifact
# cleanup when visual fidelity cannot be proven.
class ScalingRaisesEntities < DummyTransformEntities
  def transform_entities(*args)
    kind = args[0].respond_to?(:kind) ? args[0].kind : nil
    raise 'forced scaling failure' if kind == :scaling
    super
  end
end

class WidthFidelityLayerManager
  def resolve(_name); Object.new; end
  def match_pdf_layers; false; end
  def text_fallback_layer; Object.new; end
end

class MeshTextWidthFidelityTest < Minitest::Test
  RF = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
  H8 = 8.0 * PT_TO_IN            # faithful 8pt height, 0.1111..."
  RENDERED_W = H8 * 3.0          # stub add_3d_text run width = 3x height

  def place(item, ents = DummyTransformEntities.new, media = LETTER)
    b = make_builder(media)
    delivered = b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil)
    [b, ents, delivered]
  end

  def scaling_transforms(ents)
    ents.transforms.select { |args| args[0].respond_to?(:kind) && args[0].kind == :scaling }
  end

  def assert_verified_visual_bounds(builder, entities, item, origin_x = 0.0, origin_y = 0.0)
    x_pdf, y_pdf, source_angle = builder.send(:mesh_text_insertion_pdf, item)
    display_angle = builder.send(:display_text_angle, item, source_angle)
    anchor = builder.send(
      :text_point_to_su, item, x_pdf, y_pdf, origin_x, origin_y
    )
    width = builder.send(:mesh_text_declared_run_width_inches, item, display_angle)
    height = builder.send(:mesh_text_height_inches, item, display_angle, 0.0)
    expected = RF.expected_rotated_bounds(anchor, width, height, display_angle)
    actual = RF.bounds(entities.to_a)
    [:min_x, :min_y, :max_x, :max_y, :width, :height].each do |key|
      assert_in_delta expected[key], actual[key], 1.0e-8,
                      "post-transform #{key} must match the source geometry"
    end

    attempt = builder.text_attempts.fetch(0)
    assert_equal item.source_span_id, attempt[:source_span_id]
    assert_equal :text3d, attempt[:delivered_mode]
    assert attempt[:visual_fidelity_verified]
    assert attempt[:placement_verified]
    assert attempt[:rotation_verified]
    assert attempt[:width_verified]
    assert attempt[:height_verified]
  end

  # ── Wide (condensed-declared) run compressed to the declared extent ──────
  def test_wide_run_is_compressed_to_declared_span_extent
    # Declared 16.8pt run vs stub-rendered 24pt-equivalent -> factor 0.7,
    # inside the measured condensed band (0.5864..0.7996).
    item = bbox_item('STD. NOTE', 8.0, 10.0, bbox_w: 16.8)
    b, ents, delivered = place(item)

    assert delivered, 'the exact source width must be deliverable as Text3D'
    kinds = ents.transforms.map { |args| args[0].kind }
    assert_equal [:scaling, :translation], kinds,
                 'run-axis fit must happen BEFORE the placement translation'
    args = ents.transforms[0][0].args
    assert_in_delta 0.7, args[1], 1e-9, 'X factor must be declared/rendered'
    assert_equal [1.0, 1.0], args[2..3],
                 'this fixture already renders at the exact source height'

    # Height pipeline unchanged pre/post: faithful add_3d_text height and
    # recorded height samples are identical to the no-width-fit contract.
    assert_equal 1, ents.height_args.length
    assert_in_delta H8, ents.height_args[0], 1e-9
    assert_in_delta H8, b.send(:text_height_samples)[0], 1e-9
    assert_verified_visual_bounds(b, ents, item)
    assert_empty ents.erased
  end

  # ── Expanded run grows to the declared extent ─────────────────────────────
  def test_expanded_run_grows_to_declared_span_extent
    # Declared 34.475pt vs rendered 24pt -> factor ~1.4365 (measured
    # expanded case).
    item = bbox_item('ONE FRAME', 8.0, 10.0, bbox_w: 24.0 * 1.4365)
    b, ents, delivered = place(item)
    assert delivered
    args = scaling_transforms(ents)[0][0].args
    assert_in_delta 1.4365, args[1], 1e-9
    assert_equal [1.0, 1.0], args[2..3]
    assert_verified_visual_bounds(b, ents, item)
  end

  # ── Rotated run: factor along the pre-rotation run axis ──────────────────
  def test_rotated_run_scales_pre_rotation_x_from_bbox_run_extent
    # 90-degree part mark: bbox X extent 8pt (cross axis), Y extent 42pt
    # (run axis). Declared run = 42pt vs rendered 24pt -> factor 1.75.
    item = identified_text_item(
      'a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext',
      nil, 140.0, 250.0, 148.0, 292.0
    )
    b, ents, delivered = place(item)

    assert delivered
    kinds = ents.transforms.map { |args| args[0].kind }
    assert_equal [:scaling, :translation, :rotation], kinds,
                 'rotated runs must scale local X first, then move, then rotate'
    args = ents.transforms[0][0].args
    assert_in_delta 42.0 / 24.0, args[1], 1e-9,
                    'factor must use the bbox extent along the run axis'
    assert_equal [1.0, 1.0], args[2..3]
    assert_verified_visual_bounds(b, ents, item)
  end

  # Near-natural widths are still fitted and verified.  A heuristic skip is a
  # roadblock because it cannot prove exact declared-width delivery.
  def test_near_1_factor_is_applied_and_post_transform_verified
    item = bbox_item('MARK', 8.0, 10.0, bbox_w: 24.0 * 1.01)
    b, ents, delivered = place(item)
    assert delivered
    fits = scaling_transforms(ents)
    assert_equal 1, fits.length
    assert_in_delta 1.01, fits[0][0].args[1], 1.0e-9
    assert_verified_visual_bounds(b, ents, item)
  end

  # No arbitrary min/max width factor may preempt a geometrically valid fit.
  def test_arbitrary_positive_width_factors_preserve_declared_width
    { 24.0 * 5.0 => 'factor 5.0 (too wide)',
      24.0 * 0.2 => 'factor 0.2 (too narrow)' }.each do |bbox_w, label|
      item = bbox_item('BOUND', 8.0, 10.0, bbox_w: bbox_w)
      b, ents, delivered = place(item)
      assert delivered, "#{label}: positive source width must remain achievable"
      fits = scaling_transforms(ents)
      assert_equal 1, fits.length
      assert_in_delta bbox_w / 24.0, fits[0][0].args[1], 1.0e-9
      assert_verified_visual_bounds(b, ents, item)
    end
  end

  def test_former_factor_boundaries_are_ordinary_exact_fits
    { 24.0 * 0.25 => 0.25, 24.0 * 4.0 => 4.0 }.each do |bbox_w, expected|
      item = bbox_item('EDGE', 8.0, 10.0, bbox_w: bbox_w)
      b, ents, delivered = place(item)
      assert delivered
      fits = scaling_transforms(ents)
      assert_equal 1, fits.length, "factor #{expected} must be applied"
      assert_in_delta expected, fits[0][0].args[1], 1e-9
      assert_verified_visual_bounds(b, ents, item)
    end
  end

  def test_diagonal_span_uses_declared_projection_and_verifies_final_bounds
    diagonal = identified_text_item(
      'SLOPE', 100.0, 200.0, 8.0, 45.0, 'pdftotext',
      nil, 100.0, 200.0, 130.0, 230.0
    )
    b, ents, delivered = place(diagonal)

    assert delivered, 'a diagonal run must not be skipped merely for its angle'
    assert_operator b.send(:mesh_text_declared_run_width_inches, diagonal, 45.0), :>, 0.0
    assert_equal [:scaling, :translation, :rotation],
                 ents.transforms.map { |args| args[0].kind }
    assert_verified_visual_bounds(b, ents, diagonal)
  end

  def test_boxless_span_fails_closed_after_exact_owned_cleanup
    boxless = no_bbox_item('p1019', 8.0)
    b, ents, delivered = place(boxless)

    refute delivered, 'Text3D cannot be certified without a declared source width'
    assert_empty ents.to_a
    attempt = b.text_attempts.fetch(0)
    text3d_rung = attempt[:attempt_history].fetch(0)
    assert_equal :text3d, text3d_rung[:mode]
    assert_equal :failed, text3d_rung[:outcome]
    assert_equal :verified, text3d_rung[:cleanup_outcome]
    assert_equal text3d_rung[:created_entity_ids].sort,
                 text3d_rung[:cleaned_entity_ids].sort
    refute_empty text3d_rung[:created_entity_ids]
    assert_empty text3d_rung[:resulting_entity_ids]
    erased_ids = ents.erased.map { |entity| "persistent_id:#{entity.persistent_id}" }
    assert_equal text3d_rung[:cleaned_entity_ids].sort, erased_ids.sort
  end

  def test_transform_failure_removes_exact_owned_artifacts_only
    item = bbox_item('FAIL', 8.0, 10.0, bbox_w: 16.8)
    preexisting = DummyRenderedTextEntity.new(9.0, 4.0)
    ents = ScalingRaisesEntities.new(preexisting: [preexisting])
    b, ents, delivered = place(item, ents)
    refute delivered, 'an unverified transform must never be certified as Text3D'

    preexisting_id = "persistent_id:#{preexisting.persistent_id}"
    assert_equal [preexisting_id],
                 ents.to_a.map { |entity| "persistent_id:#{entity.persistent_id}" }
    rung = b.text_attempts.fetch(0)[:attempt_history].fetch(0)
    assert_equal :failed, rung[:outcome]
    assert_equal :verified, rung[:cleanup_outcome]
    assert_equal rung[:created_entity_ids].sort, rung[:cleaned_entity_ids].sort
    refute_includes rung[:cleaned_entity_ids], preexisting_id
    erased_ids = ents.erased.map { |entity| "persistent_id:#{entity.persistent_id}" }
    assert_equal rung[:cleaned_entity_ids].sort, erased_ids.sort
    assert_empty rung[:resulting_entity_ids]
  end

  def test_build_result_carries_exact_visual_and_identity_evidence
    item = bbox_item('STD. NOTE', 8.0, 10.0, bbox_w: 16.8)
    ents = DummyTransformEntities.new
    b = GB.new(
      Object.new, [], [item], LETTER,
      scale_factor: 1.0, import_text: true, use_3d_text: true,
      group_per_page: false, target_entities: ents,
      layer_manager: WidthFidelityLayerManager.new,
      native_font_identity_resolver: exact_test_font_resolver
    )
    result = b.build
    assert_equal 1, result[:text_objects]
    attempt = result[:text_attempts].fetch(0)
    assert_equal item.source_span_id, attempt[:source_span_id]
    assert_equal :text3d, attempt[:requested_mode]
    assert_equal :text3d, attempt[:delivered_mode]
    assert attempt[:visual_fidelity_verified]
    assert attempt[:placement_verified]
    assert attempt[:rotation_verified]
    assert attempt[:width_verified]
    assert attempt[:height_verified]
    assert RF.positive_entity_ids(attempt[:resulting_entity_ids])
    provenance = result[:source_provenance_objects].fetch(0)
    assert_equal item.source_span_id, provenance[:span_id]
    assert_equal attempt[:resulting_entity_ids], provenance[:resulting_entity_ids]
  end

  # ── Import scale factors into the declared width exactly once ────────────
  def test_import_scale_scales_declared_width_once
    item = bbox_item('MARK', 8.0, 10.0, bbox_w: 16.8)
    b = GB.new(Object.new, [], [], LETTER, scale_factor: 2.0,
               import_text: true, use_3d_text: true)
    declared = b.send(:mesh_text_declared_run_width_inches, item, 0.0)
    assert_in_delta 2.0 * 16.8 / 72.0, declared, 1e-9,
                    'declared width must be bbox extent x pt->inch x import scale'
  end

  # ── Source locks ──────────────────────────────────────────────────────────
  def source
    # Explicit UTF-8: the bare ruby:2.2 container defaults to US-ASCII and
    # raises on the builder's UTF-8 comments otherwise.
    @source ||= File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'),
      encoding: 'UTF-8'
    )
  end

  def method_body(name)
    body = source[/^([ \t]*)def #{Regexp.escape(name)}(?=\s|\().*?^\1end\b/m]
    refute_nil body, "could not isolate ##{name}"
    body
  end

  # The height-derivation region must contain no width calls at all — width
  # fidelity is post-generation only and can never select a height.
  def test_height_derivation_region_contains_no_width_calls
    %w[mesh_text_height_inches record_mesh_text_height_sample].each do |height_fn|
      body = method_body(height_fn)
      refute_match(/width/i, body,
                   "##{height_fn} must contain no width tokens (SIZE-1)")
      refute_includes body, 'Transformation.scaling',
                      "##{height_fn} must never scale geometry"
    end
  end

  # Banned shim tokens stay banned (R22 brief + prior rounds).
  def test_banned_width_shim_tokens_absent
    %w[mesh_text_fit_font_size_pts calibrate_mesh_text
       mesh_text_post_rotation_offset].each do |forbidden|
      refute_includes source, forbidden,
                      "#{forbidden} must not exist in geometry_builder.rb"
    end
  end

  def test_visual_fit_requires_source_dimensions_and_final_host_bounds
    body = method_body('fit_created_text_entities!')
    assert_includes body, 'mesh_text_height_inches'
    assert_includes body, 'mesh_text_declared_run_width_inches'
    assert_includes body, 'RepresentationFidelity.bounds(created)'
    assert_includes body, 'factor_x = target_width / generated[:width]'
    assert_includes body, 'factor_y = target_height / generated[:height]'
    assert_includes body, 'scaled = RepresentationFidelity.bounds(created)'
    assert_includes body, 'final_bounds = RepresentationFidelity.bounds(created)'
    assert_includes body, 'RepresentationFidelity.expected_rotated_bounds'
    refute_match(/MESH_TEXT_WIDTH_FACTOR_(?:MIN|MAX)/, body)
    refute_includes body, 'MESH_TEXT_WIDTH_SKIP_TOLERANCE'
  end
end
