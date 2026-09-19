# Bounded original-source renderer for round annotation microstrokes.
require 'digest'
require_relative 'annotation_composite_source'
require_relative 'command_runner'
require_relative 'png_cropper'
require_relative 'safe_temp'

module BlueCollarSystems
  module PDFVectorImporter
    module AnnotationCompositeProvider
      MICROLINE_LIMIT_PT = 0.0005 * 72.0

      def self.eligible_microline?(record)
        a, b = record.values_at(:start_pdf,:end_pdf)
        length = Math.sqrt((a[0]-b[0])**2 + (a[1]-b[1])**2)
        length > 0 && length < MICROLINE_LIMIT_PT
      end

      class Page
        attr_reader :geometry_records, :composite_records, :report, :directory

        def initialize(parser, page_number, source_sha256, executable, runner = CommandRunner)
          @parser, @page, @source_sha, @executable, @runner = parser, page_number, source_sha256, executable, runner
          @source_path = parser.instance_variable_get(:@filepath)
          @directory = nil
          @geometry_records, @composite_records = [], []
          @report = { :schema=>'bcs.original_annotation_delivery/1', :page=>@page,
            :source_pdf_sha256=>@source_sha, :scope=>'original_authored_round_annotation_microline',
            :microline_limit_pdf_points=>MICROLINE_LIMIT_PT, :composite_status=>'NOT_NEEDED' }
        end

        def prepare!
          verify_original_file!
          begin
            inventory = SourceRoundAnnotationInk.inventory(@parser,@page,@source_sha)
          rescue SourceRoundAnnotationInk::Unproven => error
            verify_original_file!
            @report[:eligible_geometry_count] = 0
            @report[:composite_status] = 'ORIGINAL_ANNOTATION_SCOPE_UNPROVEN_EXISTING_GEOMETRY_RETAINED'
            @report[:composite_reason] = error.message
            return self
          end
          @geometry_records = inventory[:records].select { |record| AnnotationCompositeProvider.eligible_microline?(record) }
          @report[:source_unsupported] = inventory[:unsupported]
          @report[:eligible_geometry_count] = @geometry_records.length
          return self if @geometry_records.empty?
          page = @parser.page_data(@page)
          page_dict = SourceRoundAnnotationInk.dictionary(@parser,@parser.pages.fetch(@page-1))
          rotation = SourceRoundAnnotationInk.number(@parser.send(:find_inherited,page_dict,'/Rotate') || 0)
          begin
            plans = AnnotationCompositeSource.plan_page(@geometry_records,page[:media_box],rotation)
            other_annotations = AnnotationCompositeSource.other_annotations_disjoint!(@parser,@page,@geometry_records,plans)
            font_scope = AnnotationCompositeSource.font_scope!(@parser,@page)
            @directory = SafeTemp.mktmpdir('bcs-annotation-source-')
            background = File.join(@directory,'background.pdf')
            copy = AnnotationCompositeSource.write_background_copy!(@parser,@source_sha,@page,background)
            svg_path = File.join(@directory,'background.svg')
            command = [@executable.to_s,'-svg','-f',@page.to_s,'-l',@page.to_s,background,svg_path]
            run_verified!(command,svg_path,background,copy[:copy_sha256])
            svg = File.binread(svg_path)
            scene = AnnotationCompositeSource::BackgroundGlyphInventory.new(svg)
            scene.verify_page_space!(page[:media_box])
            absence = scene.prove_absence!(plans)
            @report[:background_proof] = copy.merge(absence).merge(:other_annotations_disjoint=>other_annotations,
              :font_scope=>font_scope,
              :background_svg_command=>command)
          rescue AnnotationCompositeSource::Unproven, SourceImagePaintOrder::Unproven => error
            verify_original_file!
            @report[:composite_status] = 'SOURCE_UNSUPPORTED_GEOMETRY_RETAINED'
            @report[:composite_reason] = error.message
            return self
          end
          @geometry_records.zip(plans).each_with_index do |(record,plan),index|
            prefix = File.join(@directory,'original-crop-' + index.to_s)
            output = prefix + '.png'
            command = AnnotationCompositeSource.crop_arguments(@executable,@source_path,@page,plan,prefix)
            run_verified!(command,output,@source_path,@source_sha)
            pixels = PngCropper.inspect_pixels!(output,false)
            unless pixels[:pixel_width] == plan[:pixel_width] && pixels[:pixel_height] == plan[:pixel_height] &&
                   pixels[:visible_pixel_present] == true && pixels[:transparent_pixel_present] == false
              raise RepresentationFidelity::ContractError, 'annotation crop does not match the opaque original device lattice'
            end
            @composite_records << { :source=>record, :crop=>plan, :png_path=>output,
              :pixels=>pixels, :renderer=>'original_pdftocairo_600dpi_integer_crop',
              :renderer_sha256=>Digest::SHA256.file(@executable).hexdigest,
              :command=>command, :background_proof=>@report[:background_proof] }
          end
          @report[:composite_status] = 'ORIGINAL_PIXELS_READY_NATIVE_UNVERIFIED'
          @report[:composite_count] = @composite_records.length
          @report[:rendered_pixels] = plans.inject(0) { |sum,plan| sum+plan[:pixel_width]*plan[:pixel_height] }
          self
        end

        def run_verified!(command, output, input, expected_sha)
          diagnostic = { :phase=>'before_renderer', :command=>command.dup,
            :input_sha256=>expected_sha, :output_path=>output }
          (@report[:renderer_attempts] ||= []) << diagnostic
          verify_original_file!
          unless File.file?(@executable.to_s) && File.file?(input) && Digest::SHA256.file(input).hexdigest == expected_sha && !File.exist?(output)
            raise RepresentationFidelity::ContractError, 'annotation renderer input/helper/output identity is invalid'
          end
          helper_sha = Digest::SHA256.file(@executable).hexdigest
          diagnostic[:renderer_sha256] = helper_sha
          diagnostic[:phase] = 'renderer'
          result = @runner.run(command,:timeout_s=>90,:context=>'OriginalAnnotationComposite')
          if result.is_a?(Hash)
            [:ok,:exitstatus,:timed_out,:error,:stdout,:stderr].each do |key|
              value = result[key]
              diagnostic[key] = value.is_a?(String) ? value[0,8192] : value
            end
          else
            diagnostic[:result_type] = result.class.to_s
          end
          diagnostic[:phase] = 'after_renderer_identity'
          verify_original_file!
          diagnostic[:input_unchanged] = File.file?(input) && Digest::SHA256.file(input).hexdigest == expected_sha
          diagnostic[:renderer_unchanged] = File.file?(@executable) && Digest::SHA256.file(@executable).hexdigest == helper_sha
          diagnostic[:output_exists] = File.file?(output)
          diagnostic[:output_bytes] = File.file?(output) ? File.size(output) : 0
          reasons = []
          reasons << 'input identity changed' unless diagnostic[:input_unchanged]
          reasons << 'renderer identity changed' unless diagnostic[:renderer_unchanged]
          if result.is_a?(Hash)
            reasons << 'exit=' + result[:exitstatus].inspect unless result[:ok] == true && result[:exitstatus] == 0
            reasons << 'timed out' if result[:timed_out] == true
            reasons << 'launch error: ' + result[:error].to_s[0,512] unless result[:error].to_s.empty?
            unused_symbol = result[:ok] == true && result[:exitstatus] == 0 &&
              result[:timed_out] != true && result[:error].to_s.empty? &&
              result[:stdout].to_s.strip.empty? && !result[:stderr].to_s.strip.empty? &&
              qualify_unused_symbol_warning!(result[:stderr],input,expected_sha)
            diagnostic[:nonaffecting_warning_proof] = @unused_symbol_proof if unused_symbol
            [:stderr,:stdout].each do |key|
              detail = result[key].to_s.strip
              unless detail.empty? || (key == :stderr && unused_symbol)
                reasons << key.to_s + ': ' + detail.lines.first.to_s.strip[0,512]
              end
            end
          else
            reasons << 'invalid renderer result ' + result.class.to_s
          end
          reasons << 'missing or empty output: ' + output.to_s unless diagnostic[:output_bytes] > 0
          unless reasons.empty?
            diagnostic[:phase] = 'output_verification'
            raise RepresentationFidelity::ContractError, 'original annotation renderer failed: ' + reasons.join('; ')
          end
          diagnostic[:phase] = 'verified'
          result
        rescue StandardError => error
          if diagnostic
            diagnostic[:failure] = error.class.to_s + ': ' + error.message
            @report[:composite_status] = 'RENDERER_FAILED'
            @report[:composite_reason] = diagnostic[:phase] + ': ' + diagnostic[:failure]
          end
          raise
        end

        # The bundled Windows renderer may initialize an unused Symbol font.
        # This exact diagnostic alone is harmless only when the same original
        # PDF's complete, successful pdffonts inventory has no Symbol row.
        # No font is substituted and no other renderer diagnostic is ignored.
        def qualify_unused_symbol_warning!(stderr,input,expected_sha)
          return false unless SvgTextRenderer.symbol_startup_diagnostics_only?(stderr) &&
            File.expand_path(input) == File.expand_path(@source_path) && expected_sha == @source_sha
          suffix = File.extname(@executable.to_s).downcase == '.exe' ? '.exe' : ''
          helper = File.join(File.dirname(@executable),'pdffonts' + suffix)
          return false unless File.file?(helper)
          helper_sha = Digest::SHA256.file(helper).hexdigest
          if @unused_symbol_proof
            return @unused_symbol_proof[:source_pdf_sha256] == expected_sha &&
              @unused_symbol_proof[:helper_sha256] == helper_sha
          end
          verify_original_file!
          command = [helper,'--',@source_path]
          run = @runner.run(command,:timeout_s=>30,:context=>'OriginalAnnotationFontInventory')
          verify_original_file!
          evidence = { :command=>command, :source_pdf_sha256=>expected_sha,
            :helper_sha256=>helper_sha, :helper_unchanged=>File.file?(helper) && Digest::SHA256.file(helper).hexdigest == helper_sha }
          @report[:font_inventory_attempt] = evidence
          return false unless run.is_a?(Hash)
          [:ok,:exitstatus,:timed_out,:error,:stdout,:stderr].each do |key|
            value = run[key]
            evidence[key] = value.is_a?(String) ? value[0,65_536] : value
          end
          return false unless evidence[:helper_unchanged] && run[:ok] == true && run[:exitstatus] == 0 &&
            run[:timed_out] != true && run[:error].to_s.empty? && run[:stdout].to_s.bytesize <= 65_536 &&
            SvgTextRenderer.symbol_startup_diagnostics_only?(run[:stderr]) &&
            SvgTextRenderer.pdffonts_inventory_complete?(run[:stdout])
          rows = run[:stdout].lines.map(&:strip).reject(&:empty?)[2..-1]
          return false if rows.any? { |row| row =~ /symbol/i }
          @unused_symbol_proof = evidence.merge(:schema=>'bcs.unused_symbol_startup_warning/1',
            :policy=>'exact_symbol_warning_complete_original_font_inventory_no_symbol',
            :font_row_count=>rows.length, :symbol_font_absent=>true)
          @report[:nonaffecting_renderer_warning] = @unused_symbol_proof
          true
        end

        def verify_original_file!
          AnnotationCompositeSource.assert_original!(@parser,@source_sha)
        rescue AnnotationCompositeSource::Unproven => error
          raise RepresentationFidelity::ContractError,error.message
        end

        def cleanup
          FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
          @directory = nil
        end
      end
    end
  end
end
