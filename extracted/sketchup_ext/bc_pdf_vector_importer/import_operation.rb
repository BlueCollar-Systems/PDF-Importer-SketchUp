# bc_pdf_vector_importer/import_operation.rb
# Single owner for one SketchUp model import transaction.

require File.join(File.dirname(__FILE__), 'representation_fidelity')

module BlueCollarSystems
  module PDFVectorImporter
    class ImportOperation
      attr_reader :abort_error, :readiness_evidence, :state

      def initialize(model, name)
        @model = model
        @name = name.to_s
        @state = :new
        @readiness_evidence = nil
        @abort_error = nil
      end

      def start!
        raise_contract('import operation has already been started') unless
          @state == :new
        begin
          opened = @model && @model.start_operation(@name, true)
          unless opened == true
            @state = :failed
            raise_contract('SketchUp refused to start the import operation')
          end
          @state = :open
          true
        rescue RepresentationFidelity::ContractError
          raise
        rescue StandardError => e
          @state = :failed
          raise_contract("SketchUp import operation start failed: #{e.message}")
        end
      end

      def mark_ready!(evidence)
        raise_contract('import operation is not open') unless open?
        valid = evidence.is_a?(Hash) &&
          evidence[:diagnostics] == true && evidence[:persistence] == true
        raise_contract('import operation readiness evidence is incomplete') unless valid
        @readiness_evidence = {
          :diagnostics => true,
          :persistence => true
        }.freeze
        true
      end

      def commit!
        return false if committed?
        raise_contract('import operation is not open') unless open?
        raise_contract('import operation is not ready to commit') unless
          @readiness_evidence.is_a?(Hash)
        begin
          committed = @model.commit_operation
          raise 'SketchUp refused to commit the import operation' unless
            committed == true
          @state = :committed
          true
        rescue StandardError => e
          abort!
          detail = "SketchUp import operation commit failed: #{e.message}"
          if @abort_error
            detail += "; abort also failed: #{@abort_error.message}"
          end
          raise_contract(detail)
        end
      end

      def abort!
        return false unless open?
        # Mark first so a host exception cannot make any caller retry the same
        # abort and accidentally affect an unrelated later operation.
        @state = :aborted
        begin
          aborted = @model.abort_operation
          return aborted == true
        rescue StandardError => e
          @abort_error = e
          if defined?(Logger)
            Logger.warn('ImportOperation', "abort_operation failed: #{e.message}")
          end
          false
        end
      end

      def open?
        @state == :open
      end

      def committed?
        @state == :committed
      end

      def aborted?
        @state == :aborted
      end

      private

      def raise_contract(message)
        raise RepresentationFidelity::ContractError, message.to_s
      end
    end
  end
end
