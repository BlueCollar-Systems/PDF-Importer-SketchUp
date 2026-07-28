require 'minitest/autorun'

class VersionMetadataTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def read(path)
    File.read(File.join(ROOT, path))
  end

  def test_release_version_is_consistent
    loader = read('extracted/sketchup_ext/bc_pdf_vector_importer.rb')
    metadata = read('extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb')
    readme = read('README.md')
    loader_version = loader[/PLUGIN_VERSION\s*=\s*'([^']+)'/, 1]
    metadata_version = metadata[/VERSION\s*=\s*'([^']+)'/, 1]
    readme_version = readme[/Version-([0-9.]+)-green/, 1]

    refute_nil loader_version
    assert_equal loader_version, metadata_version
    assert_equal loader_version, readme_version
  end
end
