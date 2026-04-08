# bc_pdf_vector_importer.rb
# Root loader for the PDF Vector Importer SketchUp Extension
# CI-tested across Ruby 2.2 / 2.7 / 3.0 / 3.2 (SketchUp Make 2017 baseline through current releases).
#
# Copyright 2024-2026 BlueCollar Systems
# License: MIT
# BUILT. NOT BOUGHT.
#
# AI Contributors: Claude & Claude Code (Anthropic), ChatGPT & Codex (OpenAI),
#   Gemini (Google), Microsoft Copilot — collaborative AI development partners.

require 'sketchup.rb'
require 'extensions.rb'

module BlueCollarSystems
  module PDFVectorImporter

    PLUGIN_ID       = 'bc_pdf_vector_importer'.freeze
    PLUGIN_NAME     = 'PDF Vector Importer'.freeze
    PLUGIN_VERSION  = '3.6.8'.freeze
    PLUGIN_DIR      = File.join(File.dirname(__FILE__), PLUGIN_ID).freeze

    extension = SketchupExtension.new(PLUGIN_NAME, File.join(PLUGIN_ID, 'main'))
    extension.creator     = 'BlueCollar Systems'
    extension.description = 'Import PDF vector geometry as native editable SketchUp edges. ' \
                            'Features arc reconstruction, color-based tag grouping, ' \
                            'text import, dash patterns, Scale by Reference tool, ' \
                            'scanned-page detection warnings, and full Bezier support. ' \
                            'CI-tested: Ruby 2.2, 2.7, 3.0, and 3.2 (SketchUp Make 2017+ baseline).'
    extension.version     = PLUGIN_VERSION
    extension.copyright   = '2024-2026 BlueCollar Systems'

    Sketchup.register_extension(extension, true)

  end
end
