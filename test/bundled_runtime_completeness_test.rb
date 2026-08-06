#!/usr/bin/env ruby
# frozen_string_literal: true

# Every bundled helper must be loadable on a machine that has nothing installed
# but Windows itself.
#
# The RBZ ships Poppler EXEs and their support DLLs. Those binaries were built
# against the Visual C++ runtime, so they import VCRUNTIME140.dll,
# VCRUNTIME140_1.dll and MSVCP140.dll. Those three come from a Visual C++
# *redistributable*, not from Windows -- unlike ucrtbase.dll, which is part of
# the OS. SketchUp 2017 bundles no CRT of its own, so installing SketchUp does
# not supply them either.
#
# On a developer machine they sit in System32 (some other tool installed the
# redist), every helper launches, and every runtime test is green. On a clean
# customer PC the loader kills the helper before main() and pdftocairo -- the
# renderer behind the terminal Raster rung -- cannot start. Because
# DependencyResolver checks availability with File.exist? only, the helper is
# still reported as "found".
#
# A runtime test cannot see this bug on the machine that has the DLLs. Reading
# the PE import table can. That is the whole point of this file: it is the one
# gate that fails HERE for a defect that only bites THERE.
#
# Pure Ruby 2.2 (SketchUp 2017 ships Ruby 2.2.4): no &., no Integer#positive?,
# no <<~ heredocs, no unpack1, no Array#sum.

require 'minitest/autorun'

class BundledRuntimeCompletenessTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)

  BIN_DIRS = [
    File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer',
              'Library', 'bin'),
    File.join(REPO_ROOT, 'sketchup_ext', 'bc_pdf_vector_importer',
              'Library', 'bin')
  ].freeze

  # Supplied by base Windows. Anything imported and not in here (and not
  # bundled) must ship beside the binary.
  OS_PREFIXES = ['api-ms-win-', 'ext-ms-win-'].freeze
  OS_DLLS = %w[
    kernel32.dll user32.dll gdi32.dll advapi32.dll shell32.dll ole32.dll
    oleaut32.dll ws2_32.dll wldap32.dll crypt32.dll bcrypt.dll ncrypt.dll
    secur32.dll winmm.dll comdlg32.dll comctl32.dll shlwapi.dll version.dll
    psapi.dll userenv.dll netapi32.dll iphlpapi.dll dnsapi.dll winspool.drv
    msimg32.dll imm32.dll setupapi.dll cfgmgr32.dll powrprof.dll dwmapi.dll
    uxtheme.dll rpcrt4.dll sechost.dll ntdll.dll msvcrt.dll normaliz.dll
    usp10.dll gdiplus.dll winhttp.dll wintrust.dll authz.dll mpr.dll
    wtsapi32.dll dbghelp.dll d3d11.dll dxgi.dll opengl32.dll glu32.dll
    ucrtbase.dll
  ].freeze

  # Ships with a Visual C++ redistributable. Never assume these are present.
  REDIST_CRT = %w[
    vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll
    msvcp140_2.dll concrt140.dll vcomp140.dll vccorlib140.dll
  ].freeze

  def bin_dir
    BIN_DIRS.find { |d| File.directory?(d) }
  end

  # --- minimal PE import-table reader ---------------------------------------

  def u16(data, offset)
    data[offset, 2].unpack('v')[0]
  end

  def u32(data, offset)
    data[offset, 4].unpack('V')[0]
  end

  def pe_imported_dlls(path)
    data = File.open(path, 'rb') { |f| f.read }
    return [] if data.nil? || data.bytesize < 0x40
    return [] unless data[0, 2] == 'MZ'

    pe_offset = u32(data, 0x3C)
    return [] if pe_offset.nil? || pe_offset + 24 > data.bytesize
    return [] unless data[pe_offset, 4] == "PE\0\0"

    section_count = u16(data, pe_offset + 6)
    optional_size = u16(data, pe_offset + 20)
    optional_offset = pe_offset + 24
    magic = u16(data, optional_offset)
    # PE32+ has a larger optional header before the data directories.
    dir_offset = optional_offset + (magic == 0x20B ? 112 : 96)
    return [] if dir_offset + 16 > data.bytesize

    import_rva = u32(data, dir_offset + 8)
    return [] if import_rva.nil? || import_rva.zero?

    sections = []
    section_base = optional_offset + optional_size
    section_count.times do |i|
      entry = section_base + (i * 40)
      break if entry + 40 > data.bytesize
      sections << {
        :vaddr => u32(data, entry + 12), :vsize => u32(data, entry + 8),
        :praw => u32(data, entry + 20), :rawsize => u32(data, entry + 16)
      }
    end

    to_offset = lambda do |rva|
      hit = sections.find do |s|
        span = s[:vsize] > s[:rawsize] ? s[:vsize] : s[:rawsize]
        rva >= s[:vaddr] && rva < s[:vaddr] + span
      end
      next nil if hit.nil?
      offset = hit[:praw] + (rva - hit[:vaddr])
      offset < data.bytesize ? offset : nil
    end

    read_cstring = lambda do |offset|
      terminator = data.index("\0", offset)
      terminator.nil? ? '' : data[offset...terminator]
    end

    names = []
    base = to_offset.call(import_rva)
    return [] if base.nil?
    index = 0
    while index < 4096
      entry = base + (index * 20)
      break if entry + 20 > data.bytesize
      name_rva = u32(data, entry + 12)
      break if name_rva.nil? || (name_rva.zero? && u32(data, entry).to_i.zero?)
      offset = to_offset.call(name_rva)
      unless offset.nil?
        name = read_cstring.call(offset)
        names << name unless name.empty?
      end
      index += 1
    end
    names
  end

  # --- the gate --------------------------------------------------------------

  def test_no_bundled_helper_imports_an_unbundled_runtime
    directory = bin_dir
    skip 'no bundled Library/bin in this checkout' if directory.nil?

    binaries = Dir.glob(File.join(directory, '*')).select do |path|
      File.file?(path) && ['.exe', '.dll'].include?(File.extname(path).downcase)
    end
    refute_empty binaries, "no bundled binaries found under #{directory}"

    bundled = binaries.map { |p| File.basename(p).downcase }
    offenders = {}

    binaries.each do |path|
      pe_imported_dlls(path).each do |dll|
        key = dll.downcase
        next if bundled.include?(key)
        next if OS_DLLS.include?(key)
        next if OS_PREFIXES.any? { |prefix| key.start_with?(prefix) }
        offenders[dll] ||= []
        offenders[dll] << File.basename(path)
      end
    end

    return if offenders.empty?

    lines = offenders.keys.sort.map do |dll|
      note = REDIST_CRT.include?(dll.downcase) ? ' [Visual C++ redistributable]' : ''
      "  #{dll}#{note}\n      needed by: #{offenders[dll].sort.join(', ')}"
    end
    flunk(
      "Bundled helpers import DLLs that are neither bundled nor part of " \
      "Windows.\nOn a clean customer PC these fail to load before main(), and " \
      "the\nexistence-only availability check still reports them as found:\n" +
      lines.join("\n")
    )
  end

  # Guards the guard: if the allowlists ever swallow the CRT, this notices.
  def test_redistributable_crt_is_never_treated_as_an_os_dll
    REDIST_CRT.each do |dll|
      refute_includes OS_DLLS, dll,
                      "#{dll} ships with a Visual C++ redistributable, not " \
                      'with Windows; it must not be allowlisted as an OS DLL'
    end
    assert_includes OS_DLLS, 'ucrtbase.dll',
                    'ucrtbase.dll IS part of Windows 10+ and must stay allowlisted'
  end
end
