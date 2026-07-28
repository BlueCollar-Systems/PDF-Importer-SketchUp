require 'minitest/autorun'
require 'tmpdir'

validator_path = File.expand_path(
  '../extracted/sketchup_ext/bc_pdf_vector_importer/poppler_result_validator',
  __dir__
)
require validator_path if File.file?(validator_path + '.rb')

class PopplerResultValidatorTest < Minitest::Test
  PROVEN_ADOBE_GB1_STDERR = [
    "Syntax Error: Missing language pack for 'Adobe-GB1' mapping",
    "Syntax Error: Unknown font tag 'china-s'",
    'Syntax Error (44846): No font in show/space'
  ].join("\n") + "\n"

  def validator
    assert defined?(BlueCollarSystems::PDFVectorImporter::PopplerResultValidator),
      'central PopplerResultValidator must exist'
    BlueCollarSystems::PDFVectorImporter::PopplerResultValidator
  end

  def make_artifact(bytes = 'complete-output')
    path = File.join(
      Dir.tmpdir,
      "bc_poppler_validator_test_#{Process.pid}_#{rand(1_000_000)}.out"
    )
    File.open(path, 'wb') { |file| file.write(bytes) }
    path
  end

  def successful_run(stdout = '', stderr = '')
    {
      ok: true,
      timed_out: false,
      exitstatus: 0,
      stdout: stdout,
      stderr: stderr,
      error: nil
    }
  end

  def validate(run, artifact, extra = {})
    validator.validate(run, {
      executable: 'C:/bundle/bin/pdftocairo.exe',
      argv: ['C:/bundle/bin/pdftocairo.exe', '-svg', 'fixture.pdf', 'page'],
      context: 'test.cid',
      page: 3,
      attempt: 2,
      representation: :glyph_geometry,
      artifacts: [artifact],
      artifact_policy: :all_nonempty
    }.merge(extra))
  end

  def test_rejects_rc_zero_nonempty_artifact_for_proven_combined_cid_diagnostics
    artifact = make_artifact

    result = validate(successful_run('', PROVEN_ADOBE_GB1_STDERR), artifact)

    refute result[:ok]
    assert result[:incomplete_output]
    assert_equal :proven_adobe_gb1_fixture_incomplete_output, result[:reason]
    assert_equal :page, result[:rejection_scope]
    assert_nil result[:evidence][:span_id]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_does_not_combine_unrelated_stdout_and_stderr_into_a_false_cluster
    artifact = make_artifact
    run = successful_run(
      "Syntax Error: Missing language pack for 'Adobe-GB1' mapping\n",
      "Syntax Error: Unknown font tag 'china-s'\n" \
        "Syntax Error (44846): No font in show/space\n"
    )

    result = validate(run, artifact)
    evidence = result[:evidence]

    assert result[:ok]
    refute result[:incomplete_output]
    assert_equal run[:stdout], evidence[:stdout]
    assert_equal run[:stderr], evidence[:stderr]
    assert_equal 'C:/bundle/bin/pdftocairo.exe', evidence[:executable]
    assert_equal 3, evidence[:page]
    assert_equal 2, evidence[:attempt]
    assert_equal 0, evidence[:exitstatus]
    assert_equal 1, evidence[:artifacts].length
    assert_equal artifact, evidence[:artifacts][0][:path]
    assert evidence[:artifacts][0][:exists]
    assert_equal File.size(artifact), evidence[:artifacts][0][:bytes]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_proven_complete_semantics_override_the_fixture_diagnostic_cluster
    artifact = make_artifact

    result = validate(
      successful_run('', PROVEN_ADOBE_GB1_STDERR),
      artifact,
      semantic_complete: true
    )

    assert result[:ok]
    refute result[:incomplete_output]
    assert result[:evidence][:semantic_complete]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_diagnostic_can_be_deferred_until_artifact_semantics_are_inspected
    artifact = make_artifact

    result = validate(
      successful_run('', PROVEN_ADOBE_GB1_STDERR),
      artifact,
      defer_semantic_completion: true
    )

    assert result[:ok]
    assert result[:incomplete_output]
    assert result[:semantic_completion_deferred]
    refute result[:evidence][:semantic_complete]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_single_pdffonts_language_pack_warning_is_not_fatal
    artifact = make_artifact
    stderr = "Syntax Error: Missing language pack for 'Adobe-GB1' mapping\n"

    result = validate(successful_run('valid font inventory', stderr), artifact)

    assert result[:ok]
    refute result[:incomplete_output]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_candidate_font_warning_families_do_not_become_blanket_fatal
    artifact = make_artifact
    candidate_warnings = [
      "Syntax Warning: Couldn't find a font for 'UnusedFont'",
      'Syntax Warning: failed to load truetype font for unused resource',
      'Syntax Warning: font matrix not invertible for unused resource'
    ].join("\n") + "\n"

    result = validate(successful_run('', candidate_warnings), artifact)

    assert result[:ok]
    refute result[:incomplete_output]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_partial_proven_cluster_is_benign_without_show_space_failure
    artifact = make_artifact
    stderr = [
      "Syntax Error: Missing language pack for 'Adobe-GB1' mapping",
      "Syntax Error: Unknown font tag 'china-s'"
    ].join("\n") + "\n"

    result = validate(successful_run('', stderr), artifact)

    assert result[:ok]
    refute result[:incomplete_output]
  ensure
    File.delete(artifact) if artifact && File.exist?(artifact)
  end

  def test_rejects_zero_byte_or_missing_required_artifact
    empty = make_artifact('')
    missing = empty + '.missing'

    empty_result = validate(successful_run, empty)
    missing_result = validate(successful_run, missing)

    refute empty_result[:ok]
    assert_equal :artifact_missing_or_empty, empty_result[:reason]
    refute missing_result[:ok]
    assert_equal :artifact_missing_or_empty, missing_result[:reason]
  ensure
    File.delete(empty) if empty && File.exist?(empty)
  end

  def test_nonzero_process_result_remains_rejected_with_helper_attempt_scope
    run = successful_run
    run[:ok] = false
    run[:exitstatus] = 7
    run[:stderr] = 'ordinary process failure'

    result = validator.validate(run,
      executable: 'pdffonts.exe',
      attempt: 1,
      representation: :font_inventory,
      artifacts: [],
      artifact_policy: :none)

    refute result[:ok]
    assert_equal :process_failed, result[:reason]
    assert_equal :helper_attempt, result[:rejection_scope]
    assert_equal 7, result[:evidence][:exitstatus]
  end
end
