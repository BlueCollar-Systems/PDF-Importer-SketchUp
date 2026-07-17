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
# The HEIGHT ban stays absolute: these locks also prove the height pipeline
# is untouched — the height passed to add_3d_text, the recorded height
# samples, and the Y/Z scale factors (exactly 1.0) never change.

require_relative 'mesh_text_scaling_test'

# Entities stub whose scaling transform raises, to lock the loud-but-safe
# width error path (R20-2: counted, never silent, never breaks placement).
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

  # ── Wide (condensed-declared) run compressed to the declared extent ──────
  def test_wide_run_is_compressed_to_declared_span_extent
    # Declared 16.8pt run vs stub-rendered 24pt-equivalent -> factor 0.7,
    # inside the measured condensed band (0.5864..0.7996).
    item = bbox_item('STD. NOTE', 8.0, 10.0, bbox_w: 16.8)
    b, ents, delivered = place(item)

    assert delivered, 'width fidelity must never break mesh delivery'
    kinds = ents.transforms.map { |args| args[0].kind }
    assert_equal [:scaling, :translation], kinds,
                 'run-axis fit must happen BEFORE the placement translation'
    args = ents.transforms[0][0].args
    assert_same ORIGIN, args[0]
    assert_in_delta 0.7, args[1], 1e-9, 'X factor must be declared/rendered'
    assert_equal [1.0, 1.0], args[2..3],
                 'height/depth factors must be exactly 1.0 (SIZE-1)'

    # Height pipeline unchanged pre/post: faithful add_3d_text height and
    # recorded height samples are identical to the no-width-fit contract.
    assert_equal 1, ents.height_args.length
    assert_in_delta H8, ents.height_args[0], 1e-9
    assert_in_delta H8, b.send(:text_height_samples)[0], 1e-9
    assert_equal [0.7], b.instance_variable_get(:@text_width_factor_samples)
      .map { |v| v.round(9) }
    assert_equal 0, ents.erased.length, 'no erase paths (FACE-1)'
  end

  # ── Expanded run grows to the declared extent ─────────────────────────────
  def test_expanded_run_grows_to_declared_span_extent
    # Declared 34.475pt vs rendered 24pt -> factor ~1.4365 (measured
    # expanded case).
    item = bbox_item('ONE FRAME', 8.0, 10.0, bbox_w: 24.0 * 1.4365)
    _b, ents, = place(item)
    args = scaling_transforms(ents)[0][0].args
    assert_in_delta 1.4365, args[1], 1e-9
    assert_equal [1.0, 1.0], args[2..3]
  end

  # ── Rotated run: factor along the pre-rotation run axis ──────────────────
  def test_rotated_run_scales_pre_rotation_x_from_bbox_run_extent
    # 90-degree part mark: bbox X extent 8pt (cross axis), Y extent 42pt
    # (run axis). Declared run = 42pt vs rendered 24pt -> factor 1.75.
    item = TI.new('a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext',
                  nil, 140.0, 250.0, 148.0, 292.0)
    _b, ents, delivered = place(item)

    assert delivered
    kinds = ents.transforms.map { |args| args[0].kind }
    assert_equal [:scaling, :translation, :rotation], kinds,
                 'rotated runs must scale local X first, then move, then rotate'
    args = ents.transforms[0][0].args
    assert_same ORIGIN, args[0]
    assert_in_delta 42.0 / 24.0, args[1], 1e-9,
                    'factor must use the bbox extent along the run axis'
    assert_equal [1.0, 1.0], args[2..3]
  end

  # ── Near-1 factors skip the transform and are counted ─────────────────────
  def test_near_1_factor_skips_transform_and_is_counted
    item = bbox_item('MARK', 8.0, 10.0, bbox_w: 24.0 * 1.01)
    b, ents, = place(item)
    assert_empty scaling_transforms(ents),
                 '|factor-1| < 0.02 must skip the scaling transform'
    assert_equal 1, b.instance_variable_get(:@text_width_skipped_near_1_count)
    assert_empty b.instance_variable_get(:@text_width_factor_samples)
  end

  # ── Out-of-bounds factors keep natural width and are counted ──────────────
  def test_out_of_bounds_factors_keep_natural_width_with_telemetry
    { 24.0 * 5.0 => 'factor 5.0 (too wide)',
      24.0 * 0.2 => 'factor 0.2 (too narrow)' }.each do |bbox_w, label|
      item = bbox_item('BOUND', 8.0, 10.0, bbox_w: bbox_w)
      b, ents, delivered = place(item)
      assert delivered, "#{label}: span must still be delivered"
      assert_empty scaling_transforms(ents), "#{label}: no scaling applied"
      assert_equal 1, b.instance_variable_get(:@text_width_out_of_bounds_count),
                   "#{label}: must be counted for the report"
      assert_empty b.instance_variable_get(:@text_width_factor_samples)
    end
  end

  # ── Explicit min/max comparisons: 0.25 and 4.0 are inclusive ─────────────
  def test_bound_edges_are_inclusive_and_applied
    { 24.0 * 0.25 => 0.25, 24.0 * 4.0 => 4.0 }.each do |bbox_w, expected|
      item = bbox_item('EDGE', 8.0, 10.0, bbox_w: bbox_w)
      b, ents, = place(item)
      fits = scaling_transforms(ents)
      assert_equal 1, fits.length, "factor #{expected} must be applied"
      assert_in_delta expected, fits[0][0].args[1], 1e-9
      assert_equal 0, b.instance_variable_get(:@text_width_out_of_bounds_count)
    end
  end

  # ── Diagonal and bbox-less spans skip silently ────────────────────────────
  def test_diagonal_and_boxless_spans_skip_without_telemetry
    b = make_builder(LETTER)
    diagonal = TI.new('SLOPE', 100.0, 200.0, 8.0, 45.0, 'pdftotext',
                      nil, 100.0, 200.0, 130.0, 230.0)
    factor, status = b.send(:mesh_text_width_fidelity_factor, diagonal, [], 45.0)
    assert_nil factor
    assert_equal :no_declared_width, status

    boxless = no_bbox_item('p1019', 8.0)
    factor, status = b.send(
      :mesh_text_width_fidelity_factor, boxless,
      [DummyRenderedTextEntity.new(0.3, 0.1)], 0.0
    )
    assert_nil factor
    assert_equal :no_declared_width, status
    assert_equal 0, b.instance_variable_get(:@text_width_skipped_near_1_count)
    assert_equal 0, b.instance_variable_get(:@text_width_out_of_bounds_count)
  end

  # ── Width-path failure is loud, counted, and never breaks placement ──────
  def test_width_failure_is_counted_and_placement_survives
    item = bbox_item('FAIL', 8.0, 10.0, bbox_w: 16.8)
    ents = ScalingRaisesEntities.new
    b, ents, delivered = place(item, ents)
    assert delivered, 'a width-fit failure must not break mesh delivery'
    kinds = ents.transforms.map { |args| args[0].kind }
    assert_equal [:translation], kinds,
                 'placement translation must still run after the width failure'
    assert_equal 1, b.instance_variable_get(:@text_width_error_count),
                 'width failures must be counted for the report (R20-2)'
  end

  # ── Build result carries the width telemetry to main.rb ──────────────────
  def test_build_result_carries_width_telemetry
    item = bbox_item('STD. NOTE', 8.0, 10.0, bbox_w: 16.8)
    ents = DummyTransformEntities.new
    b = GB.new(
      Object.new, [], [item], LETTER,
      scale_factor: 1.0, import_text: true, use_3d_text: true,
      group_per_page: false, target_entities: ents,
      layer_manager: WidthFidelityLayerManager.new
    )
    result = b.build
    assert_equal [0.7], result[:text_width_factor_samples].map { |v| v.round(9) }
    assert_equal 0, result[:text_width_out_of_bounds_count]
    assert_equal 0, result[:text_width_skipped_near_1_count]
    assert_equal 0, result[:text_width_error_count]
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
    body = source[/^([ \t]*)def #{Regexp.escape(name)}\b.*?^\1end\b/m]
    refute_nil body, "could not isolate ##{name}"
    body
  end

  # The height-derivation region must contain no width calls at all — width
  # fidelity is post-generation only and can never select a height.
  def test_height_derivation_region_contains_no_width_calls
    %w[mesh_text_height_inches effective_font_size_pts
       record_mesh_text_height_sample].each do |height_fn|
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

  # The width transform pivot is ORIGIN (pre-placement), locked at source
  # level so a pivot drift cannot silently re-anchor runs.
  def test_width_fit_scales_about_origin_with_unit_height_depth
    body = method_body('apply_mesh_text_width_fidelity')
    assert_includes body, 'Transformation.scaling(ORIGIN, factor, 1.0, 1.0)'
  end
end
