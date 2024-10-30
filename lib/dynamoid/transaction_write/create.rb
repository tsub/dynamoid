# frozen_string_literal: true

module Dynamoid
  class TransactionWrite
    class Create
      def initialize(model_class, attributes = {}, **options)
        @model = model_class.new(attributes)
        @save_action = Save.new(@model, **options)
      end

      def on_registration
        @save_action.on_registration
      end

      def on_completing
        @save_action.on_completing
      end

      def aborted?
        @save_action.aborted?
      end

      def observable_by_user_result
        @model
      end

      def action_request
        @save_action.action_request
      end
    end
  end
end
