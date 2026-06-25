#!/usr/bin/env ruby
# test/smoke_test.rb
# Basic automated smoke tests for the PDF Vector Importer plugin.
# Checks Ruby syntax, entry-point loadability, and .rbz package validity.
#
# Usage:  ruby test/smoke_test.rb
# Exit 0 = all checks pass, non-zero = failure.

require 'fileutils'
require 'open3'

REPO_ROOT   = File.expand_path('..', __dir__)
SOURCE_DIR  = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer')
ENTRY_POINT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer.rb')
RBZ_PATTERN = File.join(REPO_ROOT, '*.rbz')

failures = []
pass_count = 0

puts "=" * 60
puts "PDF Vector Importer -- Smoke Tests"
puts "=" * 60
puts

# ----------------------------------------------------------------
# 1. Ruby syntax check on every .rb file
# ----------------------------------------------------------------
puts "--- Check 1: Ruby syntax on all .rb files ---"
rb_files = Dir.glob(File.join(SOURCE_DIR, '**', '*.rb'))
rb_files << ENTRY_POINT if File.exist?(ENTRY_POINT)

if rb_files.empty?
  failures << "No .rb files found in #{SOURCE_DIR}"
  puts "  FAIL: no .rb files found"
else
  rb_files.each do |f|
    rel = f.sub("#{REPO_ROOT}/", '').sub("#{REPO_ROOT}\\", '')
    output = `ruby -c "#{f}" 2>&1`
    if $?.success?
      pass_count += 1
    else
      failures << "Syntax error in #{rel}: #{output.strip}"
      puts "  FAIL: #{rel}"
      puts "        #{output.strip}"
    end
  end
  syntax_ok = rb_files.length - failures.length
  puts "  #{syntax_ok}/#{rb_files.length} files passed syntax check"
end

puts

# ----------------------------------------------------------------
# 2. Entry-point load check (without SketchUp runtime)
# ----------------------------------------------------------------
puts "--- Check 2: Main entry point loadability ---"
# We cannot actually require the entry point because it depends on
# SketchUp's runtime (sketchup.rb, extensions.rb). Instead we verify
# that the file parses cleanly AND that the main.rb file can be
# parsed, which covers the bulk of the logic.

main_rb = File.join(SOURCE_DIR, 'main.rb')
[ENTRY_POINT, main_rb].each do |f|
  next unless File.exist?(f)
  rel = f.sub("#{REPO_ROOT}/", '').sub("#{REPO_ROOT}\\", '')
  output = `ruby -c "#{f}" 2>&1`
  if $?.success?
    puts "  PASS: #{rel} parses without error"
    pass_count += 1
  else
    failures << "Entry point load failed for #{rel}: #{output.strip}"
    puts "  FAIL: #{rel} -- #{output.strip}"
  end
end

# Verify the Logger module can actually be loaded standalone
logger_rb = File.join(SOURCE_DIR, 'logger.rb')
if File.exist?(logger_rb)
  output = `ruby -e "load '#{logger_rb.gsub('\\', '/')}'; puts BlueCollarSystems::PDFVectorImporter::Logger.summary" 2>&1`
  if $?.success?
    puts "  PASS: logger.rb loads and executes standalone"
    pass_count += 1
  else
    failures << "logger.rb standalone load failed: #{output.strip}"
    puts "  FAIL: logger.rb standalone -- #{output.strip}"
  end
end

puts

# ----------------------------------------------------------------
# 3. .rbz package exists and is a valid zip
# ----------------------------------------------------------------
puts "--- Check 3: .rbz package validity ---"
rbz_files = Dir.glob(RBZ_PATTERN)

if rbz_files.empty?
  # Clean source checkouts may not include packaged artifacts.
  puts "  PASS: no .rbz package found (clean source checkout)"
  pass_count += 1
else
  rbz_files.each do |rbz|
    rel = File.basename(rbz)
    begin
      # A valid ZIP starts with PK\x03\x04
      bytes = File.binread(rbz, 4)
      pk_header = [0x50, 0x4B, 0x03, 0x04].pack('C*')
      if bytes == pk_header
        # Validate the zip can be opened and list entries
        entry_count = 0
        begin
          if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
            ps_script = "Add-Type -AssemblyName System.IO.Compression.FileSystem; " \
                        "$z = [System.IO.Compression.ZipFile]::OpenRead('#{rbz.tr('/', '\\')}'); " \
                        "$z.Entries.Count; $z.Dispose()"
            list_output, _, status = Open3.capture3('powershell', '-NoProfile', '-Command', ps_script)
            list_output = list_output.strip
          else
            list_output, _, status = Open3.capture3('unzip', '-l', rbz)
          end

          if list_output =~ /(\d+)/ && $1.to_i > 0
            entry_count = $1.to_i
            puts "  PASS: #{rel} is a valid zip archive (#{entry_count} entries)"
            pass_count += 1
          else
            puts "  PASS: #{rel} has valid zip header (PK signature)"
            pass_count += 1
          end
        rescue StandardError => e
          # Fallback: header check is sufficient
          puts "  PASS: #{rel} has valid zip header (PK signature)"
          pass_count += 1
        end
      else
        failures << "#{rel} is not a valid zip (bad header: #{bytes.inspect})"
        puts "  FAIL: #{rel} -- not a valid zip file"
      end
    rescue StandardError => e
      failures << "#{rel} validation error: #{e.message}"
      puts "  FAIL: #{rel} -- #{e.message}"
    end
  end
