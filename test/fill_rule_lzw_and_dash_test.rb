require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
    def distance(other)
      dx = x - other.x
      dy = y - other.y
      dz = z - other.z
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
  end

  class Transformation
    def initialize(origin = nil, scale = 1.0)
      @origin = origin
      @scale = scale.to_f
    end
    def self.translation(origin)
      new(origin, 1.0)
    end
    def self.scaling(x_scale, y_scale = nil, z_scale = nil)
      raise ArgumentError, 'three-axis scaling' if y_scale.nil? || z_scale.nil?
      new(nil, x_scale)
    end
    def *(other)
      self.class.new(@origin || other.instance_variable_get(:@origin),
                     @scale * other.instance_variable_get(:@scale))
    end
  end
end unless defined?(Geom::Point3d)

module Sketchup
  class Face; end
  class Edge; end
  class Color
    attr_reader :red, :green, :blue
    def initialize(red, green, blue)
      @red, @green, @blue = red, green, blue
    end
  end
end unless defined?(Sketchup::Face)

require_relative 'support/synthetic_pdf_builder'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/xobject_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'

# Headless proof that even-odd holes, LZW streams, and short dash phase
# stay attached to the source. SketchUp itself is not available here.
class FillRuleLzwAndDashTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  PDF = BlueCollarSystems::PDFVectorImporter::PDFParser
  XObjects = BlueCollarSystems::PDFVectorImporter::XObjectParser
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder

  def test_evenodd_and_nonzero_fills_keep_their_rule
    even = Parser.new(['0 0 40 40 re 10 10 10 10 re f*'], nil).parse
    odd = Parser.new(['0 0 40 40 re 10 10 10 10 re f'], nil).parse
    both = Parser.new(['0 0 20 20 re 4 4 6 6 re B*'], nil).parse

    assert_equal :evenodd, even[0].fill_rule
    assert_equal 2, even[0].subpaths.length
    assert_equal true, even[0].fill
    assert_equal false, even[0].stroke

    assert_equal :nonzero, odd[0].fill_rule
    assert_equal :evenodd, both[0].fill_rule
    assert_equal true, both[0].stroke
    assert_nil Parser.new(['0 0 10 10 re S'], nil).parse[0].fill_rule
  end

  def test_form_transform_keeps_the_fill_rule
    path = Parser.new(['0 0 10 10 re 2 2 4 4 re f*'], nil).parse.first
    moved = XObjects.new(nil).send(:transform_paths, [path], [1, 0, 0, 1, 5, 6]).first

    assert_equal :evenodd, moved.fill_rule
    assert_equal [5, 6], moved.subpaths[0].segments[0].points[0]
  end

  def test_evenodd_hole_is_not_left_as_a_second_solid_face
    host = HoleHost.new
    paths = Parser.new(['0 0 40 40 re 10 10 12 12 re f*'], nil).parse
    builder = Builder.new(host.model, paths, [], [0, 0, 100, 100],
                          :group_per_page => false, :detect_arcs => false,
                          :import_fills => true, :merge_tolerance => 0)
    result = builder.build

    faces = host.faces
    assert_equal 1, faces.length, 'the inner contour must be removed'
    assert_equal 1, result[:faces]
    assert faces[0].points.length >= 4
  end

  def test_nonzero_opposite_hole_is_removed_and_same_winding_stays
    host = HoleHost.new
    # Inner rectangle is wound opposite the outer one.
    stream = '0 0 40 40 re 10 10 m 10 22 l 22 22 l 22 10 l h f'
    paths = Parser.new([stream], nil).parse
    assert_equal :nonzero, paths[0].fill_rule
    builder = Builder.new(host.model, paths, [], [0, 0, 100, 100],
                          :group_per_page => false, :detect_arcs => false,
                          :import_fills => true, :merge_tolerance => 0)
    result = builder.build
    assert_equal 1, result[:faces]

    solid = HoleHost.new
    same = Parser.new(['0 0 40 40 re 10 10 12 12 re f'], nil).parse
    Builder.new(solid.model, same, [], [0, 0, 100, 100],
                :group_per_page => false, :detect_arcs => false,
                :import_fills => true, :merge_tolerance => 0).build
    assert_equal 2, solid.faces.length
  end

  def test_disjoint_opposite_contours_stay_two_faces
    host = HoleHost.new
    stream = '0 0 10 10 re 30 30 m 30 40 l 40 40 l 40 30 l h f'
    paths = Parser.new([stream], nil).parse
    builder = Builder.new(host.model, paths, [], [0, 0, 100, 100],
                          :group_per_page => false, :detect_arcs => false,
                          :import_fills => true, :merge_tolerance => 0)
    refute builder.send(:compound_fill_needs_punch?, paths[0])
    result = builder.build
    assert_equal 2, result[:faces]
  end

  def test_short_dash_phase_uses_the_same_visibility_scale
    builder = Builder.new(nil, [], [], [0, 0, 100, 100], :merge_tolerance => 0.0005)
    spec = builder.send(:normalize_dash_pattern, [[1.0, 1.0], 1.0], [1, 0, 0, 1, 0, 0])
    assert_in_delta 0.03, spec[:pattern][0], 1.0e-9
    assert_in_delta 0.03, spec[:pattern][1], 1.0e-9
    assert_in_delta 0.03, spec[:phase], 1.0e-9
  end

  def test_lzw_content_stream_round_trips_and_poppler_reads_it
    # Enough distinct words to cross the 9-bit and 10-bit code boundaries.
    # A single long run never changes the code width, and pdftotext drops
    # the tail of one enormous unspaced line even from an uncompressed PDF.
    words = ['LZWSTART'] + (0...420).map { |i| format('w%04d', i) } + ['LZWEND']
    plain = "BT /F1 10 Tf 12 TL 40 6800 Td (#{words[0]}) Tj"
    words[1..-1].each { |word| plain << " T* (#{word}) Tj" }
    plain << ' ET'
    encoded = lzw_encode(plain, 1)
    path = write_lzw_pdf(encoded, 1)

    parser = PDF.new(path)
    parser.parse
    streams = parser.page_data(1)[:content_streams]
    assert_equal plain, streams[0]

    text = poppler_text(path)
    skip 'pdftotext is not available' unless text
    assert_includes text, 'LZWSTART'
    assert_includes text, 'w0200'
    assert_includes text, 'LZWEND'
  ensure
    parser.release if parser
  end

  def test_lzw_early_change_zero_still_decodes
    plain = '0 0 30 15 re S'
    encoded = lzw_encode(plain, 0)
    path = write_lzw_pdf(encoded, 0)
    parser = PDF.new(path)
    parser.parse
    assert_equal plain, parser.page_data(1)[:content_streams][0]
    paths = Parser.new(parser.page_data(1)[:content_streams], nil).parse
    assert_equal 1, paths.length
    assert_equal true, paths[0].stroke
  ensure
    parser.release if parser
  end

  def lzw_encode(data, early)
    src = data.dup
    src.force_encoding('BINARY')
    table = {}
    256.times { |i| table[[i].pack('C')] = i }
    next_code = 258
    code_size = 9
    codes = []
    emit = lambda do |code|
      codes << [code, code_size]
    end
    bump = lambda do
      if code_size < 12 && (next_code + early) > (1 << code_size)
        code_size += 1
      end
    end
    emit.call(256)
    window = ''.dup.force_encoding('BINARY')
    src.each_byte do |byte|
      piece = [byte].pack('C')
      joined = window + piece
      if table.key?(joined)
        window = joined
      else
        emit.call(table[window])
        if next_code < 4096
          table[joined] = next_code
          next_code += 1
          bump.call
        end
        window = piece
      end
    end
    emit.call(table[window]) unless window.empty?
    emit.call(257)
    pack_codes(codes)
  end

  def pack_codes(codes)
    buf = 0
    nbits = 0
    out = ''.dup.force_encoding('BINARY')
    codes.each do |code, size|
      buf = (buf << size) | code
      nbits += size
      while nbits >= 8
        nbits -= 8
        out << [(buf >> nbits) & 0xFF].pack('C')
        if nbits > 0
          buf &= (1 << nbits) - 1
        else
          buf = 0
        end
      end
    end
    out << [(buf << (8 - nbits)) & 0xFF].pack('C') if nbits > 0
    out
  end

  def write_lzw_pdf(encoded, early_change)
    parms = early_change == 0 ? '/DecodeParms << /EarlyChange 0 >>' : ''
    dir = Dir.mktmpdir('lzw-pdf')
    path = File.join(dir, 'lzw.pdf')
    stream = SyntheticPdfBuilder.stream_object("/Filter /LZWDecode #{parms}", encoded)
    font = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    bodies = []
    bodies << '<< /Type /Catalog /Pages 2 0 R >>'
    bodies << '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
    bodies << '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 7000] ' \
              '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'
    bodies << stream
    bodies << font
    SyntheticPdfBuilder.write(path, bodies)
    path
  end

  def poppler_text(path)
    exe = ['pdftotext', '/usr/bin/pdftotext'].find { |cmd| system("command -v #{cmd} >/dev/null 2>&1") }
    return nil unless exe
    out = `#{exe} -q "#{path}" -`
    $?.success? ? out : nil
  end

  # Small SketchUp stand-in. Faces are real Sketchup::Face objects so the
  # compound-fill path can see them, measure a triangle, and erase a hole.
  class HoleHost
    attr_reader :model

    def initialize
      @model = Model.new
    end

    def faces
      walk(@model.active_entities).select { |item| item.is_a?(Sketchup::Face) }
    end

    def walk(entities)
      entities.to_a.flat_map do |item|
        item.respond_to?(:entities) ? [item] + walk(item.entities) : [item]
      end
    end
  end

  class Model
    attr_reader :active_entities, :layers, :materials
    def initialize
      @active_entities = Entities.new
      @layers = Layers.new
      @materials = Materials.new
    end
  end

  class Layers
    def initialize
      @layers = {}
    end
    def [](name)
      @layers[name]
    end
    def add(name)
      @layers[name] = name
    end
  end

  class Materials
    def initialize
      @items = {}
    end
    def [](name)
      @items[name]
    end
    def add(name)
      key = name
      key += '_1' while @items.key?(key)
      @items[key] = Material.new
    end
  end

  class Material
    attr_accessor :color, :alpha, :texture
    def initialize
      @alpha = 1.0
    end
  end

  class Entities
    def initialize
      @items = []
    end
    def to_a
      @items.dup
    end
    def length
      @items.length
    end
    def add_group
      group = Group.new
      @items << group
      group
    end
    def add_face(points)
      face = Face.new(points, self)
      @items << face
      face
    end
    def add_line(a, b)
      edge = Edge.new(a, b)
      @items << edge
      edge
    end
    def erase_entity(entity)
      @items.delete(entity)
    end
    def grep(kind)
      to_a.select { |item| item.is_a?(kind) }
    end
  end

  class Group
    attr_accessor :name, :layer, :transformation
    attr_reader :entities
    def initialize
      @entities = Entities.new
    end
    def erase!
      true
    end
  end

  class Edge < Sketchup::Edge
    attr_accessor :layer, :hidden, :material, :start_point, :end_point
    def initialize(start_point, end_point)
      @start_point = start_point
      @end_point = end_point
    end
  end

  class Face < Sketchup::Face
    attr_accessor :layer, :material, :back_material
    attr_reader :points, :owner
    def initialize(points, owner)
      @points = points
      @owner = owner
    end
    def edges
      points.each_with_index.map do |point, index|
        Edge.new(point, points[(index + 1) % points.length])
      end
    end
    def normal
      Struct.new(:z).new(1.0)
    end
    def reverse!
      self
    end
    def erase!
      owner.erase_entity(self)
    end
    def mesh(_flags = 0)
      Mesh.new(points)
    end
  end

  class Mesh
    def initialize(points)
      @points = points
    end
    def polygons
      [[1, 2, 3]]
    end
    def point_at(index)
      @points[index.abs - 1]
    end
  end
end
