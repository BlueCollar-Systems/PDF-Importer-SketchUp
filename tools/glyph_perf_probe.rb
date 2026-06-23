#!/usr/bin/env ruby
# tools/glyph_perf_probe.rb
# Host-neutral profiling harness for the SVG glyph rendering path.
#
# Renders a PDF page to SVG with the bundled pdftocairo, then exercises the
# REAL SvgTextRenderer parse/estimate/strategy helpers to report:
#   - unique glyph definitions
#   - glyph <use> placements
#   - estimated stamped edges (sum over placements of per-glyph edge count)
#   - which strategy the current code selects (raw_edges vs glyph_components)
#   - model-mutating op counts for the OLD raw-edge path vs the NEW path.
#
# The dominant SketchUp cost is geometry MERGE on each add_edges/add_line into a
# shared entities collection (~O(n^2) in edges already present). This harness
# cannot run the SketchUp engine, so it reports the number of merge-triggering
# operations on the shared model entities, which is what drives the blowup.
#
# Copyright 2024-2026 BlueCollar Systems - BUILT. NOT BOUGHT.

# --- Minimal Geom stubs so svg_path_to_points runs host-neutral. ------------
module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f; @y = y.to_f; @z = z.to_f
    end
    def distance(o)
      dx = @x - o.x; dy = @y - o.y; dz = @z - o.z
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
    def transform(_tr); self; end
  end
end

SRC = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer', __dir__)
require File.join(SRC, 'logger')
require File.join(SRC, 'svg_text_renderer')

R = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer
PDFTOCAIRO = File.join(SRC, 'bin', 'pdftocairo.exe')

def render_svg(pdf, page)
  out = File.join(Dir.tmpdir, "probe_#{Process.pid}_#{rand(1_000_000)}")
  system(PDFTOCAIRO, '-svg', '-f', page.to_s, '-l', page.to_s, '--', pdf, out,
         out: File::NULL, err: File::NULL)
  return nil unless File.exist?(out)
  svg = File.read(out, encoding: 'UTF-8')
  File.delete(out) rescue nil
  svg
end

def probe(pdf, page = 1)
  t0 = Time.now
  svg = render_svg(pdf, page)
  render_s = Time.now - t0
  return { error: 'render failed' } unless svg

  t1 = Time.now
  glyphs = R.send(:parse_glyph_defs, svg)
  placements = R.send(:parse_use_placements, svg)
  parse_s = Time.now - t1

  # Build per-glyph edge counts using the REAL path-to-points + counter.
  t2 = Time.now
  edge_counts = {}
  glyphs.each do |gid, d|
    next if d.strip.empty?
    subpaths = R.send(:svg_path_to_points, d, 1.0 / 72.0, 1.0 / 72.0)
    edge_counts[gid] = R.send(:count_subpath_edges, subpaths)
  end
  points_s = Time.now - t2

  estimated = R.send(:estimate_glyph_edge_count, placements, edge_counts)
  raw_now = R.send(:raw_edge_glyphs?, {}, placements.length, estimated)
  flatten_now = R.send(:flatten_glyph_instances?, {}, estimated)

  # OLD committed behavior (v3.7.52): raw_edge when placements <= 5000,
  # regardless of edge volume -> stamps every glyph edge into shared entities.
  old_raw = placements.length <= 5_000
  old_merge_ops = old_raw ? estimated : 0           # add_edges/add_line into model
  # NEW behavior: component defs built once (isolated), instances placed O(1).
  new_def_edge_ops = raw_now ? 0 : edge_counts.values.reduce(0, :+)
  new_instance_ops = raw_now ? 0 : placements.length
  new_raw_merge_ops = raw_now ? estimated : 0

  {
    file: File.basename(pdf),
    render_s: render_s.round(3),
    parse_s: parse_s.round(3),
    points_s: points_s.round(3),
    unique_glyphs: glyphs.length,
    placements: placements.length,
    estimated_edges: estimated,
    strategy_now: raw_now ? 'raw_edges' : 'glyph_components',
    flatten_now: flatten_now,
    old_strategy: old_raw ? 'raw_edges' : 'glyph_components',
    old_shared_merge_ops: old_merge_ops,
    new_def_edge_ops: new_def_edge_ops,
    new_instance_ops: new_instance_ops,
    new_shared_merge_ops: new_raw_merge_ops
  }
end

if __FILE__ == $0
  ARGV.each do |pdf|
    res = probe(pdf, (ENV['PAGE'] || 1).to_i)
    puts "==== #{res[:file] || pdf} ===="
    res.each { |k, v| puts format('  %-22s %s', k, v) }
    puts
  end
end
