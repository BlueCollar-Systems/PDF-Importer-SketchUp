# bc_pdf_vector_importer/poppler_result_validator.rb
# Attempt-local validation for active Poppler helper boundaries.
# Ruby 2.2 compatible (SketchUp Make 2017).

module BlueCollarSystems
  module PDFVectorImporter
    module PopplerResultValidator
      # This is not a generic CID oracle. It is the exact diagnostic cluster
      # observed when the reviewed Adobe-GB1 fixture lost text while Poppler
      # still returned exit status zero.
      PROVEN_ADOBE_GB1_FIXTURE_DIAGNOSTICS = [
        /Missing language pack for ['"]Adobe-GB1['"] mapping/i,
        /Unknown font tag ['"]china-s['"]/i,
        /No font in show\/space/i
      ].freeze

      def self.validate(run, opts = {})
        evidence = build_evidence(run, opts)
        process_ok = !!(run && run[:ok])
        incomplete_output = !evidence[:semantic_complete] &&
          proven_adobe_gb1_fixture_incomplete_output?(
            evidence[:stdout], evidence[:stderr]
          )
        semantic_completion_deferred = incomplete_output &&
          opts[:defer_semantic_completion] == true
        artifact_ok = artifacts_satisfy_policy?(
          evidence[:artifacts], opts[:artifact_policy]
        )

        reason = nil
        if incomplete_output && !semantic_completion_deferred
          reason = :proven_adobe_gb1_fixture_incomplete_output
        elsif !process_ok
          reason = :process_failed
        elsif !artifact_ok
          reason = :artifact_missing_or_empty
        end

        {
          :ok => reason.nil?,
          :reason => reason,
          :incomplete_output => incomplete_output,
          :semantic_completion_deferred => semantic_completion_deferred,
          :rejection_scope => rejection_scope(opts),
          :evidence => evidence
        }
      end

      # Finalize a phase-one snapshot after the owned SVG has been parsed,
      # placed, and matched to the current source spans. Artifact existence is
      # deliberately not re-read: the renderer owns and deletes its temp file,
      # while the phase-one snapshot already proved it nonempty.
      def self.finalize_deferred(transport_result, semantic_complete)
        unless transport_result.is_a?(Hash) && transport_result[:ok] &&
               transport_result[:semantic_completion_deferred] == true
          return {
            :ok => false,
            :reason => :invalid_deferred_validation,
            :semantic_completion_deferred => false,
            :evidence => {}
          }
        end

        result = transport_result.dup
        evidence = transport_result[:evidence].is_a?(Hash) ?
          transport_result[:evidence].dup : {}
        complete = semantic_complete == true
        evidence[:semantic_complete] = complete
        result[:evidence] = evidence
        result[:semantic_completion_deferred] = false
        result[:incomplete_output] = !complete
        result[:ok] = complete
        result[:reason] = complete ? nil :
          :proven_adobe_gb1_fixture_incomplete_output
        result
      end

      def self.proven_adobe_gb1_fixture_incomplete_output?(stdout, stderr)
        # Never combine fragments across streams or helper attempts.
        [stdout, stderr].any? do |stream|
          text = stream.to_s
          PROVEN_ADOBE_GB1_FIXTURE_DIAGNOSTICS.all? do |pattern|
            text =~ pattern
          end
        end
      rescue StandardError
        false
      end

      def self.proven_cid_incomplete_output?(stdout, stderr)
        proven_adobe_gb1_fixture_incomplete_output?(stdout, stderr)
      end

      def self.log_rejection(result, context = nil)
        return if result && result[:ok]

        evidence = result && result[:evidence] ? result[:evidence] : {}
        label = context || evidence[:context] || 'PopplerResultValidator'
        reason = result ? result[:reason] : :missing_validation_result
        message = "Rejected Poppler output: reason=#{reason.inspect}, " \
                  "scope=#{result && result[:rejection_scope]}; " \
                  "evidence=#{evidence.inspect}"
        Logger.warn(label.to_s, message) if
          defined?(Logger) && Logger.respond_to?(:warn)
      rescue StandardError
        nil
      end

      def self.build_evidence(run, opts)
        run ||= {}
        {
          :context => opts[:context],
          :executable => opts[:executable].to_s,
          :argv => Array(opts[:argv]).map { |arg| arg.to_s },
          :page => opts[:page],
          :attempt => opts[:attempt],
          :representation => opts[:representation],
          :span_id => opts[:span_id],
          :exitstatus => run[:exitstatus],
          :timed_out => !!run[:timed_out],
          :error => run[:error],
          :semantic_complete => opts[:semantic_complete] == true,
          :stdout => run[:stdout].to_s,
          :stderr => run[:stderr].to_s,
          :artifacts => artifact_evidence(opts[:artifacts])
        }
      end
      private_class_method :build_evidence

      def self.artifact_evidence(paths)
        Array(paths).compact.map do |path|
          begin
            value = path.to_s
            exists = File.file?(value)
            bytes = exists ? File.size(value) : nil
            { :path => value, :exists => exists, :bytes => bytes }
          rescue StandardError => e
            {
              :path => value, :exists => false, :bytes => nil,
              :error => e.message
            }
          end
        end
      end
      private_class_method :artifact_evidence

      def self.artifacts_satisfy_policy?(artifacts, policy)
        policy = :none if policy.nil? && artifacts.empty?
        policy = :all_nonempty if policy.nil?
        nonempty = artifacts.map do |artifact|
          artifact[:exists] && artifact[:bytes].to_i > 0
        end

        case policy
        when :none
          true
        when :any_nonempty
          nonempty.any?
        else
          !nonempty.empty? && nonempty.all?
        end
      end
      private_class_method :artifacts_satisfy_policy?

      def self.rejection_scope(opts)
        span_id = opts[:span_id]
        return :span if span_id && !span_id.to_s.empty?
        return :page if opts.key?(:page) && !opts[:page].nil?
        :helper_attempt
      end
      private_class_method :rejection_scope
    end
  end
end
