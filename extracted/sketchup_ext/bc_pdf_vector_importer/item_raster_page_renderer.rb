# Transparent whole-page rendering for native item Images. Ruby 2.2 compatible.
require 'digest'
require File.join(File.dirname(__FILE__), 'representation_fidelity')

module BlueCollarSystems
  module PDFVectorImporter
    module ItemRasterPageRenderer
      RENDERER = 'ghostscript_transparent_page_crop'.freeze
      # PDF's standard 14 fonts need not be embedded. Only these exact built-in
      # Ghostscript font programs are accepted; a missing arbitrary font is not.
      STANDARD_FONT_PROGRAMS = {
        'Courier' => 'NimbusMonoPS-Regular', 'Courier-Bold' => 'NimbusMonoPS-Bold',
        'Courier-Oblique' => 'NimbusMonoPS-Italic', 'Courier-BoldOblique' => 'NimbusMonoPS-BoldItalic',
        'Helvetica' => 'NimbusSans-Regular', 'Helvetica-Bold' => 'NimbusSans-Bold',
        'Helvetica-Oblique' => 'NimbusSans-Italic', 'Helvetica-BoldOblique' => 'NimbusSans-BoldItalic',
        'Times-Roman' => 'NimbusRoman-Regular', 'Times-Bold' => 'NimbusRoman-Bold',
        'Times-Italic' => 'NimbusRoman-Italic', 'Times-BoldItalic' => 'NimbusRoman-BoldItalic',
        'Symbol' => 'StandardSymbolsPS', 'ZapfDingbats' => 'D050000L'
      }.freeze

      def self.arguments(executable, source, page, dpi, output)
        unless page.is_a?(Integer) && page > 0 && dpi.is_a?(Integer) && dpi > 0
          fail_contract('item Raster page and resolution must be positive integers')
        end
        [executable.to_s, '-dSAFER', '-dBATCH', '-dNOPAUSE',
         '-dPDFSTOPONWARNING', '-dPDFNOCIDFALLBACK',
         '-sDEVICE=pngalpha', "-r#{dpi}", '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
         "-dFirstPage=#{page}", "-dLastPage=#{page}", '-o', output.to_s,
         '-f', source.to_s]
      end

      def self.plan(executable, source, page, dpi, output)
        if executable.to_s.empty? || !File.file?(executable.to_s)
          fail_contract('Ghostscript transparent page renderer is unavailable; repair the importer runtime')
        end
        { :engine => :ghostscript, :renderer => RENDERER,
          :executable => executable.to_s,
          :executable_sha256 => Digest::SHA256.file(executable.to_s).hexdigest,
          :environment => environment(executable),
          :output_path => output.to_s,
          :arguments => arguments(executable, source, page, dpi, output) }
      end

      # A verified argv is insufficient if inherited GS_OPTIONS can filter text
      # or GS_DLL / GS_LIB can replace the implementation and its ROM resources.
      # These overrides are passed only to this child; the host ENV is untouched.
      def self.environment(executable, inherited = ENV)
        result = {}
        inherited.keys.each { |key| result[key] = nil if key.upcase.start_with?('GS_') }
        result['GS_OPTIONS'] = ''
        result['GS_FONTPATH'] = ''
        separator = RUBY_PLATFORM =~ /mswin|mingw|cygwin/ ? ';' : ':'
        result['GS_LIB'] = "%rom%Resource/Init/#{separator}%rom%lib/"
        result['GS_DLL'] = nil
        if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
          dll_name = File.basename(executable.to_s).downcase.include?('32') ? 'gsdll32.dll' : 'gsdll64.dll'
          dll = File.expand_path(File.join(File.dirname(executable.to_s), dll_name))
          result['GS_DLL'] = dll if File.file?(dll)
          system_root = inherited['SystemRoot'] || inherited['SYSTEMROOT']
          unless system_root.to_s.empty?
            result['PATH'] = File.join(system_root.to_s, 'System32')
          end
        end
        result
      end

      def self.ghostscript_command?(argv)
        Array(argv).map(&:to_s).include?('-sDEVICE=pngalpha')
      end

      # Exact allowlist: one original MediaBox canvas with original CropBox
      # clipping and intrinsic PDF rotation,
      # transparent RGBA device, requested DPI, and no extra PostScript code,
      # crop/fit/media overrides, or per-item rendering arguments.
      def self.verify_command!(argv, source, page, dpi)
        args = Array(argv).map(&:to_s)
        unless args.length == 16 && !args[0].empty? && !args[-3].empty? &&
               File.expand_path(args[-1]).downcase == File.expand_path(source.to_s).downcase &&
               args == arguments(args[0], args[-1], page, dpi, args[-3])
          fail_contract('item Raster Ghostscript command is not bound to one transparent MediaBox page')
        end
        true
      end

      def self.validate_result!(run, plan)
        unless run.is_a?(Hash) && run[:ok] == true && run[:exitstatus] == 0 &&
               !run[:timed_out] && run[:error].to_s.empty?
          fail_contract('transparent item Raster page renderer did not complete successfully')
        end
        # Do not certify a repaired, font-substituted, or otherwise warned render
        # as complete merely because the process wrote a PNG and exited zero.
        diagnostics = [run[:stdout], run[:stderr]].map(&:to_s).join("\n")
        diagnostics = diagnostics.lines.reject do |line|
          match = /\ALoading font ([^\r\n]+) \(or substitute\) from %rom%Resource\/Font\/([^\s]+)\s*\z/.match(line)
          match && STANDARD_FONT_PROGRAMS[match[1]] == match[2]
        end.join
        if diagnostics =~ /\b(?:error|warning|unrecoverable|substitut\w*|repair\w*)\b/i
          fail_contract('transparent item Raster renderer reported unverified PDF interpretation')
        end
        output = plan[:output_path].to_s
        unless File.file?(output) && File.size(output) > 0
          fail_contract('transparent item Raster page PNG is missing or empty')
        end
        true
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, message
      end
    end
  end
end
