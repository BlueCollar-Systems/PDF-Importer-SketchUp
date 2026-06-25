# bc_pdf_vector_importer/version_notice.rb
# One-time notice when the extension version changes after install/update.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module VersionNotice
      PREF_KEY = 'bc_pdf_vector_importer'.freeze
      PREF_INSTALLED = 'installed_version'.freeze

      class << self
        def check
          return unless defined?(Sketchup) && Sketchup.respond_to?(:read_default)

          previous = Sketchup.read_default(PREF_KEY, PREF_INSTALLED, nil)
          current = defined?(PLUGIN_VERSION) ? PLUGIN_VERSION : nil
          return unless current

          if previous && previous.to_s != current.to_s
            UI.messagebox(
              "PDF Vector Importer updated from v#{previous} to v#{current}.\n\n" \
              "If you skipped versions, run Extensions → PDF Vector Importer → " \
              "Compatibility Report once and retest a Tier-1 PDF before shop use."
            )
          end
          Sketchup.write_default(PREF_KEY, PREF_INSTALLED, current)
        rescue StandardError => e
          Logger.warn('VersionNotice', "check failed: #{e.message}") if defined?(Logger)
        end
      end
    end
  end
end
