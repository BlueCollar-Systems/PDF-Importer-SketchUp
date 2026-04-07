# bc_pdf_vector_importer/ocg_parser.rb
# PDF Optional Content Group (Layer) parser.
# Reads /OCProperties from the PDF catalog, resolves OCG names,
# and tracks BDC/BMC/EMC marked content nesting in content streams
# so entities can be assigned to the correct SketchUp Tags.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class OCGParser

      attr_reader :ocg_names   # { ocg_obj_ref => "Layer Name" }
      attr_reader :layer_list  # Ordered array of unique layer names

      def initialize(pdf_parser)
        @pdf = pdf_parser
        @ocg_names = {}
        @layer_list = []
      end

      # ---------------------------------------------------------------
      # Parse OCG definitions from the PDF catalog
      # ---------------------------------------------------------------
      def parse
        @ocg_names = {}
        @layer_list = []

        # Get the document catalog (/Root)
        return unless @pdf.instance_variable_get(:@trailer)
        trailer = @pdf.instance_variable_get(:@trailer)
        root_ref = trailer['/Root']
        return unless root_ref

        root = @pdf.resolve_object(root_ref)
        root_dict = to_dict(root)
        return unless root_dict

        # Look for /OCProperties
        oc_props_ref = root_dict['/OCProperties']
        return unless oc_props_ref

        oc_props = @pdf.resolve_object(oc_props_ref)
        oc_dict = to_dict(oc_props)
        return unless oc_dict

        # /OCGs is an array of indirect references to OCG dictionaries
        ocgs_ref = oc_dict['/OCGs']
        return unless ocgs_ref

        ocgs = @pdf.resolve_object(ocgs_ref)
        ocgs = [ocgs] unless ocgs.is_a?(Array)

        ocgs.each do |ref|
          ocg_obj = @pdf.resolve_object(ref)
          ocg_d = to_dict(ocg_obj)
          next unless ocg_d

          # Each OCG dict has /Type /OCG and /Name (string)
          name = ocg_d['/Name']
          if name
            # Clean up the name — remove parentheses from PDF string
            name = name.to_s.gsub(/\A\(/, '').gsub(/\)\z/, '').strip
            name = "Layer_#{@ocg_names.length}" if name.empty?
          else
            name = "Layer_#{@ocg_names.length}"
          end

          # Store mapping from reference string to name
          ref_key = ref.is_a?(String) ? ref : ref.to_s
          @ocg_names[ref_key] = name
          @layer_list << name unless @layer_list.include?(name)
        end

        # Also parse /D (default configuration) for order and visibility
        parse_default_config(oc_dict['/D']) if oc_dict['/D']
      end

      # ---------------------------------------------------------------
      # Track which OCG layer a content stream section belongs to.
      # Call this during content stream parsing when BDC/BMC/EMC are hit.
      #
      # Returns a LayerTracker that manages the nesting stack.
      # ---------------------------------------------------------------
      def create_tracker
        LayerTracker.new(self)
      end

      # ---------------------------------------------------------------
      # Generate SketchUp tag names from OCG layer names
      # ---------------------------------------------------------------
      def sketchup_tag_names
        @layer_list.map { |name| "PDF::Layer::#{name}" }
      end

      private

      def to_dict(obj)
        return obj if obj.is_a?(Hash)
        if obj.is_a?(String) && obj.include?('<<')
          # Attempt to parse as dict
          begin
            @pdf.send(:parse_dict_string, obj)
          rescue StandardError => e
            Logger.warn("OCGParser", "parse_dict_string failed: #{e.message}")
            nil
          end
        else
          nil
        end
      end

      def parse_default_config(d_ref)
        d = @pdf.resolve_object(d_ref)
        d_dict = to_dict(d)
        return unless d_dict

        # /OFF array lists OCGs that are initially hidden
        # /Order array defines display order
        # We could use this to set initial tag visibility in SketchUp
        # For now, just having the layer names is sufficient
      end

      # =============================================
      # LayerTracker — manages BDC/BMC/EMC nesting
      # =============================================
      class LayerTracker

        attr_reader :current_layer

        def initialize(ocg_parser)
          @ocg_parser = ocg_parser
          @stack = []          # Stack of layer names (for nested BDC/EMC)
          @current_layer = nil
        end

        # Called when BDC (begin marked content with properties) is encountered
        # properties_dict should contain /OC reference to an OCG
        def begin_marked_content(tag_name, properties = nil)
          layer_name = nil

          if properties.is_a?(Hash)
            # Look for /OC (Optional Content) key
            oc_ref = properties['/OC']
            if oc_ref
              oc_obj = @ocg_parser.instance_variable_get(:@pdf).resolve_object(oc_ref)
              oc_dict = @ocg_parser.send(:to_dict, oc_obj)
              if oc_dict
                # Could be an OCMD (membership dict) or direct OCG reference
                if oc_dict['/Type'] == '/OCG'
                  name = oc_dict['/Name']
                  if name
                    name = name.to_s.gsub(/\A\(/, '').gsub(/\)\z/, '').strip
                    layer_name = name unless name.empty?
                  end
                elsif oc_dict['/OCGs']
                  # OCMD — resolve first OCG in the list
                  ocg_list = @ocg_parser.instance_variable_get(:@pdf).resolve_object(oc_dict['/OCGs'])
                  if ocg_list.is_a?(Array) && !ocg_list.empty?
                    first_ocg = @ocg_parser.instance_variable_get(:@pdf).resolve_object(ocg_list.first)
                    first_d = @ocg_parser.send(:to_dict, first_ocg)
                    if first_d && first_d['/Name']
                      layer_name = first_d['/Name'].to_s.gsub(/\A\(/, '').gsub(/\)\z/, '').strip
                    end
                  end
                end
              end
            end
          end

          # Also check if the tag name itself maps to a known layer
          if layer_name.nil? && tag_name
            tag_str = tag_name.to_s.gsub(/\A\//, '')
            # Some PDFs use the layer name directly as the tag
            if @ocg_parser.layer_list.include?(tag_str)
              layer_name = tag_str
            end
          end

          @stack.push(layer_name || @current_layer)
          @current_layer = layer_name || @current_layer
        end

        # Called for BMC (begin marked content without properties)
        def begin_marked_content_simple(tag_name)
          begin_marked_content(tag_name, nil)
        end

        # Called when EMC (end marked content) is encountered
        def end_marked_content
          @stack.pop
          @current_layer = @stack.last
        end

        # Reset for a new content stream
        def reset
          @stack.clear
          @current_layer = nil
        end

      end

    end
  end
end
