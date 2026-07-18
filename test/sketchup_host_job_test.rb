#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupHostJobTest < Minitest::Test
  def load_job_tool
    load File.join(REPO_ROOT, 'tools', 'sketchup_host_job.rb')
  end

  def test_json_job_preserves_spaced_paths_and_requested_mode
    load_job_tool
    Dir.mktmpdir('su host job ') do |dir|
      pdf = File.join(dir, 'drawing with spaces.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      output = File.join(dir, 'host output')
      job_path = File.join(dir, 'job.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => pdf,
        'output_dir' => output,
        'text_mode' => 'text3d',
        'import_mode' => 'vector',
        'pages' => [1]
      ))

      job = SketchupHostJob.load(job_path)
      assert_equal File.expand_path(pdf), job[:pdf_path]
      assert_equal File.expand_path(output), job[:output_dir]
      assert_equal :text3d, job[:text_mode]
      assert_equal 'vector', job[:import_mode]
      assert_equal [1], job[:pages]
      assert_equal File.join(output, 'drawing with spaces-text3d.skp'), job[:model_path]
      assert_equal File.join(output, 'host_acceptance.json'), job[:result_path]
      assert_equal File.join(output, 'host_progress.json'), job[:progress_path]
    end
  end

  def test_legacy_pdf_argument_retains_labels_behavior_without_second_argument
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      pdf = File.join(dir, 'legacy.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      job = SketchupHostJob.load(pdf)
      assert_equal :labels, job[:text_mode]
      assert_equal File.dirname(pdf), job[:output_dir]
    end
  end

  def test_unknown_requested_mode_is_rejected
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      pdf = File.join(dir, 'drawing.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      job_path = File.join(dir, 'job.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => pdf, 'output_dir' => dir,
        'text_mode' => 'auto_change_type'
      ))
      error = assert_raises(ArgumentError) { SketchupHostJob.load(job_path) }
      assert_match(/text_mode/, error.message)
    end
  end

  def test_fractional_pages_are_rejected
    [1.5, '1.5'].each { |value| assert_invalid_pages(value) }
  end

  def test_zero_page_is_rejected
    assert_invalid_pages(0)
  end

  def test_negative_page_is_rejected
    assert_invalid_pages(-1)
  end

  def test_non_exact_integer_string_page_is_rejected
    assert_invalid_pages(' 1 ')
  end

  def test_exact_positive_integer_strings_are_accepted
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      _pdf, job_path = write_json_job(dir, 'pages' => ['2', '1'])
      assert_equal [1, 2], SketchupHostJob.load(job_path)[:pages]
    end
  end

  def test_unknown_import_mode_is_rejected
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      _pdf, job_path = write_json_job(dir, 'import_mode' => 'auto_change_type')
      error = assert_raises(ArgumentError) { SketchupHostJob.load(job_path) }
      assert_match(/import_mode/, error.message)
    end
  end

  def test_every_requested_representation_is_preserved
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      output = File.join(dir, 'host output')
      %w[text labels text3d glyphs geometry raster].each do |mode|
        pdf, job_path = write_json_job(
          dir,
          'output_dir' => output,
          'text_mode' => mode
        )
        job = SketchupHostJob.load(job_path)
        assert_equal mode.to_sym, job[:text_mode]
        assert_equal File.join(output, "#{File.basename(pdf, '.pdf')}-#{mode}.skp"), job[:model_path]
      end
    end
  end

  def test_controlled_job_preserves_original_and_immutable_source_lineage
    load_job_tool
    Dir.mktmpdir('su-host-job-lineage') do |dir|
      original = File.join(dir, 'owner.pdf')
      immutable = File.join(dir, 'snapshot', 'owner.pdf')
      FileUtils.mkdir_p(File.dirname(immutable))
      bytes = "%PDF-1.4\nimmutable\n%%EOF\n"
      File.binwrite(original, bytes)
      File.binwrite(immutable, bytes)
      digest = Digest::SHA256.hexdigest(bytes)
      job_path = File.join(dir, 'controlled.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => immutable,
        'output_dir' => dir,
        'text_mode' => 'labels',
        'original_pdf_path' => original,
        'original_pdf_sha256' => digest,
        'immutable_pdf_path' => immutable,
        'immutable_pdf_sha256' => digest
      ))

      job = SketchupHostJob.load(job_path)
      assert_equal original, job[:original_pdf_path]
      assert_equal digest, job[:original_pdf_sha256]
      assert_equal immutable, job[:immutable_pdf_path]
      assert_equal digest, job[:immutable_pdf_sha256]
    end
  end

  private

  def assert_invalid_pages(value)
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      _pdf, job_path = write_json_job(dir, 'pages' => [value])
      error = assert_raises(ArgumentError) { SketchupHostJob.load(job_path) }
      assert_match(/pages/, error.message)
    end
  end

  def write_json_job(dir, overrides)
    pdf = File.join(dir, 'drawing.pdf')
    File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
    job_path = File.join(dir, 'job.json')
    attributes = {
      'pdf_path' => pdf,
      'output_dir' => dir,
      'text_mode' => 'labels'
    }.merge(overrides)
    File.write(job_path, JSON.generate(attributes))
    [pdf, job_path]
  end
end
