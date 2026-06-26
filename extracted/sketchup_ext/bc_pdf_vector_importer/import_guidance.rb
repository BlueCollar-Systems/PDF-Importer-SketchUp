# bc_pdf_vector_importer/import_guidance.rb
# One-time pre-import mode guidance for SketchUp users.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ImportGuidance
      PREF_KEY = 'bc_pdf_vector_importer'.freeze
      PREF_DISMISSED = 'import_guidance_dismissed'.freeze

      GUIDANCE_MESSAGE = <<-MSG.strip
Before you import:

• Labels = editable text; Outlines/Glyphs/Geometry = exact vector fidelity.
• 3D Text mode creates extruded shop labels in SketchUp.
• Scale is detected from title blocks when possible; verify Import Health if you see a scale warning.

Choose your PDF next.
      MSG

      class << self
        def maybe_show
          return if ENV['BC_HEADLESS']
          return unless defined?(Sketchup) && Sketchup.respond_to?(:read_default)
          return if Sketchup.read_default(PREF_KEY, PREF_DISMISSED, false)

          UI.messagebox(GUIDANCE_MESSAGE)
          Sketchup.write_default(PREF_KEY, PREF_DISMISSED, true)
        rescue StandardError => e
          Logger.warn('ImportGuidance', "pre-import guidance failed: #{e.message}") if defined?(Logger)
        end

        def reset_for_tests
          return unless defined?(Sketchup) && Sketchup.respond_to?(:write_default)

          Sketchup.write_default(PREF_KEY, PREF_DISMISSED, false)
        rescue StandardError
          nil
        end
      end
    end
  end
end