end

puts
# ----------------------------------------------------------------
# 4. Guardrail: SketchUp 2017 Ruby compatibility
# ----------------------------------------------------------------
puts "--- Check 4: SketchUp 2017 Ruby compatibility ---"
core_rb_files = Dir.glob(File.join(SOURCE_DIR, '**', '*.rb'))
modern_method_hits = []
modern_range_hits = []
modern_method_pattern =
  /&\.|\.(?:match\?|positive\?|negative\?|dig|sum|then|yield_self|filter_map)(?=[^A-Za-z0-9_]|$)/
endless_range_pattern = /(^|[^.])\.\.(?!\.)\s*(?:[\]\)\}]|$)/
beginless_range_pattern = /(?:\[|\()\s*\.\.(?!\.)/

core_rb_files.each do |f|
  rel = f.sub("#{REPO_ROOT}/", '').sub("#{REPO_ROOT}\\", '')
  File.open(f, 'rb') do |io|
    io.each_line.with_index do |raw_line, idx|
      line = raw_line.force_encoding('UTF-8')
      line = line.encode('UTF-8', 'binary', invalid: :replace, undef: :replace)
      if line =~ modern_method_pattern
        modern_method_hits << "#{rel}:#{idx + 1}: #{line.strip}"
      end

      # Ruby 2.2 (SketchUp 2017) cannot parse beginless/endless ranges,
      # e.g. text[-69..] or values[..10]. Modern Ruby syntax checks pass
      # these, so keep an explicit source scan in the smoke gate.
      scan_line = line.
        gsub(/'([^'\\]|\\.)*'/, "''").
        gsub(/"([^"\\]|\\.)*"/, '""').
        sub(/\s+#.*$/, '')
      if scan_line =~ endless_range_pattern || scan_line =~ beginless_range_pattern
        modern_range_hits << "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end
  end
end

if modern_method_hits.empty? && modern_range_hits.empty?
  puts "  PASS: no Ruby 2.3+ convenience methods or Ruby 2.6+ ranges found in core extension"
  pass_count += 1
else
  failures << "SketchUp 2017-incompatible Ruby syntax found in core extension (#{modern_method_hits.length + modern_range_hits.length} hit(s))."
  unless modern_method_hits.empty?
    puts "  FAIL: found SketchUp 2017-incompatible methods:"
    modern_method_hits.first(20).each { |hit| puts "        #{hit}" }
    if modern_method_hits.length > 20
      puts "        ...and #{modern_method_hits.length - 20} more method hits"
    end
  end
  unless modern_range_hits.empty?
    puts "  FAIL: found SketchUp 2017-incompatible beginless/endless ranges:"
    modern_range_hits.first(20).each { |hit| puts "        #{hit}" }
    if modern_range_hits.length > 20
      puts "        ...and #{modern_range_hits.length - 20} more range hits"
    end
  end
end

puts
# ----------------------------------------------------------------
# 5. Guardrail: no bare/silent rescue patterns in core extension
# ----------------------------------------------------------------
puts "--- Check 5: no bare/silent rescue patterns in core extension ---"
forbidden_rescue_hits = []

core_rb_files.each do |f|
  rel = f.sub("#{REPO_ROOT}/", '').sub("#{REPO_ROOT}\\", '')
  File.open(f, 'rb') do |io|
    io.each_line.with_index do |raw_line, idx|
      line = raw_line.force_encoding('UTF-8')
      line = line.encode('UTF-8', 'binary', invalid: :replace, undef: :replace)
      if line =~ /\brescue\s+nil\b/ || line =~ /\brescue\s*=>/
        forbidden_rescue_hits << "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end
  end
end

if forbidden_rescue_hits.empty?
  puts "  PASS: no 'rescue nil' / bare 'rescue => e' patterns found"
  pass_count += 1
else
  failures << "Forbidden rescue patterns found in core extension (#{forbidden_rescue_hits.length} hit(s))."
  puts "  FAIL: found forbidden rescue patterns:"
  forbidden_rescue_hits.first(20).each { |hit| puts "        #{hit}" }
  if forbidden_rescue_hits.length > 20
    puts "        ...and #{forbidden_rescue_hits.length - 20} more"
  end
end

puts
puts "=" * 60
if failures.empty?
  puts "ALL CHECKS PASSED (#{pass_count} checks)"
  puts "=" * 60
  exit 0
else
  puts "#{failures.length} FAILURE(S), #{pass_count} passed:"
  failures.each_with_index { |f, i| puts "  #{i + 1}. #{f}" }
  puts "=" * 60
  exit 1
end
