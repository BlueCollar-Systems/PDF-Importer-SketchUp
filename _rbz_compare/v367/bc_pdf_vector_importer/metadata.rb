# bc_pdf_vector_importer/metadata.rb
# Attaches SketchUp AttributeDictionary data to groups, components,
# and edges for PDF import metadata (source page, import settings, etc.).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module Metadata

      DICT_NAME = 'BlueCollar_PDF_Import'.freeze

      # ---------------------------------------------------------------
      # Attach a hash of key-value pairs to any SketchUp entity.
      # ---------------------------------------------------------------
      def self.attach(entity, data)
        return unless entity && entity.valid? && data.is_a?(Hash)
        begin
          data.each do |key, value|
            entity.set_attribute(DICT_NAME, key.to_s, value.to_s)
          end
        rescue StandardError => e
          # Attribute writing can fail on some entity types — not critical
          Logger.warn("Metadata", "attach failed: #{e.message}")
        end
      end

      # ---------------------------------------------------------------
      # Read all metadata from an entity
      # ---------------------------------------------------------------
      def self.read(entity)
        return {} unless entity && entity.valid?
        begin
          dict = entity.attribute_dictionary(DICT_NAME)
          return {} unless dict
          result = {}
          dict.each_pair { |k, v| result[k] = v }
          result
        rescue StandardError => e
          Logger.warn("Metadata", "read failed: #{e.message}")
          {}
        end
      end

      # ---------------------------------------------------------------
      # Check if an entity has PDF import metadata
      # ---------------------------------------------------------------
      def self.has_metadata?(entity)
        return false unless entity && entity.valid?
        begin
          dict = entity.attribute_dictionary(DICT_NAME)
          dict && dict.length > 0
        rescue StandardError => e
          Logger.warn("Metadata", "has_metadata? failed: #{e.message}")
          false
        end
      end

      # ---------------------------------------------------------------
      # Get a specific attribute
      # ---------------------------------------------------------------
      def self.get(entity, key, default = nil)
        return default unless entity && entity.valid?
        begin
          entity.get_attribute(DICT_NAME, key.to_s, default)
        rescue StandardError => e
          Logger.warn("Metadata", "get attribute failed: #{e.message}")
          default
        end
      end

      # ---------------------------------------------------------------
      # Remove all PDF import metadata from an entity
      # ---------------------------------------------------------------
      def self.clear(entity)
        return unless entity && entity.valid?
        begin
          entity.delete_attribute(DICT_NAME)
        rescue StandardError => e
          Logger.warn("Metadata", "clear failed: #{e.message}")
        end
      end

      # ---------------------------------------------------------------
      # Generate a text report of metadata on selected entities
      # ---------------------------------------------------------------
      def self.report(entities)
        count = 0
        lines = []
        lines << "=== PDF Import Metadata ==="
        lines << ""

        entities.each do |e|
          next unless e.valid? && has_metadata?(e)
          data = read(e)
          count += 1
          label = e.respond_to?(:name) && !e.name.to_s.empty? ? e.name : e.class.to_s
          lines << "  #{label}: #{data.map { |k, v| "#{k}=#{v}" }.join(', ')}"
        end

        lines << "" << "Total entities with metadata: #{count}"
        lines.join("\n")
      end

    end
  end
end
