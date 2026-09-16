# test/support/synthetic_pdf_builder.rb
#
# Minimal hand-rolled PDF writer for unit tests. Builds a classic-xref PDF
# from an ordered list of object bodies so parser tests can exercise real
# file parsing (xref, streams, DecodeParms, page selection) without any
# owner document or external tool. Fictional content only (PRIV-1).
#
# Ruby 2.2 compatible syntax throughout (RB22).

module SyntheticPdfBuilder
  module_function

  # Serialize a stream object body. `dict_entries` is the inner dictionary
  # text WITHOUT /Length (added here). Returns the object body string.
  def stream_object(dict_entries, data)
    bin = data.dup
    bin.force_encoding(Encoding::BINARY) if bin.respond_to?(:force_encoding)
    head = "<< #{dict_entries} /Length #{bin.bytesize} >>\nstream\n".dup
    head.force_encoding(Encoding::BINARY) if head.respond_to?(:force_encoding)
    tail = "\nendstream".dup
    tail.force_encoding(Encoding::BINARY) if tail.respond_to?(:force_encoding)
    head + bin + tail
  end

  # Write a PDF whose objects 1..n are the given bodies (object i is
  # bodies[i - 1]). Object 1 must be the catalog. Returns the path.
  def write(path, bodies)
    out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".dup
    out.force_encoding(Encoding::BINARY) if out.respond_to?(:force_encoding)
    offsets = []
    bodies.each_with_index do |body, index|
      offsets << out.bytesize
      chunk = "#{index + 1} 0 obj\n".dup
      chunk.force_encoding(Encoding::BINARY) if chunk.respond_to?(:force_encoding)
      body_bin = body.dup
      body_bin.force_encoding(Encoding::BINARY) if body_bin.respond_to?(:force_encoding)
      out << chunk << body_bin << "\nendobj\n"
    end
    xref_offset = out.bytesize
    out << "xref\n0 #{bodies.length + 1}\n"
    out << "0000000000 65535 f \n"
    offsets.each { |offset| out << format("%010d 00000 n \n", offset) }
    out << "trailer\n<< /Size #{bodies.length + 1} /Root 1 0 R >>\n"
    out << "startxref\n#{xref_offset}\n%%EOF\n"
    File.open(path, 'wb') { |f| f.write(out) }
    path
  end

  # Convenience: a document whose pages each carry one content stream and an
  # optional shared /XObject resource dictionary text (e.g. "/Im0 9 0 R").
  # `page_streams` is an array of content-stream strings; extra objects are
  # appended after the page objects and can be referenced by number:
  # object numbering is 1 catalog, 2 pages, 3..(2+n) page dicts,
  # (3+n)..(2+2n) content streams, then extras in order.
  def write_pages(path, page_streams, extras = [], xobject_entries = nil, media_box = '0 0 200 100')
    n = page_streams.length
    bodies = []
    bodies << "<< /Type /Catalog /Pages 2 0 R >>"
    kids = (0...n).map { |i| "#{3 + i} 0 R" }.join(' ')
    bodies << "<< /Type /Pages /Kids [#{kids}] /Count #{n} >>"
    n.times do |i|
      resources = xobject_entries ? "/Resources << /XObject << #{xobject_entries} >> >>" : '/Resources << >>'
      bodies << "<< /Type /Page /Parent 2 0 R /MediaBox [#{media_box}] " \
                "#{resources} /Contents #{3 + n + i} 0 R >>"
    end
    page_streams.each { |stream| bodies << stream_object('', stream) }
    extras.each { |body| bodies << body }
    write(path, bodies)
  end

  def first_extra_object_number(page_count)
    3 + (2 * page_count)
  end
end
