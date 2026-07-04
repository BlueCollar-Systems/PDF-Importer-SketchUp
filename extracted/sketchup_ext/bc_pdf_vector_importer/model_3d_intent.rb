# bc_pdf_vector_importer/model_3d_intent.rb
# Lightweight text-evidence scan for optional PDF-to-3D generation.

module BlueCollarSystems
  module PDFVectorImporter
    module Model3DIntent
      module_function

      FRACTION = '(?:\d+(?:\s+\d+/\d+)?|\d+/\d+|\d+(?:\.\d+)?)'.freeze
      PLATE_RE = Regexp.new(
        '\bPL\s*(' + FRACTION + ')\s*"?\s*[xX]\s*(' + FRACTION + ')\s*"?' \
        '(?:\s*[xX]\s*([0-9\'\-\s/\."]+))?'
      )
      MEMBER_RE = Regexp.new(
        '\b(?:W|S|M|HP|WT|MT|ST|C|MC)\s?\d{1,3}\s?[xX]\s?\d{1,3}(?:\.\d+)?\b' \
        '|\bL\s?\d{1,2}\s?[xX]\s?\d{1,2}\s?[xX]\s?' + FRACTION + '\b' \
        '|\bHSS\s?\d{1,2}(?:\.\d+)?\s?[xX]\s?\d{1,2}(?:\.\d+)?\s?[xX]\s?' + FRACTION + '\b' \
        '|\bPIPE\s?\d{1,2}\s?(?:STD|XS|XXS)\b'
      )
      MAX_CANDIDATES = 50

      def analyze(texts, opts = {})
        host_supports_3d = opts.key?(:host_supports_3d) ? !!opts[:host_supports_3d] : true
        plates = []
        members = []
        seen_plates = {}
        seen_members = {}

        Array(texts).each do |item|
          raw = text_from(item)
          next if raw.empty?

          scan_plates(raw, plates, seen_plates)
          scan_members(raw, members, seen_members)
        end

        evidence = !plates.empty? || !members.empty?
        reason = nil
        if !host_supports_3d
          reason = 'SketchUp/FreeCAD/Blender can generate solids; this host cannot.'
        elsif !evidence
          reason = 'No plate thickness callouts or rolled-shape designations found; the drawing does not carry enough third-dimension data for an honest 3D model.'
        end

        {
          feasible: host_supports_3d && evidence,
          plates: plates,
          members: members,
          skipped_reason: reason
        }
      rescue StandardError => e
        {
          feasible: false,
          plates: [],
          members: [],
          skipped_reason: "3D intent analysis failed: #{e.message}"
        }
      end

      def text_from(item)
        if item.respond_to?(:text)
          item.text.to_s.strip
        elsif item.is_a?(Hash)
          (item[:text] || item['text']).to_s.strip
        else
          item.to_s.strip
        end
      end

      def scan_plates(raw, plates, seen)
        raw.scan(PLATE_RE) do |match|
          break if plates.length >= MAX_CANDIDATES
          thickness = match[0].to_s.strip
          width = match[1].to_s.strip
          length = match[2].to_s.strip
          key = [thickness, width, length].join('|')
          next if seen[key]
          seen[key] = true
          candidate = {
            raw_text: raw,
            thickness: thickness,
            width: width
          }
          candidate[:length] = length unless length.empty?
          plates << candidate
        end
      end

      def scan_members(raw, members, seen)
        raw.scan(MEMBER_RE) do
          break if members.length >= MAX_CANDIDATES
          designation = Regexp.last_match[0].to_s.gsub(/\s+/, '').upcase
          next if designation.empty? || seen[designation]
          seen[designation] = true
          members << {
            raw_text: raw,
            designation: designation
          }
        end
      end
    end
  end
end
