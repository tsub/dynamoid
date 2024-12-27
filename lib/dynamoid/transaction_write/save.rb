# frozen_string_literal: true

require_relative 'base'

module Dynamoid
  class TransactionWrite
    class Save < Base
      def initialize(model, **options)
        @model = model
        @model_class = model.class
        @options = options

        @aborted = false
        @was_new_record = model.new_record?
        @valid = nil
      end

      def on_registration
        validate_model!

        if @options[:validate] != false && !(@valid = @model.valid?)
          if @options[:raise_error]
            raise Dynamoid::Errors::DocumentNotValid, @model
          else
            @aborted = true
            return
          end
        end

        @aborted = true
        callback_name = @was_new_record ? :create : :update

        @model.run_callbacks(:save) do
          @model.run_callbacks(callback_name) do
            @model.run_callbacks(:validate) do
              @aborted = false
              true
            end
          end
        end

        if @aborted && @options[:raise_error]
          raise Dynamoid::Errors::RecordNotSaved, @model
        end

        if @was_new_record && @model.hash_key.nil?
          @model.hash_key = SecureRandom.uuid
        end
      end

      def on_commit
        return if @aborted

        @model.changes_applied

        if @was_new_record
          @model.new_record = false
        end

        @model.run_callbacks(:commit)
      end

      def on_rollback
        @model.run_callbacks(:rollback)
      end

      def aborted?
        @aborted
      end

      def skipped?
        @model.persisted? && !@model.changed?
      end

      def observable_by_user_result
        !@aborted
      end

      def action_request
        if @was_new_record
          action_request_to_create
        else
          action_request_to_update
        end
      end

      private

      def validate_model!
        raise Dynamoid::Errors::MissingHashKey if !@was_new_record && @model.hash_key.nil?
        raise Dynamoid::Errors::MissingRangeKey if @model_class.range_key? && @model.range_value.nil?
      end

      def action_request_to_create
        touch_model_timestamps(skip_created_at: false)
        # model always exists
        item = Dynamoid::Dumping.dump_attributes(@model.attributes, @model_class.attributes)

        condition = "attribute_not_exists(#{@model_class.hash_key})"
        condition += " and attribute_not_exists(#{@model_class.range_key})" if @model_class.range_key? # needed?
        result = {
          put: {
            item: sanitize_item(item),
            table_name: @model_class.table_name,
          }
        }
        result[:put][:condition_expression] = condition

        result
      end

      def action_request_to_update
        # model.hash_key = SecureRandom.uuid if model.hash_key.blank?
        touch_model_timestamps(skip_created_at: true)
        changes = @model.changes.map { |k, v| [k.to_sym, v[1]] }.to_h # hash of dirty attributes

        changes.delete(@model_class.hash_key) # can't update id!
        changes.delete(@model_class.range_key) if @model_class.range_key?
        item = Dynamoid::Dumping.dump_attributes(changes, @model_class.attributes)

        # set 'key' that is used to look up record for updating
        key = { @model_class.hash_key => @model.hash_key }
        key[@model_class.range_key] = @model.range_value if @model_class.range_key?

        # e.g. "SET #updated_at = :updated_at ADD record_count :i"
        item_keys = item.keys
        update_expression = "SET #{item_keys.each_with_index.map { |_k, i| "#_n#{i} = :_s#{i}" }.join(', ')}"

        # e.g. {":updated_at" => 1645453.234, ":i" => 1}
        expression_attribute_values = item_keys.each_with_index.map { |k, i| [":_s#{i}", item[k]] }.to_h
        expression_attribute_names = {}

        # only alias names for fields in models, other values such as for ADD do not have them
        # e.g. {"#updated_at" => "updated_at"}
        # attribute_keys_in_model = item_keys.intersection(model_class.attributes.keys)
        # expression_attribute_names = attribute_keys_in_model.map{|k| ["##{k}","#{k}"]}.to_h
        expression_attribute_names.merge!(item_keys.each_with_index.map { |k, i| ["#_n#{i}", k.to_s] }.to_h)

        result = {
          update: {
            key: key,
            table_name: @model_class.table_name,
            update_expression: update_expression,
            expression_attribute_values: expression_attribute_values
          }
        }
        result[:update][:expression_attribute_names] = expression_attribute_names if expression_attribute_names.present?

        result
      end

      def touch_model_timestamps(skip_created_at:)
        return unless @model_class.timestamps_enabled?

        timestamp = DateTime.now.in_time_zone(Time.zone)
        @model.updated_at = timestamp unless @options[:touch] == false && !@was_new_record
        @model.created_at ||= timestamp unless skip_created_at
      end

      # copied from the protected method in AwsSdkV3
      def sanitize_item(attributes)
        config_value = Dynamoid.config.store_attribute_with_nil_value
        store_attribute_with_nil_value = config_value.nil? ? false : !!config_value

        attributes.reject do |_, v|
          ((v.is_a?(Set) || v.is_a?(String)) && v.empty?) ||
            (!store_attribute_with_nil_value && v.nil?)
        end.transform_values do |v|
          v.is_a?(Hash) ? v.stringify_keys : v
        end
      end
    end
  end
end
