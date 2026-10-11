# frozen_string_literal: true

module Iodef
  # Mutable typed views share their document; exported hashes are independent copies.
  class Model
    attr_reader :limits, :warnings

    def self.schema_type
      name.split("::").last
    end

    def initialize(data = {}, strict: true, **limits)
      @limits = Iodef.limits(limits)
      @data = Iodef.copy(data, @limits)
      raise ValidationError, "model must be an object" unless @data.is_a?(Hash)

      @warnings = Validator.new(**@limits).validate(@data, type: self.class.schema_type)
      validate! if strict && !@warnings.empty?
    end

    def self.view(data, limits, parent: nil)
      allocate.tap do |model|
        model.instance_variable_set(:@data, data)
        model.instance_variable_set(:@limits, limits)
        model.instance_variable_set(:@parent, parent)
        model.instance_variable_set(:@warnings, [].freeze)
      end
    end

    def [](key)
      @data[key.to_s]
    end

    def []=(key, value)
      @data[key.to_s] = Iodef.copy(value, limits)
    end

    def delete(key)
      @data.delete(key.to_s)
    end

    def to_h
      Iodef.copy(@data, limits)
    end

    def validate!
      @warnings = Validator.new(**limits).validate(@data, type: self.class.schema_type)
      raise ValidationError.new(violations: @warnings) unless @warnings.empty?

      self
    end

    def to_json(options = nil)
      validate!
      json = Iodef.generate_json(@data, options)
      raise LimitError, "output exceeds max_input_size" if json.bytesize > limits[:max_input_size]

      json
    end

    def description
      MultilingualText.new(@data.fetch("Description", []), lang: effective_language)
    end

    def description=(value)
      self["Description"] = value
    end

    def self.accessors
      SCHEMA.fetch(schema_type).fetch("fields").each do |field, descriptor|
        method = field.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-", "_").downcase
        next if method == "description"

        define_method(method) { read_field(field, descriptor.delete_suffix("!")) }
        define_method("#{method}=") { |value| self[field] = value }
      end
    end

    protected

    def effective_language
      @data.fetch("lang") { @parent&.effective_language }
    end

    private

    def read_field(field, descriptor)
      value = @data[field]
      return value unless value

      if descriptor.end_with?("[]") && value.is_a?(Array)
        value.map { |item| wrap(item, descriptor.delete_suffix("[]")) }
      else
        wrap(value, descriptor)
      end
    end

    def wrap(value, type)
      klass = TYPED[type]
      klass && value.is_a?(Hash) ? klass.view(value, limits, parent: self) : value
    end
  end

  class Document < Model
    def self.build(lang: nil, **limits)
      data = { "version" => "2.0", "Incident" => [] }
      data["lang"] = lang if lang
      document = new(data, strict: false, **limits)
      yield document
      document.validate!
    end

    def incidents
      read_field("Incident", "Incident[]") || []
    end

    def add_incident(purpose:, **attributes)
      value = { "purpose" => purpose }.merge(attributes.transform_keys(&:to_s))
      incident = Incident.view(Iodef.copy(value, limits), limits, parent: self)
      yield incident if block_given?
      @data["Incident"] ||= []
      @data["Incident"] << incident.instance_variable_get(:@data)
      incident
    end
  end

  class Incident < Model
    def contacts
      read_field("Contact", "Contact[]") || []
    end

    def assessments
      read_field("Assessment", "Assessment[]") || []
    end

    def indicators
      read_field("Indicator", "Indicator[]") || []
    end

    def add_contact(role:, type:, **attributes)
      value = { "role" => role, "type" => type }.merge(attributes.transform_keys(&:to_s))
      contact = Contact.view(Iodef.copy(value, limits), limits, parent: self)
      yield contact if block_given?
      @data["Contact"] ||= []
      @data["Contact"] << contact.instance_variable_get(:@data)
      contact
    end
  end

  class Contact < Model; end
  class Assessment < Model; end
  class EventData < Model; end
  class Indicator < Model; end

  TYPED = [Document, Incident, Contact, Assessment, EventData, Indicator].to_h { |klass| [klass.schema_type, klass] }.freeze
  TYPED.each_value(&:accessors)

  class MultilingualText
    include Enumerable

    def initialize(values, lang: nil)
      @values = values.is_a?(Array) ? values : [values]
      @lang = lang
    end

    def each(&)
      @values.each(&)
    end

    # Exact matches win; a language prefix and then an unlabelled value are fallbacks.
    def text(language = nil)
      values = @values.map { |value| value.is_a?(String) ? { "value" => value, "lang" => "en" } : value.merge("lang" => value.fetch("lang", @lang)) }
      language = language&.downcase
      selected = values.find { |value| value["lang"]&.downcase == language } if language
      selected ||= values.find { |value| value["lang"].to_s.downcase.split("-").first == language.split("-").first } if language
      fallback = @values.index { |value| value.is_a?(String) || value["lang"].nil? || value["lang"].empty? }
      selected ||= values[fallback] if fallback
      (selected || values.first)&.fetch("value", nil)
    end

    def to_a
      Iodef.copy(@values)
    end
  end
end
