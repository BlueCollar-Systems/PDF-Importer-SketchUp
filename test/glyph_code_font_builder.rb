# Builds tiny TrueType faces in memory so the recovery tests depend on nothing
# installed. CI runs these on Linux, where there is no Arial to lean on.
#
# Only the tables the reader looks at: head, maxp, loca, glyf, hhea, hmtx,
# cmap (format 4) and name. Everything is fictional.

module GlyphCodeFontBuilder
  module_function

  UNITS_PER_EM = 1000

  # One distinct closed outline per character. Nothing here is a real typeface;
  # the point is that two different characters never share a contour list.
  SHAPES = {
    'A' => [[0, 0], [500, 0], [500, 700], [0, 700]],
    'B' => [[20, 0], [480, 0], [480, 700], [20, 700]],
    'M' => [[0, 0], [600, 0], [600, 720], [300, 400], [0, 720]],
    'S' => [[10, 10], [590, 10], [590, 690], [300, 380], [10, 690]],
    '-' => [[0, 300], [400, 300], [400, 360], [0, 360]],
    '1' => [[200, 0], [300, 0], [300, 700], [200, 700]],
    '2' => [[40, 0], [520, 0], [520, 640], [40, 640]],
    '3' => [[30, 0], [510, 0], [510, 660], [250, 330], [30, 660]],
    ' ' => nil
  }.freeze

  ADVANCES = {
    'A' => 600, 'B' => 620, 'M' => 700, 'S' => 640,
    '-' => 333, '1' => 380, '2' => 560, '3' => 556, ' ' => 278
  }.freeze

  def u16(v); [v].pack('n'); end
  def u32(v); [v].pack('N'); end
  def s16(v); [v].pack('s>'); end

  def simple_glyph(points)
    return '' if points.nil? || points.empty?
    xs = points.map { |p| p[0] }
    ys = points.map { |p| p[1] }
    out = s16(1) + s16(xs.min) + s16(ys.min) + s16(xs.max) + s16(ys.max)
    out += u16(points.length - 1)   # end point of the single contour
    out += u16(0)                   # no instructions
    out += ([0x01] * points.length).pack('C*') # every point on-curve, long deltas
    px = 0
    points.each { |p| out += s16(p[0] - px); px = p[0] }
    py = 0
    points.each { |p| out += s16(p[1] - py); py = p[1] }
    out += "\x00" while (out.bytesize % 4) != 0
    out
  end

  # A composite glyph referencing two other glyph ids, offset apart.
  def composite_glyph(gid_a, gid_b, dx)
    out = s16(-1) + s16(0) + s16(0) + s16(1000) + s16(1000)
    # ARG_1_AND_2_ARE_WORDS | ARGS_ARE_XY_VALUES | MORE_COMPONENTS
    out += u16(0x0001 | 0x0002 | 0x0020) + u16(gid_a) + s16(0) + s16(0)
    out += u16(0x0001 | 0x0002) + u16(gid_b) + s16(dx) + s16(0)
    out += "\x00" while (out.bytesize % 4) != 0
    out
  end

  def name_table(family, subfamily)
    records = [[1, family], [2, subfamily]]
    storage = ''
    entries = ''
    records.each do |name_id, text|
      encoded = text.unpack('U*').pack('n*')
      entries += u16(3) + u16(1) + u16(0x0409) + u16(name_id) +
                 u16(encoded.bytesize) + u16(storage.bytesize)
      storage += encoded
    end
    u16(0) + u16(records.length) + u16(6 + records.length * 12) + entries + storage
  end

  # cmap format 4 with one segment per codepoint, plus the required 0xFFFF end.
  def cmap_table(map)
    codes = map.keys.sort
    segs = codes.map { |c| [c, c, map[c]] }
    segs << [0xFFFF, 0xFFFF, 0]
    seg_count = segs.length
    ends = segs.map { |s| u16(s[1]) }.join
    starts = segs.map { |s| u16(s[0]) }.join
    deltas = segs.map { |s| u16(s[2] == 0 ? 1 : (s[2] - s[0]) & 0xFFFF) }.join
    ranges = segs.map { u16(0) }.join
    sub = u16(4) + u16(16 + seg_count * 8) + u16(0) +
          u16(seg_count * 2) + u16(0) + u16(0) + u16(0) +
          ends + u16(0) + starts + deltas + ranges
    u16(0) + u16(1) + u16(3) + u16(1) + u32(12) + sub
  end

  # glyphs: array of raw glyf entries, index == glyph id.
  # advances: array of advance widths, index == glyph id.
  # cmap: {codepoint => glyph id}, or nil for no cmap table at all.
  def build(glyphs, advances, cmap, family = 'SampleGothic', subfamily = 'Regular')
    glyf = ''
    loca = []
    glyphs.each do |g|
      loca << glyf.bytesize
      glyf += g.to_s
    end
    loca << glyf.bytesize

    head = "\x00\x01\x00\x00" + "\x00\x01\x00\x00" + u32(0) + u32(0x5F0F3CF5) +
           u16(0) + u16(UNITS_PER_EM) + ("\x00" * 16) +
           s16(0) + s16(0) + s16(1000) + s16(1000) +
           u16(0) + u16(8) + s16(2) + s16(1) + s16(0)
    maxp = "\x00\x01\x00\x00" + u16(glyphs.length) + ("\x00" * 26)
    hhea = "\x00\x01\x00\x00" + ("\x00" * 30) + u16(advances.length)
    hmtx = advances.each_with_index.map { |a, _i| u16(a) + s16(0) }.join
    loca_data = loca.map { |o| u32(o) }.join

    tables = {
      'head' => head, 'maxp' => maxp, 'hhea' => hhea, 'hmtx' => hmtx,
      'loca' => loca_data, 'glyf' => glyf, 'name' => name_table(family, subfamily)
    }
    tables['cmap'] = cmap_table(cmap) unless cmap.nil?

    tags = tables.keys.sort
    offset = 12 + tags.length * 16
    directory = ''
    body = ''
    tags.each do |tag|
      data = tables[tag]
      directory += tag + u32(0) + u32(offset + body.bytesize) + u32(data.bytesize)
      padded = data.dup
      padded += "\x00" while (padded.bytesize % 4) != 0
      body += padded
    end
    out = "\x00\x01\x00\x00" + u16(tags.length) + u16(0) + u16(0) + u16(0) +
          directory + body
    out.force_encoding(Encoding::BINARY)
    out
  end

  # A face covering `chars`, mapped at their real codepoints. Glyph id 0 is
  # .notdef, then one glyph per character in order.
  def reference_face(chars, family = 'SampleGothic', subfamily = 'Regular')
    glyphs = ['']
    advances = [0]
    cmap = {}
    chars.each_char do |ch|
      cmap[ch.ord] = glyphs.length
      glyphs << simple_glyph(SHAPES[ch])
      advances << ADVANCES[ch]
    end
    build(glyphs, advances, cmap, family, subfamily)
  end

  # A subset drawing the same shapes at arbitrary glyph ids and carrying NO
  # cmap - the defect this whole module exists for.
  # layout: {glyph id => character}
  def subset_face(layout, with_cmap = nil)
    max_gid = layout.keys.max.to_i
    glyphs = Array.new(max_gid + 1, '')
    advances = Array.new(max_gid + 1, 0)
    layout.each do |gid, ch|
      glyphs[gid] = simple_glyph(SHAPES[ch])
      advances[gid] = ADVANCES[ch]
    end
    build(glyphs, advances, with_cmap)
  end

  # {glyph id => advance} as a PDF /W would give it.
  def widths_for(layout)
    out = {}
    layout.each { |gid, ch| out[gid] = ADVANCES[ch].to_f }
    out
  end

  def hex_for(gids)
    gids.map { |g| format('%04x', g) }.join
  end
end
