# bc_pdf_vector_importer/source_provenance.rb
# Minimal source provenance sidecar builder (bcs.source_provenance/1.0)
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'
require 'digest'
require 'fileutils'
require 'time'

module BlueCollarSystems
  module PDFVectorImporter
    module SourceProvenance

      SCHEMA = 'bcs.source_provenance/1.0'.freeze

      module_function

      def new_import_session_id
        require 'securerandom'
        SecureRandom.uuid
      rescue StandardError
        "su-import-#{Process.pid}-#{Time.now.to_i}"
      end

      def sha256_file(path)
        return '' unless path && File.file?(path)
        Digest::SHA256.file(path).hexdigest
      rescue StandardError
        ''
      end

      def build_manifest(import_session_id:, pdf_path:, objects:, version:, page_count: nil)
        source_pdf = { path: pdf_path.to_s }
        digest = sha256_file(pdf_path)
        source_pdf[:sha256] = digest unless digest.empty?
        source_pdf[:page_count] = page_count.to_i if page_count && page_count.to_i > 0

        {
          schema: SCHEMA,
          import_session_id: import_session_id.to_s,
          importer: {
            name: 'sketchup',
            version: version.to_s,
            build: ['sketchup', version.to_s].join(' ')
          },
          source_pdf: source_pdf,
          objects: normalize_objects(objects)
        }
      end

      def write_sidecar(output_path:, import_session_id:, pdf_path:, objects:, version:, page_count: nil)
        manifest = build_manifest(
          import_session_id: import_session_id,
          pdf_path: pdf_path,
          objects: objects,
          version: version,
          page_count: page_count
        )
        path = output_path.to_s
        parent = File.dirname(path)
        FileUtils.mkdir_p(parent) unless parent.empty? || File.directory?(parent)
        File.write(path, JSON.pretty_generate(manifest) + "\n", encoding: 'UTF-8')
        path
      rescue StandardError => e
        Logger.warn('SourceProvenance', "write_sidecar failed: #{e.message}")
        nil
      end

      def default_sidecar_path(pdf_path)
        base = File.basename(pdf_path.to_s, '.pdf')
        File.join(File.dirname(pdf_path.to_s), "#{base}_source_provenance.json")
      end

      def record_image_provenance(bucket, page:, name:, image_path:, source_bbox_pdf: nil)
        return unless bucket.is_a?(Array)
        idx = bucket.length
        entry = {
          object_id: "embedded_image:#{page}:#{idx}",
          page: page.to_i,
          source_kind: 'embedded_image',
          created_entity_type: 'sketchup_image',
          image_name: name.to_s
        }
        entry[:image_path] = image_path.to_s unless image_path.to_s.empty?
        entry[:source_bbox_pdf] = source_bbox_pdf if source_bbox_pdf.is_a?(Array) && source_bbox_pdf.length >= 4
        bucket << entry
      end

      def normalize_objects(objects)
        Array(objects).map do |entry|
          next entry unless entry.is_a?(Hash)
          out = {}
          entry.each do |key, value|
            sym = key.is_a?(Symbol) ? key : key.to_sym
            out[sym] = value unless value.nil?
          end
          out
        end
      end

    end
  end
end
