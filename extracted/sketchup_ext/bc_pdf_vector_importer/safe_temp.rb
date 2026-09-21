# bc_pdf_vector_importer/safe_temp.rb
#
# The single resolver for every temporary path the importer may hand to a
# bundled helper.
#
# WHY THIS EXISTS
# ---------------
# The bundled Poppler helpers cannot WRITE to a path containing a non-ASCII
# character: their output writers pass the UTF-8 byte string to a byte-oriented
# fopen, so pdftocairo/pdftotext exit non-zero and write nothing. Input paths
# are fine (poppler uses _wfopen for those) -- only the output argument is
# broken, and it breaks on a single character like the u-umlaut in 'Büro'.
#
# Every temp path used to come from Dir.tmpdir, which on Windows is
# %TMP% = C:\Users\<account>\AppData\Local\Temp -- the customer's account name
# is a literal path component. A customer named 'Müller' or 'Иван' therefore
# lost every helper-backed rung, terminal Raster included, silently: the
# helper reported failure with no file, and nothing named the cause.
#
# Resolution order for the root:
#   1. ENV['BC_PDF_TEMP_DIR']            -- if ASCII and writable (support
#      escape hatch; a non-ASCII value is REFUSED, it would reintroduce the
#      defect this module exists to prevent)
#   2. Dir.tmpdir                        -- the normal case; most accounts are
#      ASCII and nothing changes for them
#   3. %ProgramData%\BlueCollarSystems\tmp -- ASCII on every Windows locale
#      (the localized names in Explorer are display aliases; the physical path
#      is C:\ProgramData). Its writability is checked; no administrator
#      permissions, network access, or PATH changes are requested.
# If none is writable and ASCII, raise an actionable Unavailable error. A
# known non-ASCII path cannot serve as a fallback for these helper writers.
#
# Customer-derived filename components (a PDF basename folded into a temp file
# name) go through ascii_component, because an ASCII root does not help if the
# leaf re-imports the customer's alphabet.
#
# Ruby 2.2 compatible (SketchUp 2017 ships 2.2.4): avoids safe navigation and
# squiggly heredocs.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'tmpdir'
require 'fileutils'

module BlueCollarSystems
  module PDFVectorImporter
    module SafeTemp
      ENV_OVERRIDE = 'BC_PDF_TEMP_DIR'.freeze
      class Unavailable < StandardError; end

      class << self
        def root
          @root ||= resolve_root
        end

        # Tests swap the environment; production never calls this.
        def reset!
          @root = nil
        end

        # An explicit diagnostic parent must satisfy the same alphabet rule.
        # The logger uses this to retain writable LOCALAPPDATA/home fallbacks.
        def mktmpdir(prefix, parent = nil)
          if parent && !parent.ascii_only?
            raise ArgumentError, 'Temporary directory parent must be ASCII'
          end
          Dir.mktmpdir(prefix, parent || root)
        end

        def join(*parts)
          File.join(root, *parts)
        end

        # Reduce a customer-derived name to bytes every helper can write.
        # Never returns an empty or dot-only token: a name that sanitises to
        # nothing (e.g. fully CJK) falls back so the caller still gets a
        # usable, unique-enough component.
        def ascii_component(name, fallback = 'item')
          token = name.to_s.gsub(/[^A-Za-z0-9_.\-]/, '_')
          return fallback if token.gsub(/[_.\-]/, '').empty?
          token
        end

        private

        def resolve_root
          override = ENV[ENV_OVERRIDE].to_s
          return override unless override.empty? || !usable?(override)

          tmp = system_tmpdir
          return tmp if tmp && usable?(tmp)

          fallback = program_data_root
          return fallback if fallback

          raise Unavailable,
                'No writable ASCII temporary folder is available. Set ' \
                'BC_PDF_TEMP_DIR to a writable folder with an ASCII-only path ' \
                'and restart SketchUp.'
        end

        def system_tmpdir
          Dir.tmpdir
        rescue StandardError
          nil
        end

        def usable?(dir)
          dir.ascii_only? && writable_dir?(dir)
        end

        def writable_dir?(dir)
          FileUtils.mkdir_p(dir) unless File.directory?(dir)
          probe = File.join(dir, ".bc_probe_#{Process.pid}_#{rand(100_000)}")
          File.open(probe, 'wb') { |handle| handle.write('x') }
          File.delete(probe)
          true
        rescue StandardError
          false
        end

        def program_data_root
          base = ENV['ProgramData'].to_s
          base = 'C:/ProgramData' if base.empty?
          dir = File.join(base, 'BlueCollarSystems', 'tmp')
          usable?(dir) ? dir : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
