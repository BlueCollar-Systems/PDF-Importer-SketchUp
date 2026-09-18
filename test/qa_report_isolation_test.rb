require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/source_provenance'

class QAReportIsolationTest < Minitest::Test
  QA = BlueCollarSystems::PDFVectorImporter::QAReport
  TEMP = BlueCollarSystems::PDFVectorImporter::SafeTemp

  def test_simultaneous_same_drawing_reports_cannot_replace_each_other_or_another_host
    Dir.mktmpdir('qa-isolation-test-') do |dir|
      other_host = File.join(dir, 'drawing_import_report.json')
      File.write(other_host, JSON.generate('host' => 'freecad', 'run' => 'peer'))
      TEMP.stub(:root, dir) do
        paths = 12.times.map do |index|
          Thread.new do
            path = QA.default_output_path('drawing.pdf')
            assert_equal path, QA.write_json({'host' => 'sketchup', 'run' => index}, path)
            [index, path]
          end
        end.map(&:value)
        assert_equal 12, paths.map(&:last).uniq.length
        paths.each do |index, path|
          assert_equal({'host' => 'sketchup', 'run' => index}, JSON.parse(File.read(path)))
        end
        assert_equal({'host' => 'freecad', 'run' => 'peer'}, JSON.parse(File.read(other_host)))
      end
    end
  end

  def test_unicode_and_long_basename_stay_short_ascii_and_do_not_collide
    Dir.mktmpdir('qa-isolation-test-') do |dir|
      TEMP.stub(:root, dir) do
        input = ("\u00e9" * 200) + '.PDF'
        first = QA.default_output_path(input)
        second = QA.default_output_path(input)
        assert File.basename(first).ascii_only?
        assert_operator File.basename(first).length, :<=, 83
        refute_equal first, second
        assert File.directory?(File.dirname(first))
      end
    end
  end

  def test_explicit_output_path_is_preserved
    Dir.mktmpdir('qa-isolation-test-') do |dir|
      output = File.join(dir, 'chosen-report.json')
      assert_equal output, QA.write_json({'run' => 'explicit'}, output)
      assert_equal({'run' => 'explicit'}, JSON.parse(File.read(output)))
    end
  end

  def test_native_companion_manifests_are_separate_for_two_imports_of_one_pdf
    provenance = BlueCollarSystems::PDFVectorImporter::SourceProvenance
    Dir.mktmpdir('qa-isolation-test-') do |dir|
      source_dir = File.join(dir, 'source')
      Dir.mkdir(source_dir)
      pdf = File.join(source_dir, 'drawing.pdf')
      File.write(pdf, '%PDF-test')
      TEMP.stub(:root, dir) do
        manifests = 2.times.map do |index|
          report = QA.default_output_path(pdf)
          target = provenance.default_sidecar_path(pdf, File.dirname(report))
          provenance.write_sidecar(output_path: target, import_session_id: "run-#{index}",
            pdf_path: pdf, objects: [{'object_id' => "entity-#{index}"}], version: 'test')
          [index, target]
        end
        refute_equal manifests[0][1], manifests[1][1]
        manifests.each do |index, target|
          manifest = JSON.parse(File.read(target))
          assert_equal "run-#{index}", manifest['import_session_id']
          assert_equal "entity-#{index}", manifest['objects'][0]['object_id']
        end
        assert_equal ['drawing.pdf'], Dir.entries(source_dir) - ['.', '..']
        refute_equal provenance.default_sidecar_path(pdf), provenance.default_sidecar_path(pdf)
      end
    end
  end
end
