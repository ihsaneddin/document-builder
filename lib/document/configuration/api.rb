require 'options_model'
module Document
  module Configuration
    module Api

      mattr_accessor :current_user
      @@current_user = nil

      def set_current_user &block
        @@current_user = Proc.new
      end


      def ability_class_constant
        @@ability_class.constantize
      end

      module Callbacks

        mattr_accessor :callbacks
        @@callbacks = {
          form_got_resource: -> (resource) { resource.owner = current_user if resource.new_record? },
          form_query_scope: -> (query) { query },
          section_got_resource: -> (resource) {  resource.form = form },
          section_query_scope: -> (query) { query.where(form: form).rank(:position) },
          field_got_resource: -> (resource) {  resource.form = form },
          field_query_scope: -> (query) { query.where(form: form).rank(:position) },
          instance_got_resource: -> (resource) { resource },
          instance_query_scope: -> (query) { query },
          query_builder_got_resource: -> (resource) {
            resource.form = form
            resource.context = current_user
          },
          query_builder_query_scope: -> (query) { query.where(form: form) }
        }
        class << self

          def callback_of name, &block
            if @@callbacks[name.to_sym]
              @@callbacks[name.to_sym] = Proc.new
            end
          end

          def perform name, context, *args
            callback = @@callbacks[name.to_sym]
            if callback.is_a?(Proc)
              context.instance_exec(*args, &callback)
            end
          end

        end

      end

      mattr_accessor :callbacks
      @@callbacks = Callbacks

      def setup_callbacks &block
        @@callbacks.module_exec(&block)
      end

      mattr_accessor :ability_class
      @@ability_class = 'Document::Grape::Ability'

      class Permission
        attr_reader :name, :namespace, :priority, :callable, :action, :options

        def initialize(name, _namespace: [], _priority: 0, _callable: true, **_options, &_block)
          @name = name
          @namespace = _namespace
          @priority = _priority
          @callable = _callable
          options = _options
          return unless _callable

          @model_name = options[:model_name]
          @subject = options[:subject]
          @action = options[:action] || name
          @condition_proc = options[:condition_proc]
          @if = options[:if]
          @options = options.except(:model, :model_name, :subject, :action, :condition_proc, :if)
          @block = _block
        end

        def call(context, api, *args)
          return unless callable
          return if @if.present? && !api.instance_exec(*args, &@if) rescue false
          subject = @subject || @model_name.constantize
          if block_attached?
            context.can @action, subject, &@block.curry[*args]
          else
            additional_options = if @condition_proc
              api.instance_exec(*args, &@condition_proc)
            else
              {}
            end
            context.can @action, subject, @options.merge(additional_options)
          end
        rescue NameError
          debugger
          raise "You must provide a valid model name."
        end

        delegate :hash, to: :instance_values

        def ==(other)
          return false unless other.is_a?(Document::Configuration::Api::Permission)

          instance_values == other.instance_values
        end

        def block_attached?
          !!@block
        end

        alias eql? ==
      end

      class ComputedPermissions
        delegate :each, :map, :to_a, :to_ary, to: :@permissions

        def initialize(permissions = [])
          @permissions = [].concat permissions.to_a
          regroup!
        end

        def concat(permissions)
          @permissions.concat permissions
          regroup!

          self
        end

        def call(context, *args)
          @permissions.each do |permission|
            permission.call(context, *args)
          end

          self
        end

        private

          def regroup!
            @permissions.uniq!
            @permissions.sort_by!(&:priority)
          end
      end

      class PermissionSet < OptionsModel::Base
        def permitted_permission_names
          attributes.select { |_, v| v }.keys
        end

        def computed_permissions(include_nesting: true)
          permissions = self.class.registered_permissions.values
          permissions.concat self.class.nested_classes.values.map{|v| v.new.computed_permissions}.flatten! if include_nesting && self.class.nested_classes.any?

          ComputedPermissions.new(permissions)
        end

        class << self

          def use_relative_model_naming?
            true
          end

          def permission_class
            Permission
          end

          def permission_class=(klass)
            raise ArgumentError, "#{klass} should be sub-class of #{Permission}." unless klass && klass < Permission

            @permission_class = klass
          end

          def draw_permissions(constraints = {}, &block)
            raise ArgumentError, "must provide a block" unless block_given?

            Mapper.new(self, constraints).instance_exec(&block)

            self
          end

          def registered_permissions
            @registered_permissions ||= ActiveSupport::HashWithIndifferentAccess.new
          end

          def register_permission(name, default = false, options = {}, &block)
            raise ArgumentError, "`name` can't be blank" if name.blank?

            attribute name, :boolean, default: default
            registered_permissions[name] = permission_class.new name, **options, &block
          end

          PERMITTED_ATTRIBUTE_CLASSES = [Symbol].freeze

          def permitted_attribute_classes
            PERMITTED_ATTRIBUTE_CLASSES
          end
        end
      end

      class Mapper
        def initialize(set, constraints = {})
          @constraints = constraints
          @constraints[:_namespace] ||= []
          @set = set
        end

        def permission(name, default: false, **options, &block)
          @set.register_permission name, default, @constraints.merge(options), &block
          self
        end

        def group(name, constraints = {}, &block)
          raise ArgumentError, "`name` can't be blank" if name.blank?
          raise ArgumentError, "must provide a block" unless block_given?

          constraints[:_namespace] ||= @constraints[:_namespace].dup
          constraints[:_namespace] << name

          sub_permission_set_class =
            if @set.nested_classes.key?(name)
              @set.nested_classes[name]
            else
              klass_name = constraints[:_namespace].map { |n| n.to_s.classify }.join("::")
              klass = PermissionSet.derive klass_name
              @set.embeds_one(name, anonymous_class: klass)

              klass
            end

          sub_permission_set_class.draw_permissions(@constraints.merge(constraints), &block)

          self
        end
      end

      mattr_accessor :permission_set
      @@permission_set = PermissionSet

      def api &block
        module_exec(&block)
      end

      def draw_permissions &block
        permission_set.draw_permissions(&block)
      end

    end
  end
end