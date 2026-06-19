#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../corpus_paths'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer'

class SvgTextMultiPageGateTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer
  Runner = BlueCollarSystems::PDFVectorImporter::CommandRunner
  TARGET_PDF = 'BOUND SET SEALED DRAWINGS 18 FEB 2026.pdf'.freeze

  def test_available_svg_renderers_handle_non_page_one_text
    pdf_path = ENV['BCS_SVG_TEXT_GATE_PDF'].to_s
    pdf_path = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf(TARGET_PDF).to_s if pdf_path.empty?
    skip "Set BCS_SVG_TEXT_GATE_PDF or add #{TARGET_PDF} to the corpus" unless File.file?(pdf_path)

    renderers = available_renderers
    skip 'No SVG text renderer found' if renderers.empty?

    pages = selected_pages(pdf_path)
    assert_operator pages.length, :>=, 3

    renderers.each do |renderer|
      pages.each do |page_num|
        assert_svg_text_output(renderer, pdf_path, page_num)
      end
    end
  end

  private

  def available_renderers
    renderers = []
    pdftocairo = R.find_pdftocairo
    renderers << { kind: :pdftocairo, exe: pdftocairo } if pdftocairo
    mutool = R.find_mutool
    renderers << { kind: :mutool, exe: mutool } if mutool
    renderers
  end

  def selected_pages(pdf_path)
    parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
    parser.parse
    count = parser.page_count
    assert_operator count, :>=, 3
    [1, [(count / 2.0).ceil, 2].max, count].uniq
  ensure
    parser.release if parser
  end

  def assert_svg_text_output(renderer, pdf_path, page_num)
    svg_path = R.temp_svg_path
    ok = false
    stderr = ''
    R.svg_render_arg_variants(renderer, pdf_path, svg_path, page_num, false).each do |args|
      File.delete(svg_path) if File.exist?(svg_path)
      run = Runner.run(args, timeout_s: 90, context: "SvgTextMultiPageGate.#{renderer[:kind]}")
      stderr = run[:stderr].to_s
      ok = run[:ok] && File.exist?(svg_path)
      break if ok || run[:timed_out]
    end

    assert ok, "#{renderer[:kind]} failed to render SVG text for page #{page_num}: #{stderr}"
    svg = File.read(svg_path, encoding: 'UTF-8')
    defs = R.parse_glyph_defs(svg)
    placements = R.parse_use_placements(svg)
    assert_operator defs.length, :>, 0, "#{renderer[:kind]} page #{page_num} glyph definitions"
    assert_operator placements.length, :>, 0, "#{renderer[:kind]} page #{page_num} glyph placements"
  ensure
    File.delete(svg_path) if svg_path && File.exist?(svg_path)
  end
end
