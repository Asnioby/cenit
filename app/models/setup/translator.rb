module Setup
  class Translator
    include Mongoid::Document
    include Mongoid::Timestamps
    include AccountScoped
    include Trackable

    BuildInDataType.regist(self).referenced_by(:name)

    field :name, type: String
    field :type, type: Symbol

    belongs_to :source_data_type, class_name: Setup::DataType.name, inverse_of: nil
    belongs_to :target_data_type, class_name: Setup::DataType.name, inverse_of: nil

    field :discard_events, type: Boolean
    field :style, type: String
    field :transformation, type: String

    belongs_to :source_exporter, class_name: Setup::Translator.name, inverse_of: nil
    belongs_to :target_importer, class_name: Setup::Translator.name, inverse_of: nil

    field :discard_chained_records, type: Boolean

    belongs_to :template, class_name: Setup::Template.name, inverse_of: :translators

    validates_presence_of :name, :type, :style
    validates_uniqueness_of :name
    validates_inclusion_of :type, in: ->(t) { t.type_options }
    validates_inclusion_of :style, in: ->(t) { t.style_options }
    before_save :validates_configuration

    def validates_configuration
      if type == :Conversion
        [:source_data_type, :target_data_type].each do |field|
          errors.add(field, "can't be blank") if send(field).blank?
        end
        # if errors.blank?
        #   errors.add(:target_data_type, 'must defers from source') if target_data_type == source_data_type
        # end
        if style == 'chain'
          [:source_exporter, :target_importer].each do |field|
            errors.add(field, "can't be blank") if send(field).blank?
          end
          if errors.blank?
            errors.add(:source_exporter, "can't be applied to #{source_data_type.title}") unless source_exporter.apply_to_source?(source_data_type)
            errors.add(:target_importer, "can't be applied to #{target_data_type.title}") unless target_importer.apply_to_target?(target_data_type)
          end
          self.transformation = "#{source_data_type.title} -> [#{source_exporter.name} : #{target_importer.name}] -> #{target_data_type.title}" if errors.blank?
        end
      end
      errors.blank?
    end

    def type_options
      [:Import, :Export, :Update, :Conversion]
    end

    def type_enum
      type.present? ? [type] : type_options
    end

    STYLES_MAP = {'renit' => Setup::Transformation::RenitTransform,
                  'double_curly_braces' => Setup::Transformation::DoubleCurlyBracesTransform,
                  'xslt' => Setup::Transformation::XsltTransform,
                  'json.rabl' => Setup::Transformation::ActionViewTransform,
                  'xml.rabl' => Setup::Transformation::ActionViewTransform,
                  'xml.builder' => Setup::Transformation::ActionViewTransform,
                  'html.erb' => Setup::Transformation::ActionViewTransform,
                  'chain' => Setup::Transformation::ChainTransform}

    def style_options
      styles = []
      unless type.blank?
        STYLES_MAP.each do |key, value|
          styles << key if value.types.include?(type)
        end
      end
      styles.uniq
    end

    def style_enum
      style.present? ? [style] : style_options
    end

    def ready_to_save?
      type.present? && style.present? && (style != 'chain' || (source_data_type && target_data_type && source_exporter))
    end

    def can_be_restarted?
      type.present?
    end

    def data_type
      (type == :Import || type == :Update) ? target_data_type : source_data_type
    end

    def apply_to_source?(data_type)
      source_data_type.blank? || source_data_type == data_type
    end

    def apply_to_target?(data_type)
      target_data_type.blank? || target_data_type == data_type
    end

    def run(options={})
      context_options = respond_to?(method_name ="context_options_for_#{type.to_s.downcase}") ? send(method_name, options) : {}
      self.class.fields.keys.each { |key| context_options[key.to_sym] = send(key) }
      self.class.relations.keys.each { |key| context_options[key.to_sym] = send(key) }
      context_options[:data_type] = data_type
      context_options.merge!(options) { |key, context_val, options_val| !context_val ? options_val : options_val }

      context_options[:result] = STYLES_MAP[style].run(context_options)

      if respond_to?(method_name ="after_run_#{type.to_s.downcase}")
        send(method_name, context_options)
      end

      context_options[:result]
    end

    def context_options_for_import(options)
      raise Exception.new('Target data type not defined') unless data_type = target_data_type || options[:target_data_type]
      {target_data_type: data_type}
    end

    def context_options_for_export(options)
      raise Exception.new('Source data type not defined') unless data_type = source_data_type || options[:source_data_type]
      model = data_type.model
      offset = options[:offset] || 0
      limit = options[:limit]
      sources = if object_ids = options[:object_ids]
                  model.any_in(id: (limit ? object_ids[offset, limit] : object_ids.from(offset))).to_enum
                else
                  (limit ? model.limit(limit) : model.all).skip(offset).to_enum
                end
      {source_data_type: data_type, sources: sources}
    end

    def context_options_for_update(options)
      {target: options[:object]}
    end

    def context_options_for_conversion(options)
      raise Exception.new("Target data type #{target_data_type.title} is not loaded") unless target_data_type.loaded?
      {source: options[:object], target: style == 'chain' ? nil : target_data_type.model.new}
    end

    def after_run_import(options)
      if targets = options[:targets]
        targets.each do |target|
          target.discard_event_lookup = options[:discard_events]
          raise TransformingObjectException.new(target) unless target.save
        end
        options[:result] = targets
      end
    end

    def after_run_update(options)
      if target = options[:object]
        target.discard_event_lookup = options[:discard_events]
        raise TransformingObjectException.new(object) unless target.save
      end
      options[:result] = target
    end

    def after_run_conversion(options)
      if target = options[:target]
        if options[:save_result].nil? || options[:save_result]
          target.discard_event_lookup = options[:discard_events]
          raise TransformingObjectException.new(target) unless target.save
        end
        options[:result] = target
      end
    end

    class SourceIterator
      include Enumerable

      def initialize(object_ids, model, offset=0, limit=nil)
        @enum = if object_ids
                  (object_ids.is_a?(Enumerator) ? object_ids : object_ids.to_enum).skip(offset)
                else
                  (limit ? model.limit(limit) : model.all).skip(offset).to_enum
                end
        @enum.skip(offset)
        @model = model
      end

      def next
        if @enum
          @current = @enum.next
        else
          @current_index += 1 if @current_index < @object_ids.length
          current
        end
      end

      def current
        if @enum
          @current ||= @enum.next
        else
          (@current_index < @object_ids.length) ? @model.find(@object_ids[@current_index]) : nil
        end
      end

      def count
        if @enum
          @model.count
        else
          @object_ids.length
        end
      end

      def each
        if @enum
          @model.all.each { |record| yield record }
        else
          @object_ids.each { |obj_id| yield @model.find(obj_id) }
        end
      end
    end

    private

    def self.save(record)
      save_references(record) && record.save(validate: false)
    end

    def self.save_references(record)
      record.reflect_on_all_associations(:embeds_one,
                                         :embeds_many,
                                         :has_one,
                                         :has_many,
                                         :has_and_belongs_to_many).each do |relation|
        if values = record.send(relation.name)
          values = [values] unless values.is_a?(Enumerable)
          values.each { |value| return false unless save_references(value) }
          values.each { |value| return false unless value.save(validate: false) } unless relation.embedded?
        end
      end
      return true
    end
  end

  class TransformingObjectException < Exception

    attr_reader :object

    def initialize(object)
      super "Error transforming object #{object}"
      @object = object
    end
  end
end