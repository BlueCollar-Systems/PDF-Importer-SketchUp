#!/usr/bin/env ruby

module SketchupHostEvidence
  class EvidenceError < StandardError; end

  DELIVERY_COLLECTIONS = [
    :text_attempts,
    :page_text_delivery_records,
    :terminal_text_delivery_records,
    :page_representation_fallbacks,
    :raster_delivery_records,
    :source_glyph_physical_deliveries
  ].freeze unless const_defined?(:DELIVERY_COLLECTIONS, false)

  def self.verify_source_locations!(expected_root, locations)
    root = normalized_path(expected_root)
    unless locations.is_a?(Hash) && !locations.empty?
      raise EvidenceError, 'source locations are missing'
    end
    prefix = root.end_with?('/') ? root : "#{root}/"
    locations.each do |name, location|
      unless location.is_a?(Array) && location.length >= 2 &&
             !location[0].to_s.strip.empty? && location[1].to_i > 0
        raise EvidenceError, "#{name} source location is missing"
      end
      source_path = normalized_path(location[0])
      unless source_path.start_with?(prefix)
        raise EvidenceError,
              "#{name} source location is outside expected source root: " \
              "#{location[0]}"
      end
    end
    true
  end

  def self.snapshot_entities(entities)
    unless entities.respond_to?(:to_a)
      raise EvidenceError, 'host entity collection cannot be enumerated'
    end
    Array(entities.to_a).map do |entity|
      snapshot_entity(entity, [])
    end
  rescue EvidenceError
    raise
  rescue StandardError => error
    raise EvidenceError, "host entity snapshot failed: #{error.message}"
  end

  def self.manifest_entity_ids(manifest)
    unless manifest.is_a?(Array)
      raise EvidenceError, 'entity manifest must be an Array'
    end
    ids = []
    collect_manifest_entity_ids(manifest, ids)
    ids.uniq
  end

  def self.verify_delivery_evidence!(stats, manifest)
    unless stats.is_a?(Hash)
      raise EvidenceError, 'pipeline stats are missing'
    end
    if !manifest.is_a?(Array) || manifest.empty?
      raise EvidenceError, 'entity manifest is missing or empty'
    end
    manifest_ids = manifest_entity_ids(manifest)
    raise EvidenceError, 'entity manifest has no host entity IDs' if manifest_ids.empty?

    verify_ready_gate!(stats, :representation_fidelity)
    verify_ready_gate!(stats, :import_contract_ready)

    DELIVERY_COLLECTIONS.each do |collection_name|
      records = hash_value(stats, collection_name)
      next if records.nil?
      unless records.is_a?(Array)
        raise EvidenceError, "#{collection_name} must be an Array"
      end
      records.each_with_index do |record, index|
        verify_delivery_record!(
          collection_name, index, record, manifest_ids
        )
      end
    end
    true
  end

  def self.normalized_path(path)
    text = path.to_s.strip
    raise EvidenceError, 'expected source root is missing' if text.empty?
    expanded = File.expand_path(text)
    expanded = File.realpath(expanded) if File.exist?(expanded)
    expanded.tr('\\', '/').sub(%r{/+\z}, '').downcase
  rescue EvidenceError
    raise
  rescue StandardError => error
    raise EvidenceError, "source path is unreadable: #{error.message}"
  end
  private_class_method :normalized_path

  def self.snapshot_entity(entity, ancestors)
    raise EvidenceError, 'entity manifest contains nil' if entity.nil?
    identity = entity.object_id
    if ancestors.include?(identity)
      raise EvidenceError, 'recursive host entity cycle detected'
    end
    children = child_entities(entity)
    {
      'entity_id' => host_entity_id(entity),
      'typename' => host_typename(entity),
      'valid' => boolean_state(entity, :valid?),
      'deleted' => boolean_state(entity, :deleted?),
      'bounds' => bounds_payload(entity),
      'transformation' => transformation_payload(entity),
      'children' => children.map do |child|
        snapshot_entity(child, ancestors + [identity])
      end
    }
  end
  private_class_method :snapshot_entity

  def self.host_entity_id(entity)
    unless entity.respond_to?(:entityID)
      raise EvidenceError, 'host entity ID is unavailable'
    end
    entity_id = entity.entityID
    unless entity_id.is_a?(Integer) && entity_id > 0
      raise EvidenceError, 'host entity ID must be a positive Integer'
    end
    entity_id
  end
  private_class_method :host_entity_id

  def self.host_typename(entity)
    unless entity.respond_to?(:typename)
      raise EvidenceError, 'host entity typename is unavailable'
    end
    typename = entity.typename.to_s
    raise EvidenceError, 'host entity typename is empty' if typename.empty?
    typename
  end
  private_class_method :host_typename

  def self.boolean_state(entity, method_name)
    return nil unless entity.respond_to?(method_name)
    value = entity.send(method_name)
    return true if value == true
    return false if value == false
    nil
  rescue StandardError
    nil
  end
  private_class_method :boolean_state

  def self.bounds_payload(entity)
    return nil unless entity.respond_to?(:bounds)
    bounds = entity.bounds
    return nil unless bounds && bounds.respond_to?(:min) &&
                      bounds.respond_to?(:max)
    minimum = point_payload(bounds.min)
    maximum = point_payload(bounds.max)
    return nil unless minimum && maximum
    { 'min' => minimum, 'max' => maximum }
  rescue StandardError
    nil
  end
  private_class_method :bounds_payload

  def self.point_payload(point)
    return nil unless point && point.respond_to?(:x) &&
                      point.respond_to?(:y) && point.respond_to?(:z)
    [point.x.to_f, point.y.to_f, point.z.to_f]
  rescue StandardError
    nil
  end
  private_class_method :point_payload

  def self.transformation_payload(entity)
    return nil unless entity.respond_to?(:transformation)
    transformation = entity.transformation
    return nil unless transformation && transformation.respond_to?(:to_a)
    values = transformation.to_a
    return nil unless values.is_a?(Array)
    values.map { |value| value.to_f }
  rescue StandardError
    nil
  end
  private_class_method :transformation_payload

  def self.child_entities(entity)
    collection = if entity.respond_to?(:entities)
                   entity.entities
                 elsif entity.respond_to?(:definition) && entity.definition &&
                       entity.definition.respond_to?(:entities)
                   entity.definition.entities
                 end
    return [] unless collection
    unless collection.respond_to?(:to_a)
      raise EvidenceError, 'nested host entity collection cannot be enumerated'
    end
    Array(collection.to_a)
  end
  private_class_method :child_entities

  def self.collect_manifest_entity_ids(rows, ids)
    rows.each do |row|
      raise EvidenceError, 'entity manifest row must be a Hash' unless row.is_a?(Hash)
      entity_id = hash_value(row, :entity_id)
      unless entity_id.is_a?(Integer) && entity_id > 0
        raise EvidenceError, 'entity manifest row has no positive host entity ID'
      end
      ids << entity_id
      children = hash_value(row, :children)
      children = [] if children.nil?
      unless children.is_a?(Array)
        raise EvidenceError, 'entity manifest children must be an Array'
      end
      collect_manifest_entity_ids(children, ids)
    end
  end
  private_class_method :collect_manifest_entity_ids

  def self.verify_ready_gate!(stats, gate_name)
    gate = hash_value(stats, gate_name)
    unless gate.is_a?(Hash) && hash_value(gate, :ready) == true
      raise EvidenceError, "#{gate_name} is missing or not ready"
    end
  end
  private_class_method :verify_ready_gate!

  def self.verify_delivery_record!(collection_name, index, record, manifest_ids)
    unless record.is_a?(Hash)
      raise EvidenceError, "#{collection_name}[#{index}] must be a Hash"
    end
    claimed_ids = hash_value(record, :resulting_entity_ids)
    normalized_ids = if claimed_ids.is_a?(Array)
                       claimed_ids.map do |entity_id|
                         normalized_delivery_entity_id(entity_id)
                       end
                     else
                       []
                     end
    unless !normalized_ids.empty? &&
           normalized_ids.none? { |entity_id| entity_id.nil? } &&
           normalized_ids.uniq.length == normalized_ids.length
      raise EvidenceError,
            "#{collection_name}[#{index}] has missing or invalid entity IDs"
    end
    missing = normalized_ids.reject do |entity_id|
      manifest_ids.include?(entity_id)
    end
    unless missing.empty?
      raise EvidenceError,
            "#{collection_name}[#{index}] entity IDs are absent from manifest: " \
            "#{missing.join(', ')}"
    end
  end
  private_class_method :verify_delivery_record!

  def self.normalized_delivery_entity_id(value)
    return value if value.is_a?(Integer) && value > 0
    return nil unless value.is_a?(String)
    match = /\Aentity_id:([1-9][0-9]*)\z/.match(value)
    match ? match[1].to_i : nil
  end
  private_class_method :normalized_delivery_entity_id

  def self.hash_value(hash, key)
    return nil unless hash.is_a?(Hash)
    return hash[key] if hash.key?(key)
    hash[key.to_s]
  end
  private_class_method :hash_value
end
