require 'minitest/autorun'
require 'tmpdir'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_salvage'

class PdfSalvageCleanupTest < Minitest::Test
  PS = BlueCollarSystems::PDFVectorImporter::PdfSalvage

  def test_cleanup_is_public_and_removes_registered_temp_file
    path = File.join(Dir.tmpdir, "bc_salvage_cleanup_test_#{Process.pid}.pdf")
    File.write(path, '%PDF-1.4')
    PS.instance_variable_set(:@temp_salvages, [path])

    assert PS.respond_to?(:cleanup), 'cleanup must be callable from CLI/main ensure blocks'
    PS.cleanup(path)

    refute File.exist?(path)
    assert_equal [], PS.instance_variable_get(:@temp_salvages)
  ensure
    File.delete(path) if path && File.exist?(path)
    PS.instance_variable_set(:@temp_salvages, [])
  end

  def test_cleanup_all_removes_every_registered_temp_file
    paths = 2.times.map do |i|
      path = File.join(Dir.tmpdir, "bc_salvage_cleanup_all_test_#{Process.pid}_#{i}.pdf")
      File.write(path, '%PDF-1.4')
      path
    end
    PS.instance_variable_set(:@temp_salvages, paths.dup)

    assert PS.respond_to?(:cleanup_all), 'cleanup_all must be callable from at_exit'
    PS.cleanup_all

    paths.each { |path| refute File.exist?(path) }
    assert_equal [], PS.instance_variable_get(:@temp_salvages)
  ensure
    paths.to_a.each { |path| File.delete(path) if File.exist?(path) }
    PS.instance_variable_set(:@temp_salvages, [])
  end

  def test_prepare_regenerates_salvage_after_cleanup_evicts_cached_path
    source = File.join(Dir.tmpdir, "bc_salvage_source_#{Process.pid}.pdf")
    File.write(source, '%PDF-1.4 source')
    singleton = class << PS; self; end
    original_prepare = PS.method(:prepare_uncached)
    calls = 0
    generated = []
    PS.instance_variable_set(:@memo, {})
    PS.instance_variable_set(:@temp_salvages, [])

    singleton.send(:define_method, :prepare_uncached) do |_source_path|
      calls += 1
      path = File.join(
        Dir.tmpdir, "bc_salvage_regenerated_#{Process.pid}_#{calls}.pdf"
      )
      File.write(path, "%PDF-1.4 generated #{calls}")
      temp_salvages << path
      generated << path
      [path, 'salvaged via test seam']
    end
    singleton.send(:private, :prepare_uncached)

    first, = PS.prepare_if_needed(source)
    assert File.file?(first)
    PS.cleanup(first)
    refute File.exist?(first)

    second, = PS.prepare_if_needed(source)
    assert_equal 2, calls, 'deleted cached salvage must be regenerated'
    refute_equal first, second
    assert File.file?(second)
  ensure
    if singleton && original_prepare
      singleton.send(:define_method, :prepare_uncached) do |path|
        original_prepare.call(path)
      end
      singleton.send(:private, :prepare_uncached)
    end
    PS.cleanup_all
    generated.to_a.each { |path| File.delete(path) if File.exist?(path) }
    File.delete(source) if source && File.exist?(source)
    PS.instance_variable_set(:@memo, {})
    PS.instance_variable_set(:@temp_salvages, [])
  end
end
