#!/usr/bin/env ruby
# test/mesh_text_width_fidelity_test.rb
#
# Width-fidelity bbox fitting was removed.  3D text is now generated with the
# nominal source font size and placed at the baseline-left anchor; no scaling
# to the PDF bbox extent is performed.  This guard fails if the old width-fit
# machinery is reintroduced.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
GB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
               'bc_pdf_vector_importer', 'geometry_builder.rb')

class MeshTextWidthFidelityGuardTest < Minitest::Test
  def source
    @source ||= File.read(GB, encoding: 'UTF-8')
  end

  def method_body(name)
    body = source[/^([ 	]*)def #{Regexp.escape(name)}(?=\s|\().*?^end/m]
    refute_nil body, "could not isolate ##{name}"
    body
  end

  def test_bbox_fit_methods_are_absent
    %w[fit_created_text_entities! mesh_text_declared_run_width_inches].each do |forbidden|
      refute_includes source, "def #{forbidden}",
                      "#{forbidden} must not exist (bbox fitting removed)"
    end
  end

  def test_place_mesh_text_does_not_scale_to_bbox
    refute_includes source, 'def fit_created_text_entities!',
                    'bbox-fitting helper must be removed'
    refute_includes source, 'Transformation.scaling(pivot, factor_x, factor_y, 1.0)',
                    'place_mesh_text must not scale generated 3D text'
    refute_includes source, 'mesh_text_declared_run_width_inches',
                    'declared run width from bbox must not be used'
    refute_includes source, 'target_width / generated[:width]',
                    'width must not be bbox-fitted'
    refute_includes source, 'target_height / generated[:height]',
                    'height must not be bbox-fitted'
  end

  def test_no_width_fit_shim_tokens_anywhere
    %w[mesh_text_fit_font_size_pts calibrate_mesh_text
       mesh_text_post_rotation_offset].each do |forbidden|
      refute_includes source, forbidden,
                      "#{forbidden} must not exist in geometry_builder.rb"
    end
  end
end
