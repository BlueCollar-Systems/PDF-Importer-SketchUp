# bc_pdf_vector_importer/batch_host_policy.rb
# Fail-closed policy for unattended, real-host acceptance runs.

module BlueCollarSystems
  module PDFVectorImporter
    module BatchHostPolicy
      ENV_KEY = 'BC_PDF_IMPORTER_BATCH_NONINTERACTIVE'.freeze unless
        const_defined?(:ENV_KEY, false)
      LARGE_PDF_BYTES = 100 * 1024 * 1024 unless
        const_defined?(:LARGE_PDF_BYTES, false)

      class NoninteractiveError < StandardError; end

      module_function

      def noninteractive?
        ENV[ENV_KEY].to_s == '1'
      end

      def prompt_allowed?
        !noninteractive?
      end

      def confirm_large_pdf!(file_size_bytes)
        return true unless file_size_bytes.to_i > LARGE_PDF_BYTES
        if noninteractive?
          raise NoninteractiveError,
                'large PDF requires interactive confirmation; batch import stopped'
        end
        block_given? ? yield : false
      end

      def handle_salvage_error!(error)
        if noninteractive?
          raise NoninteractiveError,
                "PDF salvage failed in noninteractive batch mode: #{error.message}"
        end
        yield(error) if block_given?
        false
      end
    end
  end
end
