# bc_pdf_vector_importer/recognizer.rb
# Recognition Pipeline — runs generic document analysis.
#
# Modes:
#   :none    → skip recognition entirely (fastest import)
#   :generic → generic classifier + recognizer only
#   :auto    → profile page, then run generic recognition
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module Recognizer

      def self.run(page_data, mode: :auto, config: nil)
        config ||= RecognitionConfig.default

        if mode == :none
          return { generic: nil, mode_used: :none }
        end

        # Always run generic recognition
        generic = GenericRecognizer.analyze(page_data, config)

        # Profile the page type for reporting
        effective_mode = mode
        if mode == :auto
          suggested = DocumentProfiler.suggest_mode(generic.page_profile)
          # Only use :generic or :none — no domain-specific modes
          effective_mode = (suggested == :none) ? :none : :generic
        end

        {
          generic: generic,
          mode_used: effective_mode,
          page_profile: generic.page_profile
        }
      end

    end
  end
end
