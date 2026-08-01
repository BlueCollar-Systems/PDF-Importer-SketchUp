#!/usr/bin/env ruby

require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__)
LAUNCHER = File.read(File.join(ROOT, 'tools', 'sketchup_host_launcher.rb'))
BATCH = File.read(File.join(ROOT, 'tools', 'sketchup_batch_import.rb'))

class SketchupReleaseIdentityContractTest < Minitest::Test
  def test_launcher_enforces_exact_repository_package_and_lease_identity
    %w[
      repository_root git_commit git_tag package_path package_sha256
      expected_importer_version lease_evidence
    ].each do |field|
      assert_includes LAUNCHER, field
    end
    assert_includes LAUNCHER, 'verify_release_identity!'
    assert_includes LAUNCHER, 'package_tree_sha256'
    assert_includes LAUNCHER, 'verify_repository_identity!'
  end

  def test_host_result_records_loaded_module_paths_and_hashes
    assert_includes BATCH, 'module_identities'
    assert_includes BATCH, "'path' => path"
    assert_includes BATCH, "'sha256' => Digest::SHA256.file(path).hexdigest"
    assert_includes BATCH, "'requested_pages'"
    assert_includes BATCH, "'release_acceptance'"
  end
end
