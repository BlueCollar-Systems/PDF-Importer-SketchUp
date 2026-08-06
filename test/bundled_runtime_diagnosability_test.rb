#!/usr/bin/env ruby
# frozen_string_literal: true

# When the bundled Poppler runtime switches itself off, it must say why.
#
# bundled_bin_ready? has fourteen ways to refuse, and every one used to be a
# bare `return false`. The whole runtime could go dark -- taking pdftocairo and
# therefore the terminal Raster rung with it -- and neither the user, the log,
# nor the Compatibility Report would carry a single clue.
#
# The most likely trigger is also the least obvious: the integrity check
# compares the on-disk file list against poppler-runtime-manifest.json exactly,
# so adding one file to Library/bin without regenerating the manifest and
# re-pinning PINNED_MEMBER_INVENTORY_SHA256 silently disables everything. That
# is not hypothetical -- bundling the MSVC runtime tripped exactly this, and
# without a reason string it presents as "the importer stopped working".
#
# Ruby 2.2 compatible (SketchUp 2017 ships 2.2.4).

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'

class BundledRuntimeDiagnosabilityTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  EXT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer')

  def resolver
    return @resolver if defined?(@resolver) && @resolver
    require File.join(EXT, 'dependency_resolver')
    @resolver = ObjectSpace.each_object(Module).find do |mod|
      begin
        mod.respond_to?(:bundled_bin_ready?) && mod.respond_to?(:bundled_runtime_unavailable)
      rescue StandardError
        false
      end
    end
    refute_nil @resolver, 'could not locate DependencyResolver'
    @resolver
  end

  def reset!
    resolver.instance_variable_set(:@verified_bundled_runtime_root, nil)
    resolver.instance_variable_set(:@bundled_runtime_unavailable_reason, nil)
  end

  # --- the real tree is healthy ------------------------------------------------

  def test_intact_runtime_reports_ready_and_no_reason
    reset!
    assert resolver.bundled_bin_ready?,
           'the checked-in runtime tree should verify; if this fails the ' \
           'manifest is out of date with Library/bin'
    assert_nil resolver.bundled_runtime_unavailable_reason,
               'a healthy runtime must not leave a stale failure reason behind'
  end

  # --- every refusal is explained ---------------------------------------------

  def test_refusal_records_and_returns_false
    reset!
    refute resolver.bundled_runtime_unavailable('simulated cause'),
           'the helper must evaluate false so it can be returned directly'
    assert_equal 'simulated cause', resolver.bundled_runtime_unavailable_reason
  end

  def test_reason_is_replaced_when_the_cause_changes
    reset!
    resolver.bundled_runtime_unavailable('first cause')
    resolver.bundled_runtime_unavailable('second cause')
    assert_equal 'second cause', resolver.bundled_runtime_unavailable_reason
  end

  def test_integrity_mismatch_names_the_manifest_and_the_pin
    reset!
    # Simulate the exact mistake: an extra file in Library/bin that the
    # manifest has never seen.
    reason = nil
    resolver.stub(:bundled_runtime_integrity_valid?, false) do
      refute resolver.bundled_bin_ready?
      reason = resolver.bundled_runtime_unavailable_reason
    end
    refute_nil reason, 'an integrity mismatch must not be silent'
    assert_match(/integrity manifest/i, reason)
    assert_match(/poppler-runtime-manifest\.json/, reason,
                 'the reason must name the file to regenerate')
    assert_match(/PINNED_MEMBER_INVENTORY_SHA256/, reason,
                 'the reason must name the constant to re-pin')
  end

  def test_missing_manifest_is_explained
    reset!
    reason = nil
    resolver.stub(:bundled_runtime_manifest, nil) do
      refute resolver.bundled_bin_ready?
      reason = resolver.bundled_runtime_unavailable_reason
    end
    assert_match(/manifest/i, reason.to_s)
  end

  def test_unapproved_license_review_is_explained
    reset!
    manifest = {
      'schema' => 1,
      'layout' => {
        'bin' => 'Library/bin',
        'data' => 'share/poppler',
        'manifest' => 'poppler-runtime-manifest.json'
      },
      'license_review' => { 'status' => 'pending', 'missing' => [] }
    }
    reason = nil
    resolver.stub(:bundled_runtime_manifest, manifest) do
      refute resolver.bundled_bin_ready?
      reason = resolver.bundled_runtime_unavailable_reason
    end
    assert_match(/license_review status is not approved/, reason.to_s)
  end

  def test_bad_layout_names_the_offending_value
    reset!
    manifest = {
      'schema' => 1,
      'layout' => { 'bin' => 'bin', 'data' => 'share/poppler',
                    'manifest' => 'poppler-runtime-manifest.json' },
      'license_review' => { 'status' => 'approved', 'missing' => [] }
    }
    reason = nil
    resolver.stub(:bundled_runtime_manifest, manifest) do
      refute resolver.bundled_bin_ready?
      reason = resolver.bundled_runtime_unavailable_reason
    end
    assert_match(/layout\.bin/, reason.to_s)
    assert_match(/"bin"/, reason.to_s, 'the actual bad value must be shown')
  end

  # --- the reason must survive to the caller ----------------------------------

  def test_reason_is_readable_after_a_failed_check
    reset!
    resolver.stub(:bundled_runtime_integrity_valid?, false) do
      resolver.bundled_bin_ready?
    end
    refute_nil resolver.bundled_runtime_unavailable_reason,
               'Compatibility Report reads this to tell the user what broke'
  ensure
    reset!
    resolver.bundled_bin_ready?
  end
end
