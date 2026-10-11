# frozen_string_literal: true

module Iodef
  DEFAULT_LIMITS = { max_input_size: 16 * 1024 * 1024, max_depth: 32, max_collection_size: 10_000,
                     max_nodes: 200_000, max_binary_size: 1024 * 1024, max_violations: 1000 }.freeze

  class << self
    def limits(options)
      unknown = options.keys - DEFAULT_LIMITS.keys
      raise ArgumentError, "unknown limits: #{unknown.join(", ")}" unless unknown.empty?

      DEFAULT_LIMITS.merge(options).tap do |result|
        result.each_value { |value| raise ArgumentError, "limits must be positive integers" unless value.is_a?(Integer) && value.positive? }
      end.freeze
    end

    def pointer(parent, key)
      "#{parent}/#{key.to_s.gsub("~", "~0").gsub("/", "~1")}"
    end

    def freeze_tree(value)
      case value
      when Hash then value.each do |key, item|
        freeze_tree(key)
        freeze_tree(item)
      end
      when Array then value.each { |item| freeze_tree(item) }
      end
      value.freeze
    end

    def copy(value, options = DEFAULT_LIMITS, depth: 0, path: "", ancestors: [], budget: [0, 0])
      budget[0] += 1
      raise LimitError.new("value exceeds max_nodes", pointer: path) if budget[0] > options[:max_nodes]

      value = value.to_h if value.is_a?(Model)
      case value
      when Hash, Array
        raise LimitError.new("value exceeds max_depth", pointer: path) if depth >= options[:max_depth]
        raise LimitError.new("collection exceeds max_collection_size", pointer: path) if value.size > options[:max_collection_size]
        raise ValidationError.new("cyclic input", pointer: path) if ancestors.include?(value.object_id)

        nested = { depth: depth + 1, ancestors: ancestors + [value.object_id], budget: budget }
        if value.is_a?(Array)
          value.each_with_index.map { |item, index| copy(item, options, path: pointer(path, index), **nested) }
        else
          value.each_with_object({}) do |(key, item), result|
            unless (key.is_a?(String) || key.is_a?(Symbol)) && Types.string?(key.to_s)
              raise ValidationError.new("object keys must be UTF-8 strings", pointer: path)
            end

            key = key.to_s
            budget[1] += key.bytesize
            raise LimitError.new("value exceeds max_input_size", pointer: path) if budget[1] > options[:max_input_size]

            location = pointer(path, key)
            raise ValidationError.new("duplicate object key", pointer: location) if result.key?(key)

            result[key.dup.force_encoding(Encoding::UTF_8)] = copy(item, options, path: location, **nested)
          end
        end
      when String
        budget[1] += value.bytesize
        raise LimitError.new("value exceeds max_input_size", pointer: path) if budget[1] > options[:max_input_size]
        raise ValidationError.new("invalid UTF-8 string", pointer: path) unless Types.string?(value)

        value.dup.force_encoding(Encoding::UTF_8)
      when Float
        raise ValidationError.new("non-finite number", pointer: path) unless value.finite?

        value
      when Integer, TrueClass, FalseClass, NilClass then value
      else raise ValidationError.new("non-JSON value", pointer: path)
      end
    end

    def generate_json(value, options = nil)
      value = precise_floats(value) if RUBY_ENGINE == "truffleruby"
      JSON.generate(value, options)
    end

    # TruffleRuby's Float#to_s may discard digits needed for a lossless JSON round trip.
    def precise_floats(value)
      case value
      when Hash then value.transform_values { |item| precise_floats(item) }
      when Array then value.map { |item| precise_floats(item) }
      when Float
        number = format("%.17g", value)
        number += ".0" unless number.match?(/[.eE]/)
        JSON::Fragment.new(number)
      else value
      end
    end
    private :precise_floats
  end

  schema = YAML.safe_load_file(File.expand_path("../../data/types.yml", __dir__))
  SCHEMA = freeze_tree(schema.fetch("types").transform_values do |definition|
    fields = definition.fetch("groups", []).each_with_object({}) { |group, result| result.merge!(schema.fetch("groups").fetch(group)) }
    definition.merge("fields" => fields.merge(definition.fetch("fields")))
  end)
  ENUMS = freeze_tree(YAML.safe_load_file(File.expand_path("../../data/enums.yml", __dir__)))
  map = YAML.safe_load_file(File.expand_path("../../data/mapkeys.yml", __dir__))
  MAPKEYS = freeze_tree(map.fetch("names").split.each_with_index.to_h { |name, index| [name, index + map.fetch("first")] })
  KEYNAMES = MAPKEYS.invert.freeze

  module Types
    module_function

    def string?(value)
      value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)
    end

    def datetime?(value)
      return false unless string?(value)

      match = /\A(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?([Zz]|[+-]\d{2}:\d{2})\z/.match(value)
      return false unless match

      year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
      zone = match[7]
      Date.valid_date?(year, month, day, Date::GREGORIAN) && hour < 24 && minute < 60 && second <= 60 &&
        (zone.match?(/\A[zZ]\z/) || (zone[1, 2].to_i < 24 && zone[4, 2].to_i < 60))
    end

    def uri?(value)
      string?(value) && value.ascii_only? && !value.match?(/%(?![0-9a-fA-F]{2})/) && !URI.parse(value).scheme.nil?
    rescue URI::InvalidURIError
      false
    end

    def binary?(value)
      string?(value) && value.match?(%r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}) &&
        [value.unpack1("m0")].pack("m0") == value
    rescue ArgumentError
      false
    end

    def portlist?(value)
      return false unless string?(value) && value.match?(/\A\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*\z/)

      value.split(",").all? do |range|
        ports = range.split("-").map(&:to_i)
        ports.all? { |port| port <= 65_535 } && ports.first <= ports.last
      end
    end

    def valid?(type, value)
      return ENUMS.fetch(type).include?(value) if ENUMS.key?(type)

      case type
      when "string" then string?(value)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric) && (!value.is_a?(Float) || value.finite?)
      when "positive" then valid?("number", value) && value.positive?
      when "id" then string?(value) && value.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\z/)
      when "language" then string?(value) && (value.empty? || value.match?(/\A[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*\z/))
      when "timezone" then string?(value) && value.match?(/\A(?:Z|[+-](?:0\d|1[0-4]):[0-5]\d)\z/)
      when "version" then %w[2.0 2.00].include?(value)
      when "datetime" then datetime?(value)
      when "uri" then uri?(value)
      when "binary" then binary?(value)
      when "portlist" then portlist?(value)
      else false
      end
    end
  end
end
