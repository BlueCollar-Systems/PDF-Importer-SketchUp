#!/usr/bin/env ruby

require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require File.expand_path(
  '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity',
  __dir__
)
require File.expand_path(
  '../extracted/sketchup_ext/bc_pdf_vector_importer/png_cropper',
  __dir__
)

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
    :text => [:text, :labels, :text3d, :glyphs, :geometry, :raster],
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
  CREATED_ENTITY_MODES = {
    'native_label' => :labels,
    'native_3d_text' => :text3d,
    'source_glyph_3d_text' => :text3d,
    'glyph_outline' => :glyphs,
    'page_path_geometry' => :geometry,
    'raster_image' => :raster,
    'sketchup_image' => :raster
  }.freeze unless const_defined?(:CREATED_ENTITY_MODES, false)

  def self.verify_source_locations!(expected_root, locations)
    root = normalized_path(expected_root)
    unless locations.is_a?(Hash) && !locations.empty?
      raise EvidenceError, 'source locations are missing'
    end
    prefix = root.end_with?('/') ? root : "#{root}/"
    locations.each do |name, location|
      unless location.is_a?(Array) && location.length >= 2 &&
             !location[0].to_s.strip.empty? &&
             location[1].is_a?(Integer) && location[1] > 0
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

  def self.snapshot_entities(entities, options = {})
    unless entities.respond_to?(:to_a)
      raise EvidenceError, 'host entity collection cannot be enumerated'
    end
    compact = options.is_a?(Hash) && options[:compact] == true
    Array(entities.to_a).map do |entity|
      snapshot_entity_with_physical_tree(
        entity, [], compact, true
      ).first
    end.compact
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
      unless hash_value(row, :valid) == true &&
             hash_value(row, :deleted) == false &&
             hash_value(other, :valid) == true &&
             hash_value(other, :deleted) == false
        raise EvidenceError,
              "reopened entity is not live for persistent_id:#{persistent_id}"
      end
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
      unless evidence_payload_equal?(
        hash_value(row, :representation_evidence),
        hash_value(other, :representation_evidence)
      )
        raise EvidenceError,
              "reopened representation identity mismatch for persistent_id:#{persistent_id}"
      end
      unless evidence_payload_equal?(
        hash_value(row, :content_evidence),
        hash_value(other, :content_evidence)
      )
        raise EvidenceError,
              "reopened content evidence mismatch for persistent_id:#{persistent_id}"
      end
      unless direct_child_persistent_ids(row) ==
             direct_child_persistent_ids(other)
        raise EvidenceError,
              "reopened child structure mismatch for persistent_id:#{persistent_id}"
      end
      unless evidence_payload_equal?(
        hash_value(row, :geometry_evidence),
        hash_value(other, :geometry_evidence)
      )
        raise EvidenceError,
              "reopened geometry evidence mismatch for persistent_id:#{persistent_id}"
      end
      unless evidence_payload_equal?(
        hash_value(row, :style_evidence),
        hash_value(other, :style_evidence)
      )
        raise EvidenceError,
              "reopened style evidence mismatch for persistent_id:#{persistent_id}"
      end
    end
    true
  end
  private_class_method :verify_persistent_rows!

  def self.direct_child_persistent_ids(row)
    children = hash_value(row, :children)
    children = [] if children.nil?
    unless children.is_a?(Array)
      raise EvidenceError, 'manifest children must be an Array'
    end
    values = children.map do |child|
      exact_positive_integer!(
        hash_value(child, :persistent_id), 'child persistent_id'
      )
    end
    if values.uniq.length != values.length
      raise EvidenceError, 'manifest child persistent_ids are duplicated'
    end
    values.sort
  end
  private_class_method :direct_child_persistent_ids

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
    claim_rows = manifest_claim_rows(manifest)

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
        verify_delivery_record!(
          collection_name, index, record, namespaces, claim_rows, strict
        )
      end
    end

    if strict
      verify_attempt_claim_ownership!(
        hash_value(stats, :text_attempts), claim_rows
      )
      verify_source_sets!(stats, requested_mode, selected_pages)
      verify_fallback_contracts!(stats, requested_mode, selected_pages)
      verify_raster_deliveries!(
        stats, manifest, requested_mode, selected_pages
      )
      verify_page_representation_fallbacks!(
        stats, requested_mode, selected_pages
      )
      verify_source_expected_attempts!(
        hash_value(stats, :text_attempts), claim_rows
      )
    end
    true
  end

  def self.verify_attempt_claim_ownership!(attempts, rows_by_claim)
    owners = {}
    Array(attempts).each_with_index do |attempt, index|
      claims = hash_value(attempt, :resulting_entity_ids)
      Array(claims).each do |claim|
        normalized = normalized_delivery_claim(claim)
        next unless normalized
        claim_key = "#{normalized[0]}:#{normalized[1]}"
        row = rows_by_claim[claim_key]
        entity_id = hash_value(row, :entity_id)
        key = "entity_id:#{entity_id}"
        if owners.key?(key)
          raise EvidenceError,
                "text_attempts[#{index}] aliases the same host entity as " \
                "text_attempts[#{owners[key]}]: #{key}"
        end
        owners[key] = index
      end
    end
    true
  end
  private_class_method :verify_attempt_claim_ownership!

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
    snapshot_entity_with_physical_tree(entity, ancestors, false, false).first
  end
  private_class_method :snapshot_entity

  def self.snapshot_entity_with_physical_tree(entity, ancestors, compact,
                                              top_level)
    raise EvidenceError, 'entity manifest contains nil' if entity.nil?
    identity = entity.object_id
    if ancestors.include?(identity)
      raise EvidenceError, 'recursive host entity cycle detected'
    end
    children = child_entities(entity)
    child_results = children.map do |child|
      snapshot_entity_with_physical_tree(
        child, ancestors + [identity], compact, false
      )
    end
    child_rows = child_results.map { |result| result[0] }.compact
    child_trees = if compact
                    child_results.select { |result| result[0].nil? }.map do |result|
                      result[1]
                    end
                  else
                    child_results.map { |result| result[1] }
                  end
    typename = host_typename(entity)
    representation = representation_identity_evidence(entity)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    physical_tree = fidelity.physical_entity_tree(entity, child_trees)
    include_row = !compact || top_level || source_claim_root?(representation) ||
      !child_rows.empty?
    return [nil, physical_tree] unless include_row

    compact_partition = compact && compact_owner_typename?(typename)
    physical = physical_tree_evidence(physical_tree, compact_partition)
    row = {
      'entity_id' => host_positive_id(entity, :entityID, 'entityID'),
      'persistent_id' => host_positive_id(
        entity, :persistent_id, 'persistent_id'
      ),
      'typename' => typename,
      'valid' => boolean_state(entity, :valid?),
      'deleted' => boolean_state(entity, :deleted?),
      'bounds' => physical_tree_bounds(physical_tree),
      'transformation' => physical_tree_transformation(physical_tree),
      'representation_evidence' => representation,
      'content_evidence' => host_content_evidence(entity, typename),
      'geometry_evidence' => physical['geometry_evidence'],
      'style_evidence' => physical['style_evidence'],
      'children' => child_rows
    }
    [row, physical_tree]
  end
  private_class_method :snapshot_entity_with_physical_tree

  def self.physical_tree_evidence(tree, compact = false)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    evidence = fidelity.physical_evidence_from_trees([tree])
    style_root = Array(evidence[:style_payload]).first || {}
    geometry = {
      'sha256' => evidence[:physical_geometry_sha256]
    }
    style = {
      'sha256' => evidence[:physical_style_sha256],
      'layer_name' => style_root[:layer_name],
      'layer_visible' => style_root[:layer_visible],
      'entity_visible' => style_root[:entity_visible],
      'material' => style_root[:material],
      'back_material' => style_root[:back_material]
    }
    if compact
      schema = 'bcs.host_physical_partition/1.0'
      geometry['schema'] = schema
      geometry['physical_entity_count'] = evidence[:physical_entity_count]
      geometry['topology'] = physical_tree_topology(tree)
      style['schema'] = schema
      style['physical_entity_count'] = evidence[:physical_entity_count]
    else
      geometry['payload'] = evidence[:geometry_payload]
      style['payload'] = evidence[:style_payload]
    end
    { 'geometry_evidence' => geometry, 'style_evidence' => style }
  rescue StandardError => error
    raise EvidenceError, "host physical evidence failed: #{error.message}"
  end
  private_class_method :physical_tree_evidence

  def self.compact_owner_typename?(typename)
    ['Group', 'ComponentInstance', 'Text', 'Image'].include?(typename.to_s)
  end
  private_class_method :compact_owner_typename?

  def self.physical_tree_topology(tree)
    topology = tree.is_a?(Hash) ? tree[:topology] : nil
    unless topology.is_a?(Hash)
      raise EvidenceError, 'host physical topology is unavailable'
    end
    counts = topology[:descendant_type_counts]
    unless counts.is_a?(Hash)
      raise EvidenceError, 'host physical topology counts are unavailable'
    end
    {
      'root_type' => topology[:root_type].to_s,
      'direct_child_types' => Array(topology[:direct_child_types]).map(&:to_s),
      'descendant_type_counts' => counts.keys.sort.inject({}) do |memo, key|
        memo[key.to_s] = counts[key].to_i
        memo
      end,
      'descendant_entity_count' => topology[:descendant_entity_count].to_i,
      'live_entity_count' => topology[:live_entity_count].to_i
    }
  end
  private_class_method :physical_tree_topology

  def self.source_claim_root?(representation)
    representation.is_a?(Hash) &&
      hash_value(representation, :source_claim_root) == true
  rescue StandardError
    false
  end
  private_class_method :source_claim_root?

  def self.physical_tree_bounds(tree)
    geometry = tree.is_a?(Hash) ? tree[:geometry_payload] : nil
    bounds = geometry.is_a?(Hash) ? geometry[:bounds] : nil
    return nil unless bounds.is_a?(Hash)
    minimum = bounds[:min]
    maximum = bounds[:max]
    return nil unless minimum.is_a?(Array) && maximum.is_a?(Array)
    { 'min' => minimum, 'max' => maximum }
  rescue StandardError
    nil
  end
  private_class_method :physical_tree_bounds

  def self.physical_tree_transformation(tree)
    geometry = tree.is_a?(Hash) ? tree[:geometry_payload] : nil
    value = geometry.is_a?(Hash) ? geometry[:transformation] : nil
    value.is_a?(Array) ? value : nil
  rescue StandardError
    nil
  end
  private_class_method :physical_tree_transformation

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

  # Export the texture through the real host API and decode the resulting PNG.
  # This is deliberately independent of importer-written attributes: those
  # attributes describe the claim, while these pixels prove what SketchUp owns.
  def self.texture_pixel_evidence(entity)
    unless defined?(Sketchup) &&
           Sketchup.respond_to?(:create_texture_writer)
      raise EvidenceError, 'SketchUp TextureWriter is unavailable'
    end
    directory = Dir.mktmpdir('bc_host_texture_proof_')
    png_path = File.join(directory, 'texture.png')
    raw_path = File.join(directory, 'texture.rgba')
    writer = Sketchup.create_texture_writer
    raise EvidenceError, 'SketchUp TextureWriter creation failed' unless writer
    texture_id = writer.load(entity)
    unless texture_id.is_a?(Integer) && texture_id > 0
      raise EvidenceError, 'SketchUp TextureWriter did not load the image'
    end
    status = writer.write(entity, png_path)
    unless status.is_a?(Integer) && status == 0
      raise EvidenceError,
            "SketchUp TextureWriter export failed with status #{status.inspect}"
    end
    unless File.file?(png_path) && File.size(png_path).to_i > 0
      raise EvidenceError,
            'SketchUp TextureWriter reported success without an output file'
    end
    prepared = BlueCollarSystems::PDFVectorImporter::PngCropper.prepare_rgba!(
      png_path, raw_path, false
    )
    visual_sha = prepared[:visual_pixel_sha256].to_s.downcase
    unless visual_sha =~ /\A[0-9a-f]{64}\z/
      raise EvidenceError, 'host texture visual pixel digest is invalid'
    end
    {
      'host_texture_export_verified' => true,
      'host_visual_pixel_sha256' => visual_sha,
      'host_pixel_width' => prepared[:pixel_width].to_i,
      'host_pixel_height' => prepared[:pixel_height].to_i,
      'host_texture_export_byte_size' => File.size(png_path).to_i
    }
  rescue EvidenceError
    raise
  rescue StandardError => error
    raise EvidenceError, "host texture pixel evidence failed: #{error.message}"
  ensure
    cleanup_failures = []
    [raw_path, png_path].compact.each do |path|
      begin
        File.delete(path) if File.file?(path)
      rescue StandardError => error
        cleanup_failures << "#{path}: #{error.message}"
      end
    end
    if directory
      begin
        FileUtils.remove_entry(directory) if File.directory?(directory)
      rescue StandardError => error
        cleanup_failures << "#{directory}: #{error.message}"
      end
    end
    unless cleanup_failures.empty?
      raise EvidenceError,
            "host texture proof cleanup failed: #{cleanup_failures.join('; ')}"
    end
  end
  private_class_method :texture_pixel_evidence

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
        'raster_visual_pixel_sha256',
        'raster_content_bytes', 'raster_source_pdf_sha256',
        'raster_alpha_verified',
        'raster_transparent_background_verified',
        'raster_visible_pixel_verified',
        'raster_page_render_once_verified', 'raster_page_render_sha256'
      ].each do |key|
        attributes[key] = entity.get_attribute(dictionary, key, nil)
      end
    end
    evidence = {
      'image_like' => true,
      'display_width' => width,
      'display_height' => height,
      'raster_page_number' => attributes['raster_page_number'],
      'raster_pixel_width' => attributes['raster_pixel_width'],
      'raster_pixel_height' => attributes['raster_pixel_height'],
      'raster_content_sha256' => attributes['raster_content_sha256'],
      'raster_visual_pixel_sha256' =>
        attributes['raster_visual_pixel_sha256'],
      'raster_content_bytes' => attributes['raster_content_bytes'],
      'raster_source_pdf_sha256' => attributes['raster_source_pdf_sha256'],
      'raster_alpha_verified' => attributes['raster_alpha_verified'],
      'raster_transparent_background_verified' =>
        attributes['raster_transparent_background_verified'],
      'raster_visible_pixel_verified' =>
        attributes['raster_visible_pixel_verified'],
      'raster_page_render_once_verified' =>
        attributes['raster_page_render_once_verified'],
      'raster_page_render_sha256' =>
        attributes['raster_page_render_sha256'],
      'source_span_id' => attributes['source_span_id']
    }
    claimed_visual_sha = attributes['raster_visual_pixel_sha256'].to_s.strip
    evidence.merge!(texture_pixel_evidence(entity)) unless
      claimed_visual_sha.empty?
    evidence
  rescue StandardError => error
    raise EvidenceError, "host image content evidence failed: #{error.message}"
  end
  private_class_method :image_content_evidence

  def self.native_text_content_evidence(entity, typename)
    return nil unless typename.to_s == 'Text'
    text = entity.respond_to?(:text) ? entity.text.to_s : nil
    point = entity.respond_to?(:point) ? point_payload(entity.point) : nil
    leader = if entity.respond_to?(:display_leader?)
               entity.display_leader?
             elsif entity.respond_to?(:display_leader)
               entity.display_leader
             end
    {
      'text_like' => true,
      'text' => text,
      'text_sha256' => text.nil? ? nil : Digest::SHA256.hexdigest(text),
      'anchor' => point,
      'leader_visible' => leader
    }
  rescue StandardError => error
    raise EvidenceError, "host text content evidence failed: #{error.message}"
  end
  private_class_method :native_text_content_evidence

  def self.host_content_evidence(entity, typename)
    image = image_content_evidence(entity, typename)
    return image if image
    native_text_content_evidence(entity, typename)
  end
  private_class_method :host_content_evidence

  def self.representation_identity_evidence(entity)
    return nil unless entity.respond_to?(:get_attribute)
    dictionary = 'BC_PDF_Importer'
    values = {}
    base_keys = [
      'source_span_id', 'source_unit_id', 'source_kind', 'representation',
      'renderer'
    ]
    base_keys.each do |key|
      values[key] = entity.get_attribute(dictionary, key, nil)
    end
    claim_root = entity.get_attribute(dictionary, 'source_claim_root', nil)
    values['source_claim_root'] = claim_root unless claim_root.nil?
    [
      'source_evidence_sha256', 'source_text_sha256',
      'physical_geometry_sha256', 'physical_style_sha256'
    ].each do |key|
      value = entity.get_attribute(dictionary, key, nil)
      values[key] = value unless value.nil?
    end
    return nil if values.values.all? { |value| value.nil? }
    values
  rescue StandardError => error
    raise EvidenceError,
          "host representation identity evidence failed: #{error.message}"
  end
  private_class_method :representation_identity_evidence

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
        if sets[namespace].include?(value)
          raise EvidenceError,
                "duplicate entity manifest #{namespace}:#{value}"
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
        raise EvidenceError, "duplicate persistent_id:#{persistent_id}"
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

  def self.verify_delivery_record!(collection_name, index, record, namespaces,
                                   claim_rows = nil, strict = false)
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
    if strict
      rows_by_claim = claim_rows || {}
      keys = normalized.map do |namespace, value|
        "#{namespace}:#{value}"
      end
      rows = keys.map { |key| rows_by_claim[key] }
      if rows.any? { |row| row.nil? } ||
         rows.map { |row| hash_value(row, :entity_id) }.uniq.length != rows.length
        raise EvidenceError,
              "#{collection_name}[#{index}] aliases or duplicates one host entity"
      end
      verify_host_representation!(
        collection_name, index, record, rows
      )
    end
  end
  private_class_method :verify_delivery_record!

  def self.record_delivery_mode!(collection_name, index, record)
    explicit = normalize_mode(hash_value(record, :delivered_mode))
    created_type = hash_value(record, :created_entity_type).to_s.strip
    derived = CREATED_ENTITY_MODES[created_type]
    if explicit && derived && explicit != derived
      raise EvidenceError,
            "#{collection_name}[#{index}] host entity type conflicts with delivered mode"
    end
    explicit || derived
  end
  private_class_method :record_delivery_mode!

  def self.verify_host_representation!(collection_name, index, record, rows)
    mode = record_delivery_mode!(collection_name, index, record)
    return true unless mode
    label = "#{collection_name}[#{index}] #{mode}"
    rows.each { |row| verify_live_manifest_row!(row, label) }
    verify_representation_identity!(record, rows, mode, label)
    case mode
    when :labels
      verify_native_labels!(rows, record, label)
    when :text3d
      verify_text3d_rows!(rows, record, label)
    when :glyphs
      verify_glyph_rows!(rows, record, label)
    when :geometry
      verify_geometry_rows!(rows, record, label)
    when :raster
      rows.each do |row|
        unless image_typename?(hash_value(row, :typename))
          raise EvidenceError, "#{label} is not a host image representation"
        end
      end
    else
      raise EvidenceError, "#{label} has an unsupported delivered representation"
    end
    true
  end
  private_class_method :verify_host_representation!

  def self.verify_live_manifest_row!(row, label)
    unless hash_value(row, :valid) == true &&
           hash_value(row, :deleted) == false
      raise EvidenceError, "#{label} claims a host entity that is not live"
    end
  end
  private_class_method :verify_live_manifest_row!

  def self.verify_representation_identity!(record, rows, mode, label)
    expected_spans = source_span_ids(record, :span_id => true)
    expected_unit = hash_value(record, :source_unit_id).to_s.strip
    rows.each do |row|
      evidence = hash_value(row, :representation_evidence)
      next unless evidence.is_a?(Hash)
      declared = hash_value(evidence, :representation)
      unless declared.nil? || declared.to_s.strip.empty?
        unless normalize_mode(declared) == mode
          raise EvidenceError, "#{label} host representation attribute conflicts"
        end
      end
      # Recursive exact source ownership is enforced against the source-bound
      # evidence digest after page, fallback, and alias validation.
      source_unit = hash_value(evidence, :source_unit_id).to_s.strip
      if !expected_unit.empty? && source_unit != expected_unit
        raise EvidenceError, "#{label} host source-unit identity conflicts"
      end
    end
    true
  end
  private_class_method :verify_representation_identity!

  def self.verify_source_expected_evidence!(record, rows, mode, label)
    expected = hash_value(record, :expected_evidence)
    unless expected.is_a?(Hash) &&
           hash_value(expected, :schema).to_s == 'bcs.source_expected/1.0'
      raise EvidenceError, "#{label} source-bound expected evidence is missing"
    end
    spans = source_span_ids(record, :span_id => true)
    unless spans.length == 1 &&
           hash_value(expected, :source_span_id).to_s == spans[0] &&
           normalize_mode(hash_value(expected, :representation)) == mode
      raise EvidenceError, "#{label} expected evidence belongs to another source"
    end
    sha_fields = [
      :source_text_sha256, :source_font_sha256,
      :physical_geometry_sha256, :physical_style_sha256,
      :evidence_sha256
    ]
    unless sha_fields.all? do |field|
      hash_value(expected, field).to_s.downcase =~ /\A[0-9a-f]{64}\z/
    end
      raise EvidenceError, "#{label} expected evidence digests are incomplete"
    end
    canonical = expected.dup
    canonical.delete(:evidence_sha256)
    canonical.delete('evidence_sha256')
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    unless fidelity.canonical_sha256(canonical) ==
           hash_value(expected, :evidence_sha256).to_s.downcase
      raise EvidenceError, "#{label} expected evidence digest is invalid"
    end
    verify_record_expected_consistency!(record, expected, label)

    geometry = manifest_evidence_summary!(
      rows, :geometry_evidence, label, true
    )
    style = manifest_evidence_summary!(
      rows, :style_evidence, label, false
    )
    unless geometry[:sha256] ==
           hash_value(expected, :physical_geometry_sha256).to_s.downcase
      raise EvidenceError, "#{label} physical geometry differs from source expectation"
    end
    unless style[:sha256] ==
           hash_value(expected, :physical_style_sha256).to_s.downcase
      raise EvidenceError, "#{label} physical style differs from source expectation"
    end
    unless geometry[:physical_entity_count] == exact_positive_integer!(
      hash_value(expected, :physical_entity_count),
      "#{label} physical entity count"
    )
      raise EvidenceError, "#{label} physical entity count differs from expectation"
    end
    if style[:physical_entity_count] &&
       style[:physical_entity_count] != geometry[:physical_entity_count]
      raise EvidenceError, "#{label} physical style entity count differs"
    end
    verify_expected_identity_tree!(
      rows, spans[0], mode,
      hash_value(expected, :evidence_sha256).to_s.downcase, label
    )
    verify_expected_dimensions!(expected, rows, mode, label)
    true
  end
  private_class_method :verify_source_expected_evidence!

  def self.verify_record_expected_consistency!(record, expected, label)
    bindings = {
      :source_text_sha256 => :source_text_sha256,
      :source_font_sha256 => :source_font_sha256,
      :source_bbox_pdf => :source_bbox_pdf,
      :source_anchor => :source_anchor,
      :source_rotation_radians => :source_rotation_radians,
      :expected_width => :expected_width,
      :expected_height => :expected_height,
      :expected_depth => :expected_depth,
      :expected_bounds => :expected_bounds,
      :expected_transform => :expected_transformation,
      :expected_transformation => :expected_transformation,
      :source_geometry_sha256 => :physical_geometry_sha256,
      :physical_geometry_sha256 => :physical_geometry_sha256,
      :source_style_sha256 => :physical_style_sha256,
      :physical_style_sha256 => :physical_style_sha256,
      :physical_entity_count => :physical_entity_count
    }
    bindings.each do |record_field, expected_field|
      next unless hash_key?(record, record_field)
      unless evidence_payload_equal?(
        hash_value(record, record_field), hash_value(expected, expected_field)
      )
        raise EvidenceError,
              "#{label} #{record_field} conflicts with source-bound expectation"
      end
    end
    true
  end
  private_class_method :verify_record_expected_consistency!

  def self.verify_source_expected_attempts!(attempts, rows_by_claim)
    Array(attempts).each_with_index do |attempt, index|
      mode = normalize_mode(hash_value(attempt, :delivered_mode))
      next if mode == :raster
      claims = canonical_claims!(
        hash_value(attempt, :resulting_entity_ids), 'attempt', false
      )
      rows = claims.map { |claim| rows_by_claim[claim] }
      if rows.any? { |row| row.nil? }
        raise EvidenceError, "text_attempts[#{index}] manifest binding is missing"
      end
      verify_source_expected_evidence!(
        attempt, rows, mode, "text_attempts[#{index}] #{mode}"
      )
    end
    true
  end
  private_class_method :verify_source_expected_attempts!

  def self.manifest_evidence_summary!(rows, key, label, count_geometry)
    values = Array(rows)
    compact = values.select do |row|
      evidence = hash_value(row, key)
      hash_value(evidence, :schema).to_s ==
        'bcs.host_physical_partition/1.0'
    end
    unless compact.empty?
      unless compact.length == values.length && values.length == 1
        raise EvidenceError,
              "#{label} #{key} compact partitions must identify one claim root"
      end
      unless compact_physical_partition_row?(values.first)
        raise EvidenceError, "#{label} compact physical partition is invalid"
      end
      evidence = hash_value(values.first, key)
      sha = hash_value(evidence, :sha256).to_s.downcase
      unless sha =~ /\A[0-9a-f]{64}\z/
        raise EvidenceError, "#{label} #{key} digest is unavailable"
      end
      count = exact_positive_integer!(
        hash_value(evidence, :physical_entity_count),
        "#{label} #{key} physical entity count"
      )
      return { :sha256 => sha, :physical_entity_count => count }
    end

    payload = []
    values.each do |row|
      evidence = hash_value(row, key)
      row_payload = hash_value(evidence, :payload) if evidence.is_a?(Hash)
      unless row_payload.is_a?(Array) && !row_payload.empty?
        raise EvidenceError, "#{label} #{key} is unavailable"
      end
      fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
      unless fidelity.canonical_sha256(row_payload) ==
             hash_value(evidence, :sha256).to_s.downcase
        raise EvidenceError, "#{label} #{key} row digest is invalid"
      end
      payload.concat(row_payload)
    end
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    payload = payload.sort_by { |entry| fidelity.canonical_json(entry) }
    count = if count_geometry
              payload.inject(0) do |total, entry|
                total + geometry_payload_entity_count(entry)
              end
            end
    {
      :sha256 => fidelity.canonical_sha256(payload),
      :physical_entity_count => count
    }
  end
  private_class_method :manifest_evidence_summary!

  def self.geometry_payload_entity_count(payload)
    children = hash_value(payload, :children)
    1 + Array(children).inject(0) do |total, child|
      total + geometry_payload_entity_count(child)
    end
  end
  private_class_method :geometry_payload_entity_count

  def self.verify_expected_identity_tree!(rows, source_id, mode, digest, label)
    compact = Array(rows).all? { |row| compact_physical_partition_row?(row) }
    targets = []
    if compact
      targets = Array(rows)
    else
      visit_manifest(Array(rows)) { |row| targets << row }
    end
    targets.each do |row|
      evidence = hash_value(row, :representation_evidence)
      unless evidence.is_a?(Hash) &&
             hash_value(evidence, :source_span_id).to_s == source_id &&
             normalize_mode(hash_value(evidence, :representation)) == mode &&
             hash_value(evidence, :source_evidence_sha256).to_s.downcase == digest
        raise EvidenceError,
              "#{label} physical descendant lacks exact source evidence identity"
      end
      if compact && hash_value(evidence, :source_claim_root) != true
        raise EvidenceError, "#{label} compact evidence is not a source claim root"
      end
    end
    true
  end
  private_class_method :verify_expected_identity_tree!

  def self.compact_physical_partition_row?(row)
    geometry = hash_value(row, :geometry_evidence)
    style = hash_value(row, :style_evidence)
    valid_evidence = [geometry, style].all? do |evidence|
      evidence.is_a?(Hash) &&
        hash_value(evidence, :schema).to_s ==
          'bcs.host_physical_partition/1.0' &&
        hash_value(evidence, :sha256).to_s.downcase =~ /\A[0-9a-f]{64}\z/ &&
        hash_value(evidence, :physical_entity_count).is_a?(Integer) &&
        hash_value(evidence, :physical_entity_count) > 0
    end
    return false unless valid_evidence
    count = hash_value(geometry, :physical_entity_count)
    return false unless hash_value(style, :physical_entity_count) == count
    topology = hash_value(geometry, :topology)
    return false unless topology.is_a?(Hash)
    root_type = hash_value(topology, :root_type).to_s
    direct_types = hash_value(topology, :direct_child_types)
    type_counts = hash_value(topology, :descendant_type_counts)
    descendant_count = hash_value(topology, :descendant_entity_count)
    live_count = hash_value(topology, :live_entity_count)
    return false if root_type.empty? ||
      root_type != hash_value(row, :typename).to_s
    return false unless direct_types.is_a?(Array) && direct_types.all? do |type|
      type.is_a?(String) && !type.empty?
    end
    return false unless type_counts.is_a?(Hash) && type_counts.all? do |type, value|
      !type.to_s.empty? && value.is_a?(Integer) && value > 0
    end
    return false unless descendant_count.is_a?(Integer) && descendant_count >= 0 &&
      descendant_count == count - 1 &&
      descendant_count == type_counts.values.inject(0, :+)
    return false unless live_count.is_a?(Integer) && live_count == count
    direct_counts = direct_types.inject({}) do |memo, type|
      memo[type] = memo.fetch(type, 0) + 1
      memo
    end
    direct_counts.all? do |type, value|
      type_counts.fetch(type, 0) >= value
    end
  rescue StandardError
    false
  end
  private_class_method :compact_physical_partition_row?

  def self.compact_topology!(row, label)
    unless compact_physical_partition_row?(row)
      raise EvidenceError, "#{label} compact physical topology is invalid"
    end
    hash_value(hash_value(row, :geometry_evidence), :topology)
  end
  private_class_method :compact_topology!

  def self.verify_expected_dimensions!(expected, rows, mode, label)
    anchor = hash_value(expected, :source_anchor)
    rotation = hash_value(expected, :source_rotation_radians)
    unless numeric_point_payload?(anchor) && positive_finite_number?(
      hash_value(expected, :expected_width)
    ) && positive_finite_number?(hash_value(expected, :expected_height)) &&
           rotation.is_a?(Numeric) && rotation.to_f.finite?
      raise EvidenceError, "#{label} source dimensions/placement are incomplete"
    end
    depth = hash_value(expected, :expected_depth)
    unless depth.is_a?(Numeric) && depth.to_f.finite? && depth.to_f >= 0.0
      raise EvidenceError, "#{label} source depth is invalid"
    end
    if mode == :text3d && depth.to_f <= 0.0
      raise EvidenceError, "#{label} expected 3D Text depth is not positive"
    end
    if [:text3d, :glyphs, :geometry].include?(mode)
      bounds = hash_value(expected, :expected_bounds)
      transform = hash_value(expected, :expected_transformation)
      unless bounds.is_a?(Hash) && !transform.nil?
        raise EvidenceError, "#{label} expected physical bounds/transform are missing"
      end
      if rows.length == 1
        unless evidence_payload_equal?(bounds, hash_value(rows[0], :bounds))
          raise EvidenceError, "#{label} saved bounds differ from source expectation"
        end
        row_transform = hash_value(rows[0], :transformation)
        unless transform.is_a?(Hash) &&
               hash_value(transform, :kind).to_s == 'baked_geometry'
          unless evidence_payload_equal?(transform, row_transform)
            raise EvidenceError,
                  "#{label} saved transform differs from source expectation"
          end
        end
      end
    end
    true
  end
  private_class_method :verify_expected_dimensions!

  def self.verify_native_labels!(rows, record, label)
    expected_digest = hash_value(record, :source_text_sha256).to_s.downcase
    unless expected_digest =~ /\A[0-9a-f]{64}\z/
      raise EvidenceError, "#{label} source text digest is missing"
    end
    expected = hash_value(record, :expected_evidence)
    expected_anchor = expected.is_a?(Hash) ?
      hash_value(expected, :source_anchor) : nil
    expected_rotation = expected.is_a?(Hash) ?
      hash_value(expected, :source_rotation_radians) : nil
    if expected.is_a?(Hash) &&
       (!numeric_point_payload?(expected_anchor) ||
        !expected_rotation.is_a?(Numeric) ||
        expected_rotation.to_f.abs > 1.0e-12)
      raise EvidenceError, "#{label} exact source anchor/rotation is missing"
    end
    valid = rows.all? do |row|
      content = hash_value(row, :content_evidence)
      actual_text = hash_value(content, :text).to_s
      hash_value(row, :typename).to_s == 'Text' &&
        content.is_a?(Hash) && hash_value(content, :text_like) == true &&
        !actual_text.empty? &&
        Digest::SHA256.hexdigest(actual_text) == expected_digest &&
        hash_value(content, :text_sha256).to_s.downcase == expected_digest &&
        numeric_point_payload?(hash_value(content, :anchor)) &&
        (!expected.is_a?(Hash) || [0, 1, 2].all? do |axis|
          (hash_value(content, :anchor)[axis].to_f -
            expected_anchor[axis].to_f).abs <= 1.0e-6
        end) &&
        hash_value(content, :leader_visible) == false &&
        Array(hash_value(row, :children)).empty?
    end
    raise EvidenceError, "#{label} is not verified native SketchUp Text" unless valid
    true
  end
  private_class_method :verify_native_labels!

  def self.verify_text3d_rows!(rows, record, label)
    types = rows.map { |row| hash_value(row, :typename).to_s }
    if types.all? { |type| type == 'Group' }
      rows.each do |row|
        evidence = hash_value(row, :representation_evidence)
        unless evidence.is_a?(Hash) &&
               normalize_mode(hash_value(evidence, :representation)) == :text3d &&
               !hash_value(evidence, :renderer).to_s.strip.empty?
          raise EvidenceError, "#{label} lacks persisted 3D Text identity"
        end
        if compact_physical_partition_row?(row)
          topology = compact_topology!(row, label)
          counts = hash_value(topology, :descendant_type_counts)
          types = counts.keys.map(&:to_s)
          unless counts.fetch('Face', 0) > 0 && counts.fetch('Edge', 0) > 0 &&
                 (types - ['Group', 'Face', 'Edge']).empty? &&
                 positive_z_depth?(hash_value(row, :bounds))
            raise EvidenceError, "#{label} is not positive-depth 3D Text geometry"
          end
          next
        end
        descendants = descendant_manifest_rows(row)
        descendants.each do |child|
          verify_live_manifest_row!(child, "#{label} physical child")
        end
        descendant_types = descendants.map do |child|
          hash_value(child, :typename).to_s
        end
        unless descendant_types.include?('Face') &&
               descendant_types.include?('Edge') &&
               (descendant_types - ['Group', 'Face', 'Edge']).empty? &&
               positive_z_depth?(hash_value(row, :bounds))
          raise EvidenceError, "#{label} is not positive-depth 3D Text geometry"
        end
      end
      return true
    end

    unless (types - ['Face', 'Edge']).empty? && types.include?('Face') &&
           rows.any? { |row| positive_z_depth?(hash_value(row, :bounds)) }
      raise EvidenceError, "#{label} is not positive-depth native 3D Text"
    end
    created_type = hash_value(record, :created_entity_type).to_s
    if !created_type.empty? && created_type != 'native_3d_text'
      raise EvidenceError, "#{label} host structure conflicts with 3D Text type"
    end
    true
  end
  private_class_method :verify_text3d_rows!

  def self.verify_geometry_rows!(rows, record, label)
    unless rows.length == 1 && hash_value(rows[0], :typename).to_s == 'Group'
      raise EvidenceError, "#{label} must identify one owned Geometry group"
    end
    children = Array(hash_value(rows[0], :children))
    if compact_physical_partition_row?(rows[0])
      topology = compact_topology!(rows[0], label)
      direct = hash_value(topology, :direct_child_types)
      counts = hash_value(topology, :descendant_type_counts)
      unless !direct.empty? && direct.all? { |type| type == 'Edge' } &&
             counts.keys.map(&:to_s) == ['Edge'] &&
             counts['Edge'] == direct.length &&
             !positive_z_depth?(hash_value(rows[0], :bounds))
        raise EvidenceError, "#{label} is not flat raw-edge Geometry"
      end
      verify_item_group_identity_if_required!(rows[0], record, :geometry, label)
      return true
    end
    children.each do |child|
      verify_live_manifest_row!(child, "#{label} physical child")
    end
    unless !children.empty? && children.all? do |child|
      hash_value(child, :typename).to_s == 'Edge' &&
        Array(hash_value(child, :children)).empty?
    end
      raise EvidenceError, "#{label} is not flat raw-edge Geometry"
    end
    verify_item_group_identity_if_required!(rows[0], record, :geometry, label)
    true
  end
  private_class_method :verify_geometry_rows!

  def self.verify_glyph_rows!(rows, record, label)
    unless rows.length == 1 && hash_value(rows[0], :typename).to_s == 'Group'
      raise EvidenceError, "#{label} must identify one owned Glyphs group"
    end
    children = Array(hash_value(rows[0], :children))
    if compact_physical_partition_row?(rows[0])
      topology = compact_topology!(rows[0], label)
      direct = hash_value(topology, :direct_child_types)
      counts = hash_value(topology, :descendant_type_counts)
      allowed = ['Group', 'ComponentInstance', 'Edge']
      unless !direct.empty? && direct.all? do |type|
        ['Group', 'ComponentInstance'].include?(type)
      end && counts.fetch('Edge', 0) > 0 &&
             (counts.keys.map(&:to_s) - allowed).empty?
        raise EvidenceError, "#{label} is not a physical Glyphs hierarchy"
      end
      verify_item_group_identity_if_required!(rows[0], record, :glyphs, label)
      return true
    end
    descendants = descendant_manifest_rows(rows[0])
    descendants.each do |child|
      verify_live_manifest_row!(child, "#{label} physical child")
    end
    descendant_types = descendants.map do |child|
      hash_value(child, :typename).to_s
    end
    valid_containers = children.all? do |child|
      ['Group', 'ComponentInstance'].include?(
        hash_value(child, :typename).to_s
      )
    end
    allowed = ['Group', 'ComponentInstance', 'Edge']
    unless !children.empty? && valid_containers &&
           descendant_types.include?('Edge') &&
           (descendant_types - allowed).empty?
      raise EvidenceError, "#{label} is not a physical Glyphs hierarchy"
    end
    verify_item_group_identity_if_required!(rows[0], record, :glyphs, label)
    true
  end
  private_class_method :verify_glyph_rows!

  def self.verify_item_group_identity_if_required!(row, record, mode, label)
    return true unless hash_key?(record, :source_span_id)
    evidence = hash_value(row, :representation_evidence)
    unless evidence.is_a?(Hash) &&
           normalize_mode(hash_value(evidence, :representation)) == mode &&
           hash_value(evidence, :source_span_id).to_s ==
             hash_value(record, :source_span_id).to_s
      raise EvidenceError, "#{label} lacks exact item representation identity"
    end
    true
  end
  private_class_method :verify_item_group_identity_if_required!

  def self.descendant_manifest_rows(row)
    descendants = []
    Array(hash_value(row, :children)).each do |child|
      descendants << child
      descendants.concat(descendant_manifest_rows(child))
    end
    descendants
  end
  private_class_method :descendant_manifest_rows

  def self.numeric_point_payload?(value)
    value.is_a?(Array) && value.length == 3 && value.all? do |number|
      number.is_a?(Numeric) && number.to_f.finite?
    end
  rescue StandardError
    false
  end
  private_class_method :numeric_point_payload?

  def self.positive_z_depth?(bounds)
    return false unless bounds.is_a?(Hash)
    minimum = hash_value(bounds, :min)
    maximum = hash_value(bounds, :max)
    return false unless numeric_point_payload?(minimum) &&
                        numeric_point_payload?(maximum)
    (maximum[2].to_f - minimum[2].to_f).abs > 1.0e-9
  rescue StandardError
    false
  end
  private_class_method :positive_z_depth?

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
           exact_positive_integer!(
             raw_page, "#{collection_name}[#{index}] page"
           ) == pages[0]
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
                                 to_mode, selected_pages, attempt = nil)
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
           exact_positive_integer!(
             hash_value(proof, :page_number), 'fallback proof page_number'
           ) == page &&
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
    evidence_digest = nil
    if actual_from == :text
      fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
      begin
        fidelity.validate_flat_editable_text_transition!(
          proof, expected_mode, source_id
        )
      rescue StandardError => error
        raise EvidenceError,
              "flat Text capability transition is invalid: #{error.message}"
      end
      evidence_digest = hash_value(evidence, :evidence_sha256).to_s.downcase
      if attempt
        attempt_sha = hash_value(attempt, :source_text_sha256).to_s.downcase
        proof_sha = hash_value(evidence, :source_text_sha256).to_s.downcase
        attempt_bbox = hash_value(attempt, :source_bbox_pdf)
        proof_bbox = hash_value(evidence, :source_bbox_pdf)
        unless attempt_sha =~ /\A[0-9a-f]{64}\z/ && attempt_sha == proof_sha &&
               fidelity.canonical_json(attempt_bbox) ==
                 fidelity.canonical_json(proof_bbox)
          raise EvidenceError,
                'flat Text capability proof conflicts with source attempt'
        end
      end
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
     created.sort, cleaned.sort, cleanup, evidence_digest]
  end
  private_class_method :transition_signature!

  def self.verify_completed_rung!(rung, mode, expected_ids, source_id,
                                  attempt)
    unless rung.is_a?(Hash) && normalize_mode(hash_value(rung, :mode)) == mode &&
           hash_value(rung, :outcome).to_s == 'complete' &&
           canonical_claims!(
             hash_value(rung, :resulting_entity_ids), 'completed', false
           ).sort == expected_ids.sort &&
           hash_value(rung, :visual_fidelity_verified) == true &&
           hash_value(rung, :cleanup_outcome).to_s == 'not_required'
      raise EvidenceError, "#{source_id} completed rung is not bound to delivery"
    end
    verify_mode_flags!(rung, mode, "#{source_id} completed rung")
    if mode == :raster
      rung_artifact = hash_value(rung, :artifact_evidence)
      attempt_artifact = hash_value(attempt, :artifact_evidence)
      unless hash_value(rung, :real_raster_verified) == true &&
             hash_value(rung, :source_crop_binding_verified) == true &&
             rung_artifact.is_a?(Hash) && attempt_artifact.is_a?(Hash) &&
             evidence_payload_equal?(rung_artifact, attempt_artifact) &&
             hash_value(rung_artifact, :source_span_id).to_s == source_id &&
             hash_value(rung_artifact, :source_crop_binding_verified) == true &&
             hash_value(rung_artifact, :source_pdf_binding_verified) == true &&
             hash_value(rung_artifact, :source_pdf_sha256).to_s.downcase =~
               /\A[0-9a-f]{64}\z/
        raise EvidenceError, "#{source_id} raster rung lacks item crop evidence"
      end
    else
      attempt_expected = hash_value(attempt, :expected_evidence)
      rung_expected = hash_value(rung, :expected_evidence)
      unless attempt_expected.is_a?(Hash) && rung_expected.is_a?(Hash) &&
             evidence_payload_equal?(rung_expected, attempt_expected)
        raise EvidenceError,
              "#{source_id} completed rung changed its source-bound expectation"
      end
    end
    true
  end
  private_class_method :verify_completed_rung!

  def self.verify_mode_flags!(record, mode, label)
    return true if mode == :raster
    common = [
      :visual_fidelity_verified, :placement_verified, :rotation_verified,
      :content_verified, :entity_type_verified,
      :physical_geometry_verified, :physical_style_verified,
      :transform_verified
    ]
    required = common.dup
    case mode
    when :labels
      required << :leader_verified
    when :text3d
      required.concat([:width_verified, :height_verified, :depth_verified])
    when :glyphs, :geometry
      required.concat([
        :width_verified, :height_verified, :identity_verified,
        :visibility_verified
      ])
    else
      raise EvidenceError, "#{label} representation mode is invalid"
    end
    missing = required.reject { |field| hash_value(record, field) == true }
    unless missing.empty?
      raise EvidenceError,
            "#{label} mode-specific verification failed: #{missing.join(', ')}"
    end
    if mode == :text3d
      font_or_source = hash_value(record, :font_identity_verified) == true ||
        hash_value(record, :source_glyph_identity_verified) == true
      positive_depth = hash_value(record, :positive_z_depth_verified) == true ||
        hash_value(record, :depth_verified) == true
      unless font_or_source && positive_depth
        raise EvidenceError,
              "#{label} 3D Text content/font/depth verification is incomplete"
      end
    end
    true
  end
  private_class_method :verify_mode_flags!

  def self.verify_zero_canonical_page_inspection!(stats, page)
    immutable_sha = source_sha256_value(
      stats, :source_input_sha256, :immutable_pdf_sha256
    )
    rendered_sha = source_sha256_value(
      stats, :normalized_input_sha256, :normalized_pdf_sha256
    )
    matches = Array(hash_value(stats, :empty_page_source_inspections)).select do |row|
      row.is_a?(Hash) && hash_value(row, :page).is_a?(Integer) &&
        hash_value(row, :page) == page
    end
    unless matches.length == 1 &&
           immutable_sha =~ /\A[0-9a-f]{64}\z/ &&
           rendered_sha =~ /\A[0-9a-f]{64}\z/
      raise EvidenceError,
            'zero-canonical-text delivery lacks one exact source inspection'
    end
    row = matches[0]
    source_page = exact_positive_integer!(
      hash_value(row, :source_page_number),
      'zero-canonical-text inspection source page'
    )
    canonical_count = hash_value(row, :canonical_text_item_count)
    unless source_page == page && canonical_count.is_a?(Integer) &&
           canonical_count == 0 &&
           hash_value(row, :immutable_pdf_sha256).to_s.downcase ==
             immutable_sha &&
           hash_value(row, :rendered_pdf_sha256).to_s.downcase ==
             rendered_sha &&
           hash_value(row, :semantic_text_extraction_complete) == true &&
           hash_value(row, :decoded_stream_text_operators) == false &&
           hash_value(row, :decoded_form_stream_text_operators) == false
      raise EvidenceError,
            'zero-canonical-text inspection is not bound to exact PDF/page proof'
    end
    true
  end
  private_class_method :verify_zero_canonical_page_inspection!

  def self.verify_page_raster_delivery_basis!(stats, record, expected_mode,
                                              selected_pages)
    page = exact_positive_integer!(
      hash_value(record, :page), 'page raster delivery page'
    )
    unless selected_pages.empty? || selected_pages.include?(page)
      raise EvidenceError, 'page raster delivery is outside the selected page set'
    end
    basis = hash_value(record, :delivery_basis).to_s
    case basis
    when 'explicit_full_page_raster'
      unless expected_mode == :raster &&
             normalize_mode(hash_value(record, :requested_mode)) == :raster &&
             hash_value(record, :full_page_raster_request) == true &&
             hash_value(record, :semantic_text_evaluated) == false &&
             hash_value(record, :no_semantic_text) != true &&
             !hash_key?(record, :canonical_text_item_count)
        raise EvidenceError,
              'explicit full-page Raster is mislabeled as semantic-text proof'
      end
    when 'verified_zero_canonical_text'
      canonical_count = hash_value(record, :canonical_text_item_count)
      unless hash_value(record, :full_page_raster_request) != true &&
             hash_value(record, :semantic_text_evaluated) == true &&
             hash_value(record, :no_semantic_text) == true &&
             canonical_count.is_a?(Integer) && canonical_count == 0
        raise EvidenceError,
              'zero-canonical-text page Raster basis is incomplete'
      end
      verify_zero_canonical_page_inspection!(stats, page)
    else
      raise EvidenceError, 'page Raster delivery basis is missing or invalid'
    end
    true
  end
  private_class_method :verify_page_raster_delivery_basis!

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
        raise EvidenceError,
              "text_attempts[#{index}] must be one independently owned source item"
      else
        verify_mode_flags!(attempt, delivered,
                           "text_attempts[#{index}]")
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
            verify_completed_rung!(
              rung, mode, ids, source_id, attempt
            )
          else
            unless rung.is_a?(Hash) &&
                   normalize_mode(hash_value(rung, :mode)) == mode &&
                   hash_value(rung, :outcome).to_s == 'failed' &&
                   hash_value(rung, :resulting_entity_ids) == []
              raise EvidenceError, "#{source_id} failed rung is invalid"
            end
            attempt_signatures << transition_signature!(
              hash_value(rung, :transition_proof), expected_mode, source_id,
              mode, ladder[rung_index + 1], pages, attempt
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
            normalize_mode(hash_value(record, :delivered_mode)) == :raster
          verify_page_raster_delivery_basis!(
            stats, record, expected_mode, pages
          ) if allowed_page_raster
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
      if rows.key?("entity_id:#{entity_id}")
        raise EvidenceError, "duplicate entity_id:#{entity_id}"
      end
      if rows.key?("persistent_id:#{persistent_id}")
        raise EvidenceError, "duplicate persistent_id:#{persistent_id}"
      end
      rows["entity_id:#{entity_id}"] = row
      rows["persistent_id:#{persistent_id}"] = row
    end
    rows
  end
  private_class_method :manifest_claim_rows

  def self.verify_raster_artifact_binding!(record, row, claim, selected_pages,
                                           stats = nil)
    page = exact_positive_integer!(
      hash_value(record, :page), 'raster delivery page'
    )
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
    visual_sha256 = hash_value(artifact, :visual_pixel_sha256).to_s.downcase
    byte_size = exact_positive_integer!(
      hash_value(artifact, :content_byte_size), 'raster content byte size'
    )
    pixel_width = exact_positive_integer!(
      hash_value(artifact, :pixel_width), 'raster pixel width'
    )
    pixel_height = exact_positive_integer!(
      hash_value(artifact, :pixel_height), 'raster pixel height'
    )
    unless hash_value(content, :image_like) == true &&
           positive_finite_number?(hash_value(content, :display_width)) &&
           positive_finite_number?(hash_value(content, :display_height)) &&
           exact_positive_integer!(
             hash_value(artifact, :page_number), 'raster artifact page_number'
           ) == page &&
           hash_value(artifact, :png_signature_verified) == true &&
           hash_value(artifact, :page_binding_verified) == true &&
           pixel_width > 0 && pixel_height > 0 &&
           sha256 =~ /\A[0-9a-f]{64}\z/ && byte_size > 0 &&
           exact_positive_integer!(
             hash_value(content, :raster_page_number),
             'host raster page_number'
           ) == page &&
           exact_positive_integer!(
             hash_value(content, :raster_pixel_width),
             'host raster pixel width'
           ) == pixel_width &&
           exact_positive_integer!(
             hash_value(content, :raster_pixel_height),
             'host raster pixel height'
           ) == pixel_height &&
           hash_value(content, :raster_content_sha256).to_s.downcase == sha256 &&
           exact_positive_integer!(
             hash_value(content, :raster_content_bytes),
             'host raster content byte size'
           ) == byte_size
      raise EvidenceError, 'raster image content/page/identity evidence is incomplete'
    end
    if hash_value(artifact, :visual_pixel_binding_verified) == true ||
       !visual_sha256.empty?
      unless visual_sha256 =~ /\A[0-9a-f]{64}\z/ &&
             hash_value(artifact, :visual_pixel_binding_verified) == true &&
             hash_value(content, :raster_visual_pixel_sha256).to_s.downcase ==
               visual_sha256 &&
             hash_value(content, :host_texture_export_verified) == true &&
             hash_value(content, :host_visual_pixel_sha256).to_s.downcase ==
               visual_sha256 &&
             exact_positive_integer!(
               hash_value(content, :host_pixel_width),
               'host texture pixel width'
             ) == pixel_width &&
             exact_positive_integer!(
               hash_value(content, :host_pixel_height),
               'host texture pixel height'
             ) == pixel_height &&
             exact_positive_integer!(
               hash_value(content, :host_texture_export_byte_size),
               'host texture export byte size'
             ) > 0
        raise EvidenceError,
              'raster delivery lacks physical host texture pixel binding'
      end
    end
    scope = hash_value(record, :delivery_scope).to_s
    spans = source_span_ids(record, :span_id => false)
    if scope == 'item_raster'
      expected_source_sha = source_sha256_value(
        stats, :normalized_input_sha256, :normalized_pdf_sha256
      )
      artifact_source_sha = hash_value(
        artifact, :source_pdf_sha256
      ).to_s.downcase
      host_source_sha = hash_value(
        content, :raster_source_pdf_sha256
      ).to_s.downcase
      source_box = hash_value(artifact, :source_box)
      pixel_crop = hash_value(artifact, :pixel_crop)
      valid_source_box = source_box.is_a?(Array) && source_box.length == 4 &&
        source_box.all? do |value|
          value.is_a?(Numeric) && value.to_f.finite?
        end &&
        source_box[2].to_f > source_box[0].to_f &&
        source_box[3].to_f > source_box[1].to_f
      valid_pixel_crop = pixel_crop.is_a?(Array) && pixel_crop.length == 4 &&
        pixel_crop.all? { |value| value.is_a?(Integer) && value >= 0 } &&
        pixel_crop[2].to_i > 0 && pixel_crop[3].to_i > 0
      page_render_sha = hash_value(
        artifact, :page_render_content_sha256
      ).to_s.downcase
      unless spans.length == 1 &&
             source_span_page!(spans[0]) == page &&
             hash_value(record, :source_crop_binding_verified) == true &&
             hash_value(artifact, :source_span_id).to_s == spans[0] &&
             hash_value(artifact, :source_crop_binding_verified) == true &&
             hash_value(artifact, :source_pdf_binding_verified) == true &&
             !hash_value(artifact, :source_pdf_path).to_s.strip.empty? &&
             expected_source_sha =~ /\A[0-9a-f]{64}\z/ &&
             artifact_source_sha == expected_source_sha &&
             host_source_sha == expected_source_sha &&
             valid_source_box && valid_pixel_crop &&
             pixel_width == pixel_crop[2].to_i &&
             pixel_height == pixel_crop[3].to_i &&
             hash_value(artifact, :alpha_channel_verified) == true &&
             hash_value(artifact, :transparent_background_verified) == true &&
             hash_value(artifact, :visible_pixel_verified) == true &&
             hash_value(artifact, :page_render_once_verified) == true &&
             page_render_sha =~ /\A[0-9a-f]{64}\z/ &&
             hash_value(content, :raster_alpha_verified) == true &&
             hash_value(content, :raster_transparent_background_verified) == true &&
             hash_value(content, :raster_visible_pixel_verified) == true &&
             hash_value(content, :raster_page_render_once_verified) == true &&
             hash_value(content, :raster_page_render_sha256).to_s.downcase ==
               page_render_sha &&
             hash_value(content, :source_span_id).to_s == spans[0] &&
             hash_value(record, :cleanup_outcome).to_s == 'not_required'
        raise EvidenceError,
              'item raster lacks exact source/alpha/transparent page-crop binding'
      end
    elsif scope == 'page_raster'
      expected_source_sha = source_sha256_value(
        stats, :normalized_input_sha256, :normalized_pdf_sha256
      )
      artifact_source_sha = hash_value(
        artifact, :source_pdf_sha256
      ).to_s.downcase
      host_source_sha = hash_value(
        content, :raster_source_pdf_sha256
      ).to_s.downcase
      unless expected_source_sha =~ /\A[0-9a-f]{64}\z/ &&
             artifact_source_sha == expected_source_sha &&
             host_source_sha == expected_source_sha &&
             hash_value(artifact, :source_pdf_binding_verified) == true &&
             hash_value(artifact, :box_binding_verified) == true &&
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

  def self.terminal_item_raster_fallback_authorized?(stats, record,
                                                     expected_mode, span,
                                                     claims)
    return false if expected_mode == :raster
    return false unless hash_value(record, :explicit_request) == false &&
                        hash_value(record, :degraded) == true &&
                        hash_value(stats, :raster_fallback_used) == true &&
                        !Array(hash_value(stats, :fallback_transitions)).empty?
    ladder = MODE_LADDERS[expected_mode] || []
    return false unless ladder.last == :raster
    record_artifact = hash_value(record, :artifact_evidence)
    matches = Array(hash_value(stats, :text_attempts)).select do |attempt|
      source_span_ids(attempt, :span_id => false) == [span] &&
        normalize_mode(hash_value(attempt, :requested_mode)) == expected_mode &&
        normalize_mode(hash_value(attempt, :delivered_mode)) == :raster &&
        canonical_claims!(
          hash_value(attempt, :resulting_entity_ids), 'raster fallback', false
        ).sort == claims.sort &&
        evidence_payload_equal?(
          hash_value(attempt, :artifact_evidence), record_artifact
        )
    end
    return false unless matches.length == 1
    history = hash_value(matches[0], :attempt_history)
    return false unless history.is_a?(Array) && history.length == ladder.length
    final = history[-1]
    normalize_mode(hash_value(final, :mode)) == :raster &&
      hash_value(final, :outcome).to_s == 'complete' &&
      evidence_payload_equal?(
        hash_value(final, :artifact_evidence), record_artifact
      )
  end
  private_class_method :terminal_item_raster_fallback_authorized?

  def self.verify_raster_deliveries!(stats, manifest, requested_mode,
                                     selected_pages)
    expected_mode = normalize_mode(requested_mode)
    pages = normalized_pages(selected_pages, stats)
    rows = manifest_claim_rows(manifest)
    signatures = []
    delivery_pages = []
    item_span_ids = []
    page_delivery_pages = []
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
      verify_raster_artifact_binding!(record, row, claim, pages, stats)
      page = exact_positive_integer!(
        hash_value(record, :page), 'raster delivery page'
      )
      scope = hash_value(record, :delivery_scope).to_s
      spans = source_span_ids(record, :span_id => false)
      if scope == 'item_raster'
        explicit_request = expected_mode == :raster &&
          hash_value(record, :explicit_request) == true
        terminal_fallback = spans.length == 1 &&
          terminal_item_raster_fallback_authorized?(
            stats, record, expected_mode, spans[0], claims
          )
        unless spans.length == 1 && (explicit_request || terminal_fallback)
          raise EvidenceError,
                'item Raster is neither explicit nor a proven terminal fallback'
        end
        item_span_ids << spans[0]
      elsif scope == 'page_raster'
        unless spans.empty?
          raise EvidenceError,
                'requested page Raster is not source-free page delivery'
        end
        verify_page_raster_delivery_basis!(
          stats, record, expected_mode, pages
        )
        page_delivery_pages << page
      end
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
      terminal_raster_signatures << [
        exact_positive_integer!(
          hash_value(record, :page), 'terminal raster page'
        ),
        claims[0]
      ]
    end
    unless terminal_raster_signatures.sort == signatures.sort
      raise EvidenceError,
            'terminal raster deliveries do not match raster delivery records'
    end

    return true unless expected_mode == :raster
    source_ids = Array(hash_value(stats, :text_source_span_ids))
    source_pages = source_ids.map { |source_id| source_span_page!(source_id) }.
      uniq.sort
    expected_page_deliveries = pages.empty? ? page_delivery_pages.sort :
      (pages - source_pages).sort
    unless item_span_ids.uniq.length == item_span_ids.length &&
           item_span_ids.sort == source_ids.map { |value| value.to_s }.sort
      raise EvidenceError, 'requested Raster item delivery set mismatch'
    end
    if signatures.empty? ||
       page_delivery_pages.uniq.length != page_delivery_pages.length ||
       page_delivery_pages.sort != expected_page_deliveries
      raise EvidenceError, 'Raster page delivery set mismatch'
    end
    unless Array(hash_value(stats, :source_provenance_objects)).empty? &&
           Array(hash_value(stats, :page_text_delivery_records)).empty?
      raise EvidenceError, 'requested Raster contains non-raster delivery evidence'
    end
    if hash_value(stats, :raster_fallback_used) == true ||
       !Array(hash_value(stats, :fallback_transitions)).empty? ||
       !Array(hash_value(stats, :page_representation_fallbacks)).empty?
      raise EvidenceError, 'requested Raster is mislabeled as fallback'
    end
    renderers = Array(hash_value(stats, :text_renderers))
    unless renderers.all? do |renderer|
             normalize_mode(hash_value(renderer, :requested_mode)) == :raster &&
               normalize_mode(hash_value(renderer, :delivered_mode)) == :raster &&
               hash_value(renderer, :degraded) == false
           end
      raise EvidenceError, 'requested Raster renderer is degraded or misbound'
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
      [
        exact_positive_integer!(
          hash_value(record, :page), 'terminal Raster page'
        ),
        claims[0]
      ]
    end
    unless terminal_signatures.sort == signatures.sort
      raise EvidenceError, 'Raster terminal delivery identities do not crosslink'
    end
    true
  end
  private_class_method :verify_raster_deliveries!

  def self.verify_page_representation_fallbacks!(stats, requested_mode,
                                                  selected_pages)
    expected_mode = normalize_mode(requested_mode)
    pages = normalized_pages(selected_pages, stats)
    fallbacks = Array(hash_value(stats, :page_representation_fallbacks))
    if expected_mode == :raster
      unless fallbacks.empty?
        raise EvidenceError,
              'requested Raster cannot be relabeled as a page fallback'
      end
      return true
    end

    immutable_sha = source_sha256_value(
      stats, :source_input_sha256, :immutable_pdf_sha256
    )
    rendered_sha = source_sha256_value(
      stats, :normalized_input_sha256, :normalized_pdf_sha256
    )
    fallback_signatures = fallbacks.map do |record|
      unless record.is_a?(Hash)
        raise EvidenceError, 'page fallback record is invalid'
      end
      page = exact_positive_integer!(
        hash_value(record, :page), 'page fallback page'
      )
      source_page = exact_positive_integer!(
        hash_value(record, :source_page_number), 'page fallback source page'
      )
      claims = canonical_claims!(
        hash_value(record, :resulting_entity_ids), 'page fallback', false
      )
      summary = hash_value(record, :source_summary)
      source_items = hash_value(record, :source_text_items)
      canonical_items = hash_value(record, :canonical_text_item_count)
      asset_count = hash_value(record, :embedded_image_asset_count)
      placed_count = hash_value(record, :embedded_image_placed_count)
      glyph_count = hash_value(summary, :source_glyph_placements)
      unless (pages.empty? || pages.include?(page)) && source_page == page &&
             claims.length == 1 &&
             hash_value(record, :scope).to_s == 'page' &&
             hash_value(record, :reason_code).to_s ==
               'visible_nontext_source_only' &&
             hash_value(record, :affirmative_impossibility) == true &&
             normalize_mode(hash_value(record, :requested_text_mode)) ==
               expected_mode &&
             normalize_mode(hash_value(record, :delivered_mode)) == :raster &&
             source_items.is_a?(Integer) && source_items == 0 &&
             canonical_items.is_a?(Integer) && canonical_items == 0 &&
             hash_value(record, :immutable_pdf_sha256).to_s.downcase ==
               immutable_sha &&
             hash_value(record, :rendered_pdf_sha256).to_s.downcase ==
               rendered_sha &&
             asset_count.is_a?(Integer) && asset_count >= 0 &&
             placed_count.is_a?(Integer) && placed_count == 0 &&
             summary.is_a?(Hash) && glyph_count.is_a?(Integer) &&
             glyph_count == 0 &&
             hash_value(summary, :visible_nontext_source) == true &&
             hash_value(record, :real_raster_verified) == true &&
             hash_value(record, :visual_fidelity_verified) == true
        raise EvidenceError,
              'page fallback lacks affirmative source-bound impossibility proof'
      end
      [page, claims[0]]
    end

    raster_signatures = Array(hash_value(stats, :raster_delivery_records)).map do |record|
      next unless hash_value(record, :delivery_scope).to_s == 'page_raster'
      next unless normalize_mode(hash_value(record, :requested_mode)) == expected_mode
      unless hash_value(record, :delivery_basis).to_s ==
               'verified_zero_canonical_text' &&
             hash_value(record, :semantic_text_evaluated) == true &&
             hash_value(record, :no_semantic_text) == true
        raise EvidenceError,
              'page raster fallback lacks verified zero-canonical-text basis'
      end
      claims = canonical_claims!(
        hash_value(record, :resulting_entity_ids), 'page raster fallback', false
      )
      unless claims.length == 1
        raise EvidenceError,
              'page raster fallback must own exactly one image'
      end
      [exact_positive_integer!(
        hash_value(record, :page), 'page raster fallback page'
      ), claims[0]]
    end.compact
    unless fallback_signatures.sort == raster_signatures.sort
      raise EvidenceError,
            'page raster deliveries do not match affirmative fallback proofs'
    end
    true
  end
  private_class_method :verify_page_representation_fallbacks!

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

    if mode == :raster && source_ids.empty?
      delivered_pages = Array(hash_value(stats, :raster_delivery_records)).map do |row|
        unless hash_value(row, :delivery_scope).to_s == 'page_raster' &&
               source_span_ids(row, :span_id => false).empty?
          raise EvidenceError,
                'source-free Raster delivery must be one page image per page'
        end
        exact_positive_integer!(
          hash_value(row, :page), 'raster delivery page'
        )
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
    if values.uniq.length != values.length
      raise EvidenceError, 'source span identities are duplicated within a record'
    end
    values
  end
  private_class_method :source_span_ids

  def self.verify_empty_source_proof!(stats, pages)
    inspections = Array(hash_value(stats, :empty_page_source_inspections))
    immutable_sha = source_sha256_value(
      stats, :source_input_sha256, :immutable_pdf_sha256
    )
    rendered_sha = source_sha256_value(
      stats, :normalized_input_sha256, :normalized_pdf_sha256
    )
    unless immutable_sha =~ /\A[0-9a-f]{64}\z/ &&
           rendered_sha =~ /\A[0-9a-f]{64}\z/
      raise EvidenceError, 'empty-source proof lacks exact source PDF SHA256 bindings'
    end
    proven_pages = inspections.map do |row|
      page = exact_positive_integer!(
        hash_value(row, :page), 'empty-source inspection page'
      )
      source_page = exact_positive_integer!(
        hash_value(row, :source_page_number),
        'empty-source inspection source_page_number'
      )
      canonical_count = hash_value(row, :canonical_text_item_count)
      unless source_page == page && canonical_count.is_a?(Integer) &&
             canonical_count == 0 &&
             hash_value(row, :immutable_pdf_sha256).to_s.downcase == immutable_sha &&
             hash_value(row, :rendered_pdf_sha256).to_s.downcase == rendered_sha &&
             hash_value(row, :semantic_text_extraction_complete) == true &&
             hash_value(row, :decoded_stream_text_operators) == false &&
             hash_value(row, :decoded_form_stream_text_operators) == false
        raise EvidenceError,
              'empty-source proof is not bound to exact PDF/page/zero canonical items'
      end
      page
    end
    if proven_pages.uniq.length != proven_pages.length
      raise EvidenceError, 'empty-source inspection pages are duplicated'
    end
    proven_pages = proven_pages.sort
    unless !proven_pages.empty? && (pages.empty? || proven_pages == pages)
      raise EvidenceError,
            'empty text ledger lacks decoded-stream no-text proof'
    end
  end
  private_class_method :verify_empty_source_proof!

  def self.source_sha256_value(stats, *keys)
    values = []
    Array(keys).each do |key|
      next unless hash_key?(stats, key)
      value = hash_value(stats, key).to_s.downcase
      next if value.empty?
      unless value =~ /\A[0-9a-f]{64}\z/
        raise EvidenceError, "source SHA256 alias #{key} is invalid"
      end
      values << value
    end
    if values.uniq.length > 1
      raise EvidenceError, 'source SHA256 aliases conflict'
    end
    values.first.to_s
  end
  private_class_method :source_sha256_value

  def self.normalized_pages(selected_pages, stats)
    if selected_pages == :all || selected_pages.to_s == 'all'
      count = exact_positive_integer!(
        hash_value(stats, :pages), 'pipeline page count'
      )
      return (1..count).to_a
    end
    values = Array(selected_pages).map do |value|
      exact_positive_integer!(value, 'selected page')
    end
    if values.uniq.length != values.length
      raise EvidenceError, 'selected page identities are duplicated'
    end
    values.sort
  end
  private_class_method :normalized_pages

  def self.exact_positive_integer!(value, label)
    unless value.is_a?(Integer) && value > 0
      raise EvidenceError, "#{label} must be a positive Integer"
    end
    value
  end
  private_class_method :exact_positive_integer!

  def self.positive_finite_number?(value)
    value.is_a?(Numeric) && value.to_f.finite? && value.to_f > 0.0
  rescue StandardError
    false
  end
  private_class_method :positive_finite_number?

  def self.normalize_mode(value)
    text = value.to_s.strip.downcase
    return :text3d if ['text3d', '3d_text', '3d text'].include?(text)
    return text.to_sym if %w[text labels glyphs geometry raster].include?(text)
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
    text = key.to_s
    return hash[text] if hash.key?(text)
    alternate = hash.keys.find { |candidate| candidate.to_s == text }
    alternate.nil? ? nil : hash[alternate]
  end
  private_class_method :hash_value
end
