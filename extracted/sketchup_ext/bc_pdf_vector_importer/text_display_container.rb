# Empty identity parents are created before source claims. SketchUp 2017 can
# relocate an existing nested claim when add_group([claim]) is used later.
require File.join(File.dirname(__FILE__), 'representation_fidelity')

module BlueCollarSystems
  module PDFVectorImporter
    module TextDisplayContainer
      DICTIONARY = 'BC_PDF_Importer'.freeze
      IDENTITY = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
                  0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0].freeze

      def self.create!(entities, source_id, layer = nil, source_kind = :text_span)
        unless [:text_span, :svg_glyph_placement].include?(source_kind)
          raise RepresentationFidelity::ContractError, 'unknown text display source identity kind'
        end
        before = entities.to_a
        container = entities.add_group
        unless container && !before.include?(container) &&
               entities.to_a.count { |entry| entry == container } == 1 &&
               container.typename.to_s == 'Group' && container.entities.to_a.empty?
          raise RepresentationFidelity::ContractError,
                'dedicated empty text display container was not created'
        end
        container.set_attribute(DICTIONARY, 'decorative_text_container', true)
        container.set_attribute(DICTIONARY, 'decorative_source_span_id', source_id.to_s)
        container.set_attribute(DICTIONARY, 'decorative_source_kind', source_kind.to_s)
        if layer
          container.layer = layer
          unless container.layer == layer
            raise RepresentationFidelity::ContractError, 'host ignored text display container layer'
          end
        end
        verify_identity!(container)
        container
      rescue StandardError
        if container && before && !before.include?(container) && entities.to_a.include?(container)
          RepresentationFidelity.erase_owned!(entities, [container])
        end
        raise
      end

      def self.verify_identity!(container)
        unless container.get_attribute(DICTIONARY, 'decorative_text_container', false) == true &&
               container.get_attribute(DICTIONARY, 'source_span_id', '').to_s.empty? &&
               container.get_attribute(DICTIONARY, 'decorative_text_wrapper', false) == false &&
               container.hidden? == false && container.material.nil? &&
               container.transformation.to_a == IDENTITY
          raise RepresentationFidelity::ContractError,
                'text display container is not an inactive identity parent'
        end
        true
      end

      def self.verify_claim!(container, claim = nil)
        verify_identity!(container)
        children = container.entities.to_a
        unless children.length == 1 && (!claim || children.first == claim)
          raise RepresentationFidelity::ContractError,
                'text display container does not own exactly its original claim'
        end
        source_id = container.get_attribute(DICTIONARY, 'decorative_source_span_id', '').to_s
        claim = children.first
        source_kind = container.get_attribute(DICTIONARY, 'decorative_source_kind', '').to_s
        identity_matches = if source_kind == 'text_span'
                             claim.get_attribute(DICTIONARY, 'source_span_id', '').to_s == source_id
                           elsif source_kind == 'svg_glyph_placement'
                             claim.get_attribute(DICTIONARY, 'source_kind', '') == source_kind &&
                               claim.get_attribute(DICTIONARY, 'source_unit_id', '').to_s == source_id &&
                               claim.get_attribute(DICTIONARY, 'source_span_id', '').to_s.empty?
                           else
                             false
                           end
        unless !source_id.empty? && identity_matches
          raise RepresentationFidelity::ContractError,
                'text display container source identity differs from its claim'
        end
        true
      end
    end
  end
end
