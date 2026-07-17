#!/usr/bin/env ruby

require 'json'
require 'digest'
require 'fileutils'

module SketchupHostEvidence
  class EvidenceError < StandardError; end

  REQUIRED_LEDGER_COLLECTIONS = [
    :text_source_span_ids,
    :text_attempts,
    :source_provenance_objects,
    :page_text_delivery_records,
    :terminal_text_delivery_records,
    :page_representation_fallbacks,
    :raster_delivery_records,
    :source_glyph_physical_deliveries,
    :fallback_transitions,
    :terminal_cleanup_events,
    :empty_page_source_inspections
  ].freeze unless const_defined?(:REQUIRED_LEDGER_COLLECTIONS, false)

  ID_BEARING_COLLECTIONS = [
    :text_attempts,
    :source_provenance_objects,
    :page_text_delivery_records,
    :terminal_text_delivery_records,
    :page_representation_fallbacks,
    :raster_delivery_records,
    :source_glyph_physical_deliveries
  ].freeze unless const_defined?(:ID_BEARING_COLLECTIONS, false)

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
    Array(entities.to_a).map { |entity| snapshot_entity(entity, []) }
  rescue EvidenceError
    raise
  rescue StandardError => error
    raise EvidenceError, "host entity snapshot failed: #{error.message}"
  end

  def self.manifest_entity_ids(manifest)
    manifest_identity_sets(manifest)['entity_id']
  end

  def self.manifest_identity_sets(manifest)
    unless manifest.is_a?(Array)
      raise EvidenceError, 'entity manifest must be an Array'
    end
    sets = { 'entity_id' => [], 'persistent_id' => [] }
    collect_manifest_identities(manifest, sets)
    sets.each { |key, values| sets[key] = values.uniq }
    sets
  end

  def self.owned_manifest(before_manifest, after_manifest)
    before = manifest_identity_sets(before_manifest)
    owned_rows(after_manifest, before)
  end

  def self.verify_reopen_continuity!(saved_manifest, reopened_manifest)
    saved = persistent_rows(saved_manifest)
    reopened = persistent_rows(reopened_manifest)
    if saved.empty?
      raise EvidenceError, 'saved manifest has no persistent_id identities'
    end
    unless saved.keys.sort == reopened.keys.sort
      raise EvidenceError, 'reopened persistent_id set mismatch'
    end
    saved.each do |persistent_id, row|
      other = reopened[persistent_id]
      unless hash_value(row, :typename).to_s == hash_value(other, :typename).to_s
        raise EvidenceError,
              "reopened typename mismatch for persistent_id:#{persistent_id}"
      end
      unless evidence_payload_equal?(
        hash_value(row, :transformation),
        hash_value(other, :transformation)
      )
        raise EvidenceError,
              "reopened transformation mismatch for persistent_id:#{persistent_id}"
      end
      unless evidence_payload_equal?(
        hash_value(row, :bounds), hash_value(other, :bounds)
      )
        raise EvidenceError,
              "reopened bounds mismatch for persistent_id:#{persistent_id}"
      end
    end
    true
  end

  def self.verify_delivery_evidence!(stats, manifest, requested_mode = nil,
                                     selected_pages = nil)
    raise EvidenceError, 'pipeline stats are missing' unless stats.is_a?(Hash)
    if !manifest.is_a?(Array) || manifest.empty?
      raise EvidenceError, 'entity manifest is missing or empty'
    end
    namespaces = manifest_identity_sets(manifest)
    if namespaces['entity_id'].empty? || namespaces['persistent_id'].empty?
      raise EvidenceError,
            'entity manifest requires entity_id and persistent_id namespaces'
    end

    verify_ready_gate!(stats, :representation_fidelity)
    verify_ready_gate!(stats, :import_contract_ready)

    strict = !requested_mode.nil?
    if strict
      REQUIRED_LEDGER_COLLECTIONS.each do |name|
        unless hash_key?(stats, name)
          raise EvidenceError, "#{name} ledger is missing"
        end
        value = hash_value(stats, name)
        unless value.is_a?(Array)
          raise EvidenceError, "#{name} must be an Array"
        end
      end
      session_id = hash_value(stats, :import_session_id).to_s.strip
      raise EvidenceError, 'import_session_id is missing' if session_id.empty?
      actual_requested = normalize_mode(hash_value(stats, :requested_text_mode))
      expected_requested = normalize_mode(requested_mode)
      unless actual_requested == expected_requested
        raise EvidenceError,
              'requested representation mode does not match pipeline ledger'
      end
    end

    ID_BEARING_COLLECTIONS.each do |collection_name|
      records = hash_value(stats, collection_name)
      next if records.nil? && !strict
      records = [] if records.nil?
      unless records.is_a?(Array)
        raise EvidenceError, "#{collection_name} must be an Array"
      end
      records.each_with_index do |record, index|
        verify_delivery_record!(collection_name, index, record, namespaces)
      end
    end

    if strict
      verify_source_sets!(stats, requested_mode, selected_pages)
    end
    true
  end

  def self.copy_verified_report!(source_path, destination_path, expectations)
    source = File.expand_path(source_path.to_s)
    destination = File.expand_path(destination_path.to_s)
    raise EvidenceError, 'production import report missing' unless File.file?(source)
    before = File.binread(source)
    report = parse_report(before)
    verify_report_binding!(report, expectations)

    unless normalized_path(source) == normalized_path(destination)
      atomic_write(destination, before)
      unless File.binread(destination) == before
        raise EvidenceError, 'copied import report differs from validated source'
      end
    end
    yield if block_given?
    after = File.binread(source)
    unless after == before
      File.delete(destination) if normalized_path(source) != normalized_path(destination) &&
                                  File.file?(destination)
      raise EvidenceError, 'production import report was concurrently replaced'
    end
    destination
  rescue EvidenceError
    raise
  rescue StandardError => error
    raise EvidenceError, "import report verification failed: #{error.message}"
  end

  def self.atomic_write_json(path, payload)
    atomic_write(path, JSON.pretty_generate(payload) + "\n")
  end

  def self.atomic_write(path, bytes)
    destination = File.expand_path(path.to_s)
    parent = File.dirname(destination)
    FileUtils.mkdir_p(parent) unless File.directory?(parent)
    temporary = File.join(
      parent,
      ".#{File.basename(destination)}.#{Process.pid}.#{rand(1_000_000)}.tmp"
    )
    File.open(temporary, 'wb') do |file|
      file.write(bytes)
      file.flush
      begin
        file.fsync
      rescue StandardError
        # Some SketchUp-hosted Windows filesystems do not expose fsync.
      end
    end
    File.rename(temporary, destination)
    destination
  ensure
    File.delete(temporary) if defined?(temporary) && temporary &&
                              File.file?(temporary)
  end

  def self.normalized_path(path)
    text = path.to_s.strip
    raise EvidenceError, 'source path is missing' if text.empty?
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
      'entity_id' => host_positive_id(entity, :entityID, 'entityID'),
      'persistent_id' => host_positive_id(
        entity, :persistent_id, 'persistent_id'
      ),
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

  def self.host_positive_id(entity, method_name, label)
    unless entity.respond_to?(method_name)
      raise EvidenceError, "host #{label} is unavailable"
    end
    value = entity.send(method_name)
    unless value.is_a?(Integer) && value > 0
      raise EvidenceError, "host #{label} must be a positive Integer"
    end
    value
  end
  private_class_method :host_positive_id

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

  def self.collect_manifest_identities(rows, sets)
    rows.each do |row|
      raise EvidenceError, 'entity manifest row must be a Hash' unless row.is_a?(Hash)
      ['entity_id', 'persistent_id'].each do |namespace|
        value = hash_value(row, namespace)
        unless value.is_a?(Integer) && value > 0
          raise EvidenceError,
                "entity manifest row has no positive #{namespace}"
        end
        sets[namespace] << value
      end
      children = hash_value(row, :children)
      children = [] if children.nil?
      unless children.is_a?(Array)
        raise EvidenceError, 'entity manifest children must be an Array'
      end
      collect_manifest_identities(children, sets)
    end
  end
  private_class_method :collect_manifest_identities

  def self.owned_rows(rows, before)
    owned = []
    Array(rows).each do |row|
      children = owned_rows(hash_value(row, :children) || [], before)
      persistent_id = hash_value(row, :persistent_id)
      entity_id = hash_value(row, :entity_id)
      preexisting = before['persistent_id'].include?(persistent_id) ||
                    before['entity_id'].include?(entity_id)
      if preexisting
        owned.concat(children)
      else
        copy = row.dup
        copy['children'] = children
        owned << copy
      end
    end
    owned
  end
  private_class_method :owned_rows

  def self.persistent_rows(manifest)
    rows = {}
    visit_manifest(manifest) do |row|
      persistent_id = hash_value(row, :persistent_id)
      unless persistent_id.is_a?(Integer) && persistent_id > 0
        raise EvidenceError, 'manifest row has no persistent_id'
      end
      if rows.key?(persistent_id)
        unless hash_value(rows[persistent_id], :typename).to_s ==
               hash_value(row, :typename).to_s
          raise EvidenceError,
                "conflicting duplicate persistent_id:#{persistent_id}"
        end
        next
      end
      rows[persistent_id] = row
    end
    rows
  end
  private_class_method :persistent_rows

  def self.evidence_payload_equal?(left, right)
    if left.is_a?(Numeric) && right.is_a?(Numeric)
      return (left.to_f - right.to_f).abs <= 1.0e-9
    end
    if left.is_a?(Array) && right.is_a?(Array)
      return false unless left.length == right.length
      return left.each_with_index.all? do |value, index|
        evidence_payload_equal?(value, right[index])
      end
    end
    if left.is_a?(Hash) && right.is_a?(Hash)
      left_keys = left.keys.map { |key| key.to_s }.sort
      right_keys = right.keys.map { |key| key.to_s }.sort
      return false unless left_keys == right_keys
      return left_keys.all? do |key|
        evidence_payload_equal?(hash_value(left, key), hash_value(right, key))
      end
    end
    left == right
  end
  private_class_method :evidence_payload_equal?

  def self.visit_manifest(rows, &block)
    Array(rows).each do |row|
      yield row
      visit_manifest(hash_value(row, :children) || [], &block)
    end
  end
  private_class_method :visit_manifest

  def self.verify_ready_gate!(stats, gate_name)
    gate = hash_value(stats, gate_name)
    unless gate.is_a?(Hash) && hash_value(gate, :ready) == true
      raise EvidenceError, "#{gate_name} is missing or not ready"
    end
  end
  private_class_method :verify_ready_gate!

  def self.verify_delivery_record!(collection_name, index, record, namespaces)
    unless record.is_a?(Hash)
      raise EvidenceError, "#{collection_name}[#{index}] must be a Hash"
    end
    claimed_ids = hash_value(record, :resulting_entity_ids)
    claims = claimed_ids.is_a?(Array) ? claimed_ids : []
    normalized = claims.map { |value| normalized_delivery_claim(value) }
    unless !normalized.empty? && normalized.none? { |value| value.nil? } &&
           normalized.uniq.length == normalized.length
      raise EvidenceError,
            "#{collection_name}[#{index}] has missing or invalid entity IDs"
    end
    missing = normalized.reject do |namespace, value|
      namespaces[namespace].include?(value)
    end
    unless missing.empty?
      labels = missing.map { |namespace, value| "#{namespace}:#{value}" }
      raise EvidenceError,
            "#{collection_name}[#{index}] identities are absent from manifest: " \
            "#{labels.join(', ')}"
    end
  end
  private_class_method :verify_delivery_record!

  def self.normalized_delivery_claim(value)
    return ['entity_id', value] if value.is_a?(Integer) && value > 0
    return nil unless value.is_a?(String)
    match = /\A(entity_id|persistent_id):([1-9][0-9]*)\z/.match(value)
    match ? [match[1], match[2].to_i] : nil
  end
  private_class_method :normalized_delivery_claim

  def self.verify_source_sets!(stats, requested_mode, selected_pages)
    source_ids = hash_value(stats, :text_source_span_ids)
    unless source_ids.uniq.length == source_ids.length &&
           source_ids.all? { |value| !value.to_s.strip.empty? }
      raise EvidenceError, 'source span ledger is invalid'
    end
    mode = normalize_mode(requested_mode)
    pages = normalized_pages(selected_pages, stats)

    if mode == :raster
      unless source_ids.empty?
        raise EvidenceError, 'Raster source span ledger must be empty'
      end
      delivered_pages = Array(hash_value(stats, :raster_delivery_records)).map do |row|
        hash_value(row, :page).to_i
      end.uniq.sort
      unless !delivered_pages.empty? &&
             (pages.empty? || delivered_pages == pages)
        raise EvidenceError, 'Raster page delivery set mismatch'
      end
      return true
    end

    if source_ids.empty?
      verify_empty_source_proof!(stats, pages)
      return true
    end

    attempt_ids = Array(hash_value(stats, :text_attempts)).map do |row|
      hash_value(row, :source_span_id).to_s.strip
    end.reject { |value| value.empty? }.uniq.sort
    delivered_ids = []
    Array(hash_value(stats, :source_provenance_objects)).each do |row|
      span = hash_value(row, :span_id).to_s.strip
      delivered_ids << span unless span.empty?
    end
    [:terminal_text_delivery_records, :page_text_delivery_records].each do |name|
      Array(hash_value(stats, name)).each do |row|
        Array(hash_value(row, :source_span_ids)).each do |span|
          value = span.to_s.strip
          delivered_ids << value unless value.empty?
        end
      end
    end
    expected = source_ids.map { |value| value.to_s.strip }.sort
    unless attempt_ids == expected
      raise EvidenceError, 'source attempt set mismatch'
    end
    unless delivered_ids.uniq.sort == expected
      raise EvidenceError, 'source delivery set mismatch'
    end
    true
  end
  private_class_method :verify_source_sets!

  def self.verify_empty_source_proof!(stats, pages)
    inspections = Array(hash_value(stats, :empty_page_source_inspections))
    proven_pages = inspections.select do |row|
      hash_value(row, :semantic_text_extraction_complete) == true &&
        hash_value(row, :decoded_stream_text_operators) == false &&
        hash_value(row, :decoded_form_stream_text_operators) == false &&
        hash_value(row, :page).to_i > 0
    end.map { |row| hash_value(row, :page).to_i }.uniq.sort
    unless !proven_pages.empty? && (pages.empty? || proven_pages == pages)
      raise EvidenceError,
            'empty text ledger lacks decoded-stream no-text proof'
    end
  end
  private_class_method :verify_empty_source_proof!

  def self.normalized_pages(selected_pages, stats)
    if selected_pages == :all || selected_pages.to_s == 'all'
      count = hash_value(stats, :pages).to_i
      return count > 0 ? (1..count).to_a : []
    end
    Array(selected_pages).map { |value| value.to_i }.select do |value|
      value > 0
    end.uniq.sort
  end
  private_class_method :normalized_pages

  def self.normalize_mode(value)
    text = value.to_s.strip.downcase
    return :text3d if ['text3d', '3d_text', '3d text'].include?(text)
    return text.to_sym if %w[labels glyphs geometry raster].include?(text)
    nil
  end
  private_class_method :normalize_mode

  def self.parse_report(bytes)
    parsed = JSON.parse(bytes)
    raise EvidenceError, 'production import report root must be an object' unless
      parsed.is_a?(Hash)
    parsed
  rescue JSON::ParserError => error
    raise EvidenceError, "production import report is corrupt: #{error.message}"
  end
  private_class_method :parse_report

  def self.verify_report_binding!(report, expected)
    expected = {} unless expected.is_a?(Hash)
    require_equal!(report, [:schema], hash_value(expected, :schema), 'schema')
    require_equal!(report, [:host, :app], 'sketchup', 'host app')
    require_equal!(
      report, [:host, :version], hash_value(expected, :host_version),
      'host version'
    )
    worktree = hash_value(expected, :worktree_version).to_s
    loaded = hash_value(expected, :loaded_version).to_s
    unless !worktree.empty? && worktree == loaded
      raise EvidenceError, 'worktree and loaded importer versions differ'
    end
    require_equal!(report, [:importer, :version], loaded, 'importer version')
    require_equal!(report, [:report_meta, :semver], loaded, 'report version')
    require_equal!(report, [:report_meta, :host], 'sketchup', 'report host')

    pdf_path = File.expand_path(hash_value(expected, :pdf_path).to_s)
    report_path = nested_value(report, [:input, :file]).to_s
    unless normalized_path(report_path) == normalized_path(pdf_path)
      raise EvidenceError, 'report source path does not match job PDF'
    end
    expected_sha = Digest::SHA256.file(pdf_path).hexdigest
    require_equal!(report, [:input, :sha256], expected_sha, 'source SHA256')
    require_equal!(
      report, [:extra, :requested_text_mode],
      normalize_mode(hash_value(expected, :requested_mode)).to_s,
      'requested representation mode'
    )
    session_id = hash_value(expected, :import_session_id).to_s
    raise EvidenceError, 'expected import session is missing' if session_id.empty?
    require_equal!(report, [:extra, :import_session_id], session_id,
                   'import session')
    require_equal!(report, [:extra, :source_provenance, :import_session_id],
                   session_id, 'provenance import session')
    require_equal!(report, [:extra, :source_provenance, :schema],
                   'bcs.source_provenance/1.0', 'provenance schema')
    objects = nested_value(report, [:extra, :source_provenance, :objects])
    unless objects.is_a?(Array)
      raise EvidenceError, 'full source provenance objects are missing'
    end
    expected_objects = hash_value(expected, :source_provenance_objects)
    expected_objects = [] if expected_objects.nil?
    normalized_expected = JSON.parse(JSON.generate(Array(expected_objects)))
    unless objects == normalized_expected
      raise EvidenceError, 'full source provenance does not match host session'
    end
    require_equal!(report, [:extra, :source_provenance, :object_count],
                   objects.length, 'provenance object count')
    require_equal!(report, [:extra, :representation_fidelity, :ready], true,
                   'representation readiness')
    require_equal!(report, [:extra, :import_contract_ready, :ready], true,
                   'import contract readiness')
    {
      :representation_fidelity => [:extra, :representation_fidelity],
      :import_contract_ready => [:extra, :import_contract_ready]
    }.each do |expectation_key, report_path|
      next unless hash_key?(expected, expectation_key)
      expected_gate = JSON.parse(JSON.generate(
        hash_value(expected, expectation_key)
      ))
      unless nested_value(report, report_path) == expected_gate
        raise EvidenceError, "report #{expectation_key} does not match host session"
      end
    end
    true
  end
  private_class_method :verify_report_binding!

  def self.require_equal!(hash, path, expected, label)
    actual = nested_value(hash, path)
    unless actual == expected
      raise EvidenceError, "report #{label} mismatch"
    end
  end
  private_class_method :require_equal!

  def self.nested_value(hash, path)
    path.inject(hash) { |value, key| hash_value(value, key) }
  end
  private_class_method :nested_value

  def self.hash_key?(hash, key)
    hash.is_a?(Hash) && (hash.key?(key) || hash.key?(key.to_s))
  end
  private_class_method :hash_key?

  def self.hash_value(hash, key)
    return nil unless hash.is_a?(Hash)
    return hash[key] if hash.key?(key)
    hash[key.to_s]
  end
  private_class_method :hash_value
end
