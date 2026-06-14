# bc_pdf_vector_importer/layer_manager.rb
# Maps PDF OCG layer names to SketchUp Tags (layers).
# Sanitizes names for SketchUp, deduplicates collisions, and enforces
# a safety cap on layer count per owner Q&A (2026-06-08).
#
# Copyright 2024-2026 BlueCollarSystems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class LayerManager

      MAX_LAYERS = 512

      attr_reader :match_pdf_layers, :base_layer_name, :imported_names, :warning

      # Sanitize a PDF layer name for SketchUp Tags.
      # Mirrors LC/DXF rules: forbidden punctuation → underscore, trim, cap length.
      def self.sanitize_layer_name(name, fallback_index: nil)
        s = name.to_s.strip
        s = s.gsub(/\A\(/, '').gsub(/\)\z/, '')
        s = s.gsub(/[<>\\\/":;?*|=`]/, '_')
        s = s.gsub(/[^\w\s\-_.]/, '_')
        s = s.gsub(/_+/, '_').strip
        s = "PDF_Layer_#{fallback_index}" if s.empty? && fallback_index
        s = 'PDF_Layer' if s.empty?
        s = s[0, 64]
        s
      end

      def initialize(model, base_layer_name: 'PDF Import', match_pdf_layers: true)
        @model = model
        @base_layer_name = base_layer_name.to_s.strip
        @base_layer_name = 'PDF Import' if @base_layer_name.empty?
        @match_pdf_layers = match_pdf_layers != false
        @pdf_to_name = {}
        @used_names = {}
        @imported_names = []
        @warning = nil
        @fallback_index = 0
      end

      def base_layer
        resolve(nil)
      end

      def text_fallback_layer
        return base_layer if @match_pdf_layers
        name = "#{@base_layer_name}:Text"
        ensure_layer(name)
      end

      # Resolve a PDF layer name to a SketchUp layer object.
      # When match_pdf_layers is off, always returns the base import layer.
      def resolve(pdf_layer_name = nil)
        unless @match_pdf_layers
          return ensure_layer(@base_layer_name)
        end

        pdf_key = pdf_layer_name.to_s.strip
        if pdf_key.empty?
          return ensure_layer(@base_layer_name)
        end

        return ensure_layer(@pdf_to_name[pdf_key]) if @pdf_to_name.key?(pdf_key)

        if @imported_names.length >= MAX_LAYERS
          @warning ||= "PDF has more than #{MAX_LAYERS} layers; extra content assigned to '#{@base_layer_name}'."
          return ensure_layer(@base_layer_name)
        end

        @fallback_index += 1
        su_name = unique_name(LayerManager.sanitize_layer_name(pdf_key, fallback_index: @fallback_index))
        @pdf_to_name[pdf_key] = su_name
        @imported_names << su_name unless @imported_names.include?(su_name)
        ensure_layer(su_name)
      end

      def precreate_pdf_layers(pdf_layer_names)
        return unless @match_pdf_layers
        Array(pdf_layer_names).each { |n| resolve(n) }
      end

      def register_imported_names!
        PDFVectorImporter.register_import_layer_names(@imported_names)
      end

      private

      def unique_name(candidate)
        key = candidate.to_s.downcase
        if @used_names[key]
          @used_names[key] += 1
          suffix = "_#{@used_names[key]}"
          base = candidate[0, [64 - suffix.length, 1].max]
          "#{base}#{suffix}"
        else
          @used_names[key] = 1
          candidate
        end
      end

      def ensure_layer(name)
        return nil unless @model && name
        layers = @model.layers
        layer = layers[name]
        layer = layers.add(name) unless layer
        layer
      rescue StandardError => e
        Logger.warn("LayerManager", "ensure_layer failed for '#{name}': #{e.message}")
        nil
      end

    end
  end
end
