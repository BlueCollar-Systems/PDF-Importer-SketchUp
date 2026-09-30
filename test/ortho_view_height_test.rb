#!/usr/bin/env ruby
# Parallel-projection height must show the whole sheet, not only its height.

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_bounds'

include BlueCollarSystems::PDFVectorImporter

failures = []
check = lambda do |label, ok|
  failures << label unless ok
end

# Landscape sheet, no viewport yet: a square camera must cover the width.
height = ImportBounds.ortho_view_height(17.0, 11.0, nil, nil)
check.call('unknown window covers the long side', height >= 17.0 * 1.04 - 1e-6)

# Narrow window: height grows so the width still fits.
narrow = ImportBounds.ortho_view_height(17.0, 11.0, 600, 1200)
check.call('narrow window covers width/aspect', narrow >= (17.0 / 0.5) * 1.04 - 1e-6)

# Wide window: the sheet height is enough.
wide = ImportBounds.ortho_view_height(11.0, 17.0, 1600, 900)
check.call('wide window keeps the vertical span', (wide - 17.0 * 1.04).abs < 1e-6)

if failures.empty?
  puts 'ok'
  exit 0
end
warn failures.join("\n")
exit 1
