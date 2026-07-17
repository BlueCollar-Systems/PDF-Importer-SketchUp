require 'minitest/autorun'

class VersionMetadataTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  EXPECTED_VERSION = '3.7.97'.freeze

  def read(path)
    File.read(File.join(ROOT, path))
  end

  def test_release_version_is_consistent
    loader = read('extracted/sketchup_ext/bc_pdf_vector_importer.rb')
    metadata = read('extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb')
    readme = read('README.md')

    assert_match(/PLUGIN_VERSION\s*=\s*'#{Regexp.escape(EXPECTED_VERSION)}'/,
                 loader)
    assert_match(/VERSION\s*=\s*'#{Regexp.escape(EXPECTED_VERSION)}'/,
                 metadata)
    assert_match(/Version-#{Regexp.escape(EXPECTED_VERSION)}-green/,
                 readme)
  end
end
