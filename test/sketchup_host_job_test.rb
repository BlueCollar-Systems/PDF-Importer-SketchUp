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
end
