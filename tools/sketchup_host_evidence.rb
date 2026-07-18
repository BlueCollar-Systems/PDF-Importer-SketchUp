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

  SOURCE_SPAN_ID = /\Atext_span:([1-9][0-9]*):(0|[1-9][0-9]*)\z/.freeze unless
    const_defined?(:SOURCE_SPAN_ID, false)
  MODE_LADDERS = {
    :labels => [:labels, :text3d, :glyphs, :geometry, :raster],
    :text3d => [:text3d, :glyphs, :geometry, :raster],
    :glyphs => [:glyphs, :geometry, :raster],
    :geometry => [:geometry, :raster],
    :raster => [:raster]
  }.freeze unless const_defined?(:MODE_LADDERS, false)
  AFFIRMATIVE_FALLBACK_REASONS = [
    'verified_source_representation_impossible',
    'source_item_identity_unavailable',
    'source_vector_geometry_absent',
    'host_representation_unsupported'
  ].freeze unless const_defined?(:AFFIRMATIVE_FALLBACK_REASONS, false)
  IMAGE_TYPENAMES = ['image', 'rasterimage', 'imageentity'].freeze unless
    const_defined?(:IMAGE_TYPENAMES, false)

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
    verify_persistent_rows!(saved, reopened)
  end

  def self.verify_owned_reopen_continuity!(owned_manifest, reopened_manifest)
    owned = persistent_rows(owned_manifest)
    reopened = persistent_rows(reopened_manifest)
    if owned.empty?
      raise EvidenceError, 'owned manifest has no persistent_id identities'
    end
    missing = owned.keys.reject { |persistent_id| reopened.key?(persistent_id) }
    unless missing.empty?
      raise EvidenceError, 'reopened owned persistent_id set mismatch'
    end
    verify_persistent_rows!(owned, reopened)
  end

  def self.verify_persistent_rows!(saved, reopened)
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
  private_class_method :verify_persistent_rows!

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
      verify_requested_mode_records!(stats, expected_requested)
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
      verify_fallback_contracts!(stats, requested_mode, selected_pages)
      verify_raster_deliveries!(
        stats, manifest, requested_mode, selected_pages
      )
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
    typename = host_typename(entity)
    {
      'entity_id' => host_positive_id(entity, :entityID, 'entityID'),
      'persistent_id' => host_positive_id(
        entity, :persistent_id, 'persistent_id'
      ),
      'typename' => typename,
      'valid' => boolean_state(entity, :valid?),
      'deleted' => boolean_state(entity, :deleted?),
      'bounds' => bounds_payload(entity),
      'transformation' => transformation_payload(entity),
      'content_evidence' => image_content_evidence(entity, typename),
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

  def self.image_typename?(typename)
    IMAGE_TYPENAMES.include?(typename.to_s.strip.downcase)
  end
  private_class_method :image_typename?

  def self.image_content_evidence(entity, typename)
    return nil unless image_typename?(typename)
    width = entity.respond_to?(:width) ? entity.width.to_f : 0.0
    height = entity.respond_to?(:height) ? entity.height.to_f : 0.0
    if width <= 0.0 || height <= 0.0
      bounds = bounds_payload(entity)
      if bounds
        width = (bounds['max'][0].to_f - bounds['min'][0].to_f).abs
        height = (bounds['max'][1].to_f - bounds['min'][1].to_f).abs
      end
    end
    attributes = {}
    if entity.respond_to?(:get_attribute)
      dictionary = 'BC_PDF_Importer'
      [
        'source_span_id', 'raster_page_number', 'raster_pixel_width',
        'raster_pixel_height', 'raster_content_sha256',
        'raster_content_bytes'
      ].each do |key|
        attributes[key] = entity.get_attribute(dictionary, key, nil)
      end
    end
    {
      'image_like' => true,
      'display_width' => width,
      'display_height' => height,
      'raster_page_number' => attributes['raster_page_number'],
      'raster_pixel_width' => attributes['raster_pixel_width'],
      'raster_pixel_height' => attributes['raster_pixel_height'],
      'raster_content_sha256' => attributes['raster_content_sha256'],
      'raster_content_bytes' => attributes['raster_content_bytes'],
      'source_span_id' => attributes['source_span_id']
    }
  rescue StandardError => error
    raise EvidenceError, "host image content evidence failed: #{error.message}"
  end
  private_class_method :image_content_evidence

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

  def self.verify_requested_mode_records!(stats, expected_mode)
    required = [
      [:text_attempts, :requested_mode],
      [:page_text_delivery_records, :requested_mode],
      [:terminal_text_delivery_records, :requested_mode],
      [:raster_delivery_records, :requested_mode]
    ]
    required.each do |collection_name, field|
      Array(hash_value(stats, collection_name)).each_with_index do |record, index|
        unless record.is_a?(Hash) &&
               normalize_mode(hash_value(record, field)) == expected_mode
          raise EvidenceError,
                "#{collection_name}[#{index}] requested mode does not match job"
        end
      end
    end
    optional = [
      [:text_renderers, :requested_mode],
      [:page_representation_fallbacks, :requested_text_mode],
      [:representation_ownership_group_forced_pages, :requested_text_mode]
    ]
    optional.each do |collection_name, field|
      Array(hash_value(stats, collection_name)).each_with_index do |record, index|
        next unless record.is_a?(Hash) && hash_key?(record, field)
        unless normalize_mode(hash_value(record, field)) == expected_mode
          raise EvidenceError,
                "#{collection_name}[#{index}] requested mode does not match job"
        end
      end
    end
    true
  end
  private_class_method :verify_requested_mode_records!

  def self.source_span_page!(source_id)
    match = SOURCE_SPAN_ID.match(source_id.to_s.strip)
    unless match
      raise EvidenceError, "source span identity is malformed: #{source_id}"
    end
    match[1].to_i
  end
  private_class_method :source_span_page!

  def self.verify_record_page_scope!(collection_name, index, record,
                                     span_ids, selected_pages)
    pages = span_ids.map { |source_id| source_span_page!(source_id) }.uniq
    unless pages.length == 1 &&
           (selected_pages.empty? || selected_pages.include?(pages[0]))
      raise EvidenceError,
            "#{collection_name}[#{index}] is outside the selected page set"
    end
    raw_page = if hash_key?(record, :page_number)
                 hash_value(record, :page_number)
               elsif hash_key?(record, :page)
                 hash_value(record, :page)
               end
    unless raw_page.nil? || raw_page.to_s.strip.empty? ||
           raw_page.to_i == pages[0]
      raise EvidenceError,
            "#{collection_name}[#{index}] page does not match source span identity"
    end
    true
  end
  private_class_method :verify_record_page_scope!

  def self.canonical_claims!(value, label, allow_empty)
    unless value.is_a?(Array) && (allow_empty || !value.empty?)
      raise EvidenceError, "#{label} entity identities are invalid"
    end
    claims = value.map { |entry| normalized_delivery_claim(entry) }
    if claims.any? { |claim| claim.nil? } || claims.uniq.length != claims.length
      raise EvidenceError, "#{label} entity identities are invalid"
    end
    claims.map { |namespace, identity| "#{namespace}:#{identity}" }
  end
  private_class_method :canonical_claims!

  def self.transition_signature!(proof, expected_mode, source_id, from_mode,
                                 to_mode, selected_pages)
    raise EvidenceError, 'fallback transition proof is missing' unless
      proof.is_a?(Hash)
    proof_source = hash_value(proof, :source_span_id).to_s.strip
    unless proof_source == source_id
      raise EvidenceError, 'fallback transition belongs to another source item'
    end
    page = source_span_page!(source_id)
    unless selected_pages.empty? || selected_pages.include?(page)
      raise EvidenceError, 'fallback transition is outside the selected page set'
    end
    unless hash_value(proof, :importer_id).to_s ==
             'sketchup_pdf_vector_importer' &&
           hash_value(proof, :page_number).to_i == page &&
           hash_value(proof, :scope).to_s == 'item' &&
           hash_value(proof, :category).to_s ==
             'exact_representation_impossible' &&
           hash_value(proof, :affirmative_impossibility) == true &&
           hash_value(proof, :generic_failure) == false
      raise EvidenceError, 'fallback transition lacks item-bound impossibility proof'
    end
    actual_from = normalize_mode(hash_value(proof, :from_mode))
    actual_to = normalize_mode(hash_value(proof, :to_mode))
    ladder = MODE_LADDERS[expected_mode] || []
    from_index = ladder.index(actual_from)
    unless actual_from == from_mode && actual_to == to_mode && from_index &&
           ladder[from_index + 1] == actual_to
      raise EvidenceError, 'fallback transition is not one adjacent rung'
    end
    reason = hash_value(proof, :reason_code).to_s.strip.downcase
    unless AFFIRMATIVE_FALLBACK_REASONS.include?(reason)
      raise EvidenceError, 'fallback transition reason is not affirmative'
    end
    if hash_value(proof, :attempted_renderer).to_s.strip.empty?
      raise EvidenceError, 'fallback transition attempted renderer is missing'
    end
    evidence = hash_value(proof, :evidence)
    unless evidence.is_a?(Hash) && !evidence.empty?
      raise EvidenceError, 'fallback transition evidence is missing'
    end
    created = canonical_claims!(
      hash_value(proof, :created_entity_ids), 'created', true
    )
    cleaned = canonical_claims!(
      hash_value(proof, :cleaned_entity_ids), 'cleaned', true
    )
    cleanup = hash_value(proof, :cleanup_outcome).to_s
    if created.empty?
      unless cleaned.empty? && ['not_required', 'verified'].include?(cleanup)
        raise EvidenceError, 'fallback transition cleanup proof is inconsistent'
      end
    elsif cleanup != 'verified' || created.sort != cleaned.sort
      raise EvidenceError, 'fallback transition did not clean every owned artifact'
    end
    [source_id, actual_from.to_s, actual_to.to_s, reason,
     created.sort, cleaned.sort, cleanup]
  end
  private_class_method :transition_signature!

  def self.verify_completed_rung!(rung, mode, expected_ids, source_id)
    unless rung.is_a?(Hash) && normalize_mode(hash_value(rung, :mode)) == mode &&
           hash_value(rung, :outcome).to_s == 'complete' &&
           canonical_claims!(
             hash_value(rung, :resulting_entity_ids), 'completed', false
           ).sort == expected_ids.sort &&
           hash_value(rung, :visual_fidelity_verified) == true &&
           hash_value(rung, :cleanup_outcome).to_s == 'not_required'
      raise EvidenceError, "#{source_id} completed rung is not bound to delivery"
    end
    if mode == :raster &&
       (hash_value(rung, :real_raster_verified) != true ||
        hash_value(rung, :source_crop_binding_verified) != true)
      raise EvidenceError, "#{source_id} raster rung lacks item crop evidence"
    end
    true
  end
  private_class_method :verify_completed_rung!

  def self.verify_fallback_contracts!(stats, requested_mode, selected_pages)
    expected_mode = normalize_mode(requested_mode)
    pages = normalized_pages(selected_pages, stats)
    attempts_by_span = {}
    attempt_signatures = []
    Array(hash_value(stats, :text_attempts)).each_with_index do |attempt, index|
      spans = source_span_ids(attempt, :span_id => false)
      if spans.empty?
        raise EvidenceError, "text_attempts[#{index}] has no source span"
      end
      verify_record_page_scope!('text_attempts', index, attempt, spans, pages)
      requested = normalize_mode(hash_value(attempt, :requested_mode))
      delivered = normalize_mode(hash_value(attempt, :delivered_mode))
      ids = canonical_claims!(
        hash_value(attempt, :resulting_entity_ids), 'attempt', false
      )
      unless requested == expected_mode
        raise EvidenceError, "text_attempts[#{index}] requested mode does not match job"
      end
      history = hash_value(attempt, :attempt_history)
      unless history.is_a?(Array) && !history.empty?
        raise EvidenceError, "text_attempts[#{index}] attempt history is missing"
      end

      plural = hash_key?(attempt, :source_span_ids)
      if plural
        unless [:glyphs, :geometry].include?(expected_mode) &&
               delivered == expected_mode && history.length == 1
          raise EvidenceError,
                "text_attempts[#{index}] page delivery cannot self-declare a fallback mode"
        end
        spans.each do |source_id|
          verify_completed_rung!(history[0], expected_mode, ids, source_id)
        end
      else
        unless spans.length == 1
          raise EvidenceError, "text_attempts[#{index}] item identity is ambiguous"
        end
        source_id = spans[0]
        ladder = MODE_LADDERS[expected_mode] || []
        delivered_index = ladder.index(delivered)
        unless delivered_index && history.length == delivered_index + 1
          raise EvidenceError, "#{source_id} delivery is outside the fallback ladder"
        end
        history.each_with_index do |rung, rung_index|
          mode = ladder[rung_index]
          if rung_index == delivered_index
            verify_completed_rung!(rung, mode, ids, source_id)
          else
            unless rung.is_a?(Hash) &&
                   normalize_mode(hash_value(rung, :mode)) == mode &&
                   hash_value(rung, :outcome).to_s == 'failed' &&
                   hash_value(rung, :resulting_entity_ids) == []
              raise EvidenceError, "#{source_id} failed rung is invalid"
            end
            attempt_signatures << transition_signature!(
              hash_value(rung, :transition_proof), expected_mode, source_id,
              mode, ladder[rung_index + 1], pages
            )
          end
        end
      end
      spans.each do |source_id|
        if attempts_by_span.key?(source_id)
          raise EvidenceError, "duplicate attempt for #{source_id}"
        end
        attempts_by_span[source_id] = {
          :mode => delivered, :ids => ids.sort
        }
      end
    end

    global_signatures = Array(hash_value(stats, :fallback_transitions)).map do |proof|
      source_id = hash_value(proof, :source_span_id).to_s.strip
      transition_signature!(
        proof, expected_mode, source_id,
        normalize_mode(hash_value(proof, :from_mode)),
        normalize_mode(hash_value(proof, :to_mode)), pages
      )
    end
    unless global_signatures.map { |value| value.inspect }.sort ==
           attempt_signatures.map { |value| value.inspect }.sort
      raise EvidenceError, 'fallback transition ledger does not match attempts'
    end

    [
      :page_text_delivery_records, :terminal_text_delivery_records
    ].each do |collection_name|
      Array(hash_value(stats, collection_name)).each_with_index do |record, index|
        spans = source_span_ids(record, :span_id => false)
        if spans.empty?
          allowed_page_raster = collection_name ==
            :terminal_text_delivery_records &&
            normalize_mode(hash_value(record, :delivered_mode)) == :raster &&
            hash_value(record, :no_semantic_text) == true
          unless allowed_page_raster
            raise EvidenceError,
                  "#{collection_name}[#{index}] has no source span delivery binding"
          end
          next
        end
        verify_record_page_scope!(collection_name, index, record, spans, pages)
        requested = normalize_mode(hash_value(record, :requested_mode))
        delivered = normalize_mode(hash_value(record, :delivered_mode))
        ids = canonical_claims!(
          hash_value(record, :resulting_entity_ids), collection_name, false
        ).sort
        unless requested == expected_mode
          raise EvidenceError,
                "#{collection_name}[#{index}] requested mode does not match job"
        end
        spans.each do |source_id|
          attempt = attempts_by_span[source_id]
          unless attempt && attempt[:mode] == delivered && attempt[:ids] == ids
            raise EvidenceError,
                  "#{collection_name}[#{index}] does not match item attempt"
          end
        end
      end
    end
    true
  end
  private_class_method :verify_fallback_contracts!

  def self.manifest_claim_rows(manifest)
    rows = {}
    visit_manifest(manifest) do |row|
      entity_id = hash_value(row, :entity_id)
      persistent_id = hash_value(row, :persistent_id)
      rows["entity_id:#{entity_id}"] = row
      rows["persistent_id:#{persistent_id}"] = row
    end
    rows
  end
  private_class_method :manifest_claim_rows

  def self.verify_raster_artifact_binding!(record, row, claim, selected_pages)
    page = hash_value(record, :page).to_i
    unless page > 0 &&
           (selected_pages.empty? || selected_pages.include?(page))
      raise EvidenceError, 'raster delivery is outside the selected page set'
    end
    unless normalize_mode(hash_value(record, :delivered_mode)) == :raster &&
           hash_value(record, :created_entity_type).to_s == 'raster_image' &&
           hash_value(record, :real_raster_verified) == true &&
           hash_value(record, :visual_fidelity_verified) == true
      raise EvidenceError, 'raster delivery is not verified as raster'
    end
    typename = hash_value(row, :typename).to_s
    unless image_typename?(typename)
      raise EvidenceError,
            "raster identity #{claim} is #{typename.empty? ? 'unknown' : typename}, not an image"
    end
    if hash_value(row, :valid) == false || hash_value(row, :deleted) == true
      raise EvidenceError, "raster image identity #{claim} is not live"
    end
    content = hash_value(row, :content_evidence)
    artifact = hash_value(record, :artifact_evidence)
    unless content.is_a?(Hash) && artifact.is_a?(Hash)
      raise EvidenceError, 'raster image content evidence is missing'
    end
    sha256 = hash_value(artifact, :content_sha256).to_s.downcase
    byte_size = hash_value(artifact, :content_byte_size).to_i
    pixel_width = hash_value(artifact, :pixel_width).to_i
    pixel_height = hash_value(artifact, :pixel_height).to_i
    unless hash_value(content, :image_like) == true &&
           hash_value(content, :display_width).to_f > 0.0 &&
           hash_value(content, :display_height).to_f > 0.0 &&
           hash_value(artifact, :page_number).to_i == page &&
           hash_value(artifact, :png_signature_verified) == true &&
           hash_value(artifact, :page_binding_verified) == true &&
           pixel_width > 0 && pixel_height > 0 &&
           sha256 =~ /\A[0-9a-f]{64}\z/ && byte_size > 0 &&
           hash_value(content, :raster_page_number).to_i == page &&
           hash_value(content, :raster_pixel_width).to_i == pixel_width &&
           hash_value(content, :raster_pixel_height).to_i == pixel_height &&
           hash_value(content, :raster_content_sha256).to_s.downcase == sha256 &&
           hash_value(content, :raster_content_bytes).to_i == byte_size
      raise EvidenceError, 'raster image content/page/identity evidence is incomplete'
    end
    scope = hash_value(record, :delivery_scope).to_s
    spans = source_span_ids(record, :span_id => false)
    if scope == 'item_raster'
      unless spans.length == 1 &&
             source_span_page!(spans[0]) == page &&
             hash_value(record, :source_crop_binding_verified) == true &&
             hash_value(artifact, :source_span_id).to_s == spans[0] &&
             hash_value(artifact, :source_crop_binding_verified) == true &&
             hash_value(content, :source_span_id).to_s == spans[0] &&
             hash_value(record, :cleanup_outcome).to_s == 'not_required'
        raise EvidenceError, 'item raster is not bound to its exact source span'
      end
    elsif scope == 'page_raster'
      unless hash_value(artifact, :box_binding_verified) == true &&
             ['not_required', 'verified'].include?(
               hash_value(record, :cleanup_outcome).to_s
             )
        raise EvidenceError, 'page raster box/cleanup evidence is incomplete'
      end
    else
      raise EvidenceError, 'raster delivery scope is invalid'
    end
    true
  end
  private_class_method :verify_raster_artifact_binding!

  def self.verify_raster_deliveries!(stats, manifest, requested_mode,
                                     selected_pages)
    expected_mode = normalize_mode(requested_mode)
    pages = normalized_pages(selected_pages, stats)
    rows = manifest_claim_rows(manifest)
    signatures = []
    delivery_pages = []
    Array(hash_value(stats, :raster_delivery_records)).each_with_index do |record, index|
      unless record.is_a?(Hash) &&
             normalize_mode(hash_value(record, :requested_mode)) == expected_mode
        raise EvidenceError,
              "raster_delivery_records[#{index}] requested mode does not match job"
      end
      claims = canonical_claims!(
        hash_value(record, :resulting_entity_ids), 'raster delivery', false
      )
      unless claims.length == 1
        raise EvidenceError, 'raster delivery must identify exactly one host entity'
      end
      claim = claims[0]
      row = rows[claim]
      unless row
        raise EvidenceError, "raster delivery identity is absent from manifest: #{claim}"
      end
      verify_raster_artifact_binding!(record, row, claim, pages)
      page = hash_value(record, :page).to_i
      delivery_pages << page
      signatures << [page, claim]
    end

    terminal_records = Array(hash_value(stats, :terminal_text_delivery_records))
    terminal_raster_signatures = []
    terminal_records.each do |record|
      next unless normalize_mode(hash_value(record, :delivered_mode)) == :raster
      claims = canonical_claims!(
        hash_value(record, :resulting_entity_ids), 'terminal raster', false
      )
      unless claims.length == 1
        raise EvidenceError, 'terminal raster must identify exactly one host image'
      end
      terminal_raster_signatures << [hash_value(record, :page).to_i, claims[0]]
    end
    unless terminal_raster_signatures.sort == signatures.sort
      raise EvidenceError,
            'terminal raster deliveries do not match raster delivery records'
    end

    return true unless expected_mode == :raster
    source_ids = Array(hash_value(stats, :text_source_span_ids))
    unless source_ids.empty? &&
           Array(hash_value(stats, :text_attempts)).empty? &&
           Array(hash_value(stats, :source_provenance_objects)).empty? &&
           Array(hash_value(stats, :page_text_delivery_records)).empty?
      raise EvidenceError, 'requested Raster contains non-raster span evidence'
    end
    if signatures.empty? || delivery_pages.uniq.length != delivery_pages.length ||
       (!pages.empty? && delivery_pages.sort != pages.sort)
      raise EvidenceError, 'Raster page delivery set mismatch'
    end
    terminal_signatures = terminal_records.map do |record|
      claims = canonical_claims!(
        hash_value(record, :resulting_entity_ids), 'terminal raster', false
      )
      unless claims.length == 1 &&
             normalize_mode(hash_value(record, :requested_mode)) == :raster &&
             normalize_mode(hash_value(record, :delivered_mode)) == :raster
        raise EvidenceError, 'terminal Raster delivery is invalid'
      end
      [hash_value(record, :page).to_i, claims[0]]
    end
    unless terminal_signatures.sort == signatures.sort
      raise EvidenceError, 'Raster terminal delivery identities do not crosslink'
    end
    true
  end
  private_class_method :verify_raster_deliveries!

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
    if hash_key?(stats, :selected_pages)
      pipeline_pages = normalized_pages(hash_value(stats, :selected_pages), stats)
      unless pipeline_pages == pages
        raise EvidenceError, 'pipeline selected pages do not match the job'
      end
    end

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

    source_ids.each do |source_id|
      page = source_span_page!(source_id)
      unless pages.empty? || pages.include?(page)
        raise EvidenceError, 'source span evidence is outside the selected page set'
      end
    end

    attempt_ids = Array(hash_value(stats, :text_attempts)).flat_map do |row|
      source_span_ids(row, :span_id => false)
    end.uniq.sort
    delivered_ids = []
    Array(hash_value(stats, :source_provenance_objects)).each_with_index do |row, index|
      spans = source_span_ids(row, :span_id => true)
      unless spans.empty?
        verify_record_page_scope!(
          :source_provenance_objects, index, row, spans, pages
        )
      end
      delivered_ids.concat(spans)
    end
    [:terminal_text_delivery_records, :page_text_delivery_records].each do |name|
      Array(hash_value(stats, name)).each do |row|
        delivered_ids.concat(source_span_ids(row, :span_id => false))
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

  def self.source_span_ids(record, options = {})
    return [] unless record.is_a?(Hash)
    values = []
    singular_keys = [:source_span_id]
    singular_keys << :span_id if options[:span_id]
    plural_keys = [:source_span_ids]
    plural_keys << :span_ids if options[:span_id]
    singular_keys.each do |key|
      next unless hash_key?(record, key)
      value = hash_value(record, key).to_s.strip
      values << value unless value.empty?
    end
    plural_keys.each do |key|
      next unless hash_key?(record, key)
      raw = hash_value(record, key)
      unless raw.is_a?(Array)
        raise EvidenceError, "#{key} must be an Array"
      end
      raw.each do |span|
        value = span.to_s.strip
        values << value unless value.empty?
      end
    end
    values.uniq
  end
  private_class_method :source_span_ids

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
    if hash_key?(expected, :source_lineage)
      expected_lineage = JSON.parse(JSON.generate(
        hash_value(expected, :source_lineage)
      ))
      unless nested_value(report, [:extra, :source_lineage]) ==
             expected_lineage
        raise EvidenceError, 'report source lineage does not match host session'
      end
    end
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
