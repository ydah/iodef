# frozen_string_literal: true

module Iodef
  class Validator
    attr_reader :limits

    def initialize(**limits)
      @limits = Iodef.limits(limits)
    end

    def validate(value, type: "Document")
      @violations = []
      @ids = {}
      @references = []
      data = Iodef.copy(value, limits)
      check_object(data, type, "")
      if type == "Document"
        @references.each do |id, path|
          add(path, "reference", "reference has no matching identifier") unless @ids.key?(id)
        end
      end
      @violations.freeze
    rescue LimitError
      raise
    rescue ValidationError => e
      [Violation.new(pointer: e.pointer, rule: "json", message: "value is not a finite UTF-8 JSON tree")].freeze
    end

    private

    def add(path, rule, message)
      return if @violations.size >= limits[:max_violations]

      @violations << Violation.new(pointer: path.freeze, rule: rule.freeze, message: message.freeze)
    end

    def check_object(value, type, path)
      return add(path, type, "expected an object") unless value.is_a?(Hash)

      definition = SCHEMA.fetch(type)
      definition.fetch("fields").each do |name, descriptor|
        field_path = Iodef.pointer(path, name)
        unless value.key?(name)
          add(field_path, "required", "required property is absent") if descriptor.end_with?("!")
          next
        end
        check_field(value[name], descriptor.delete_suffix("!"), field_path)
      end
      check_groups(value, definition, path)
      check_extensions(value, definition, path)
      check_semantics(value, type, path)
    end

    def check_field(value, type, path)
      if type.end_with?("[]")
        return add(path, type, "expected a nonempty array") unless value.is_a?(Array) && !value.empty?

        value.each_with_index { |item, index| check_field(item, type.delete_suffix("[]"), Iodef.pointer(path, index)) }
      elsif type == "mlstring"
        unless value.is_a?(String)
          if value.is_a?(Hash)
            check_object(value, "MLString",
                         path)
          else
            add(path, type, "expected a string or multilingual string object")
          end
        end
      elsif SCHEMA.key?(type)
        check_object(value, type, path)
      else
        add(path, type, "invalid #{type} value") unless Types.valid?(type, value)
        if type == "binary" && value.is_a?(String) && (value.bytesize / 4 * 3) - value.count("=") > limits[:max_binary_size]
          raise LimitError.new("binary data exceeds max_binary_size", pointer: path)
        end
      end
    end

    def check_groups(value, definition, path)
      { "at_least_one" => (1..), "exactly_one" => (1..1), "at_most_one" => (0..1) }.each do |rule, count|
        fields = definition[rule]
        next unless fields

        add(path, rule, "invalid combination of #{fields.join(", ")}") unless count.cover?(fields.count { |field| value.key?(field) })
      end
    end

    def check_extensions(value, definition, path)
      definition.fetch("fields").each_key do |name|
        next unless name.start_with?("ext-")

        original = name.delete_prefix("ext-")
        # SpecID uses "private" for its extension selector, unlike ordinary enumerations.
        marker = original == "SpecID" ? "private" : "ext-value"
        if value[original] == marker
          unless value[name].is_a?(String) && !value[name].empty?
            add(Iodef.pointer(path, name), "extension",
                "extension selector requires its companion property")
          end
        elsif value.key?(name)
          add(Iodef.pointer(path, name), "extension", "extension property requires the extension selector")
        end
      end
    end

    def check_semantics(value, type, path)
      register_identifiers(value, type, path)
      case type
      when "Document"
        require_field(value, "private-enum-name", path) if value.key?("private-enum-id")
      when "SoftwareReference"
        require_field(value, "dtype", path) if value["spec-name"] == "custom"
        check_typed_content(value, path)
      when "Extension" then check_typed_content(value, path)
      when "Confidence"
        if value["rating"] == "numeric"
          require_field(value, "value", path)
        elsif value.key?("value")
          add(Iodef.pointer(path, "value"), "confidence", "value is only allowed for a numeric rating")
        end
      when "HistoryItem", "Expectation"
        require_field(value, "DefinedCOA", path) if value["action"] == "defined-coa"
      when "NameServers" then check_name_server_addresses(value, path)
      when "Service" then check_service(value, path)
      when "EmailData" then check_headers(value, "EmailHeaderField", path, string: true)
      when "HashData" then check_hash_data(value, path)
      when "BulkObservable"
        if value["type"] == "file-hash" && !value["BulkObservableFormat"].is_a?(Hash)
          require_field(value, "BulkObservableFormat", path)
        elsif value["type"] == "file-hash" && !value["BulkObservableFormat"].key?("Hash")
          add("#{path}/BulkObservableFormat/Hash", "required", "file hashes require a hash description")
        end
      when "IndicatorExpression"
        operands = %w[IndicatorExpression Observable uid-ref IndicatorReference].sum { |key| value[key].is_a?(Array) ? value[key].size : 0 }
        add(path, "operator", "negation requires exactly one operand") if value["operator"] == "not" && operands != 1
      end
    end

    def register_identifiers(value, type, path)
      fields = SCHEMA.fetch(type).fetch("fields").key?("observable-id") ? ["observable-id"] : []
      fields << "id" if type == "IndicatorID"
      fields.each do |field|
        next unless value[field].is_a?(String)

        location = Iodef.pointer(path, field)
        add(location, "identifier", "identifier is already defined") if @ids.key?(value[field]) && field == "observable-id"
        @ids[value[field]] = location
      end
      refs = value["uid-ref"] if SCHEMA.fetch(type).fetch("fields").key?("uid-ref")
      (refs.is_a?(Array) ? refs : [refs]).each_with_index do |id, index|
        @references << [id, refs.is_a?(Array) ? Iodef.pointer(Iodef.pointer(path, "uid-ref"), index) : Iodef.pointer(path, "uid-ref")] if id.is_a?(String)
      end
    end

    def require_field(value, name, path)
      add(Iodef.pointer(path, name), "required", "required property is absent") unless value.key?(name)
    end

    def check_name_server_addresses(value, path)
      return unless value["Address"].is_a?(Array)

      value["Address"].each_with_index do |address, index|
        next unless address.is_a?(Hash)
        next if %w[ipv4-addr ipv6-addr].include?(address["category"])

        add("#{path}/Address/#{index}/category", "address", "name servers require an IP address")
      end
    end

    def check_service(value, path)
      require_field(value, "ip-protocol", path) if %w[Port Portlist ProtoCode ProtoType ProtoField].any? { |key| value.key?(key) }
      { "Port" => 65_535, "ip-protocol" => 255, "ProtoCode" => 255, "ProtoType" => 255 }.each do |field, maximum|
        item = value[field]
        add(Iodef.pointer(path, field), "range", "protocol number is outside its wire range") if item.is_a?(Integer) && !item.between?(0, maximum)
      end
      check_headers(value, "ApplicationHeaderField", path)
    end

    def check_headers(value, field, path, string: false)
      return unless value[field].is_a?(Array)

      value[field].each_with_index do |header, index|
        next unless header.is_a?(Hash)

        header_path = "#{path}/#{field}/#{index}"
        require_field(header, "name", header_path)
        add("#{header_path}/dtype", "header", "email header data must use the string data type") if string && header["dtype"] != "string"
      end
    end

    def check_hash_data(value, path)
      require_field(value, "HashTargetID", path) if %w[file-pe-section file-pe-resource file-pdf-object].include?(value["scope"])
      return unless value["scope"] == "file-pe-iat"

      hashes = [*value["Hash"], *value["FuzzyHash"]]
      return if hashes.any? { |item| item.is_a?(Hash) && item.key?("Application") }

      add(path, "hash", "import table hashing requires the tool in Application")
    end

    def check_typed_content(value, path)
      content = value["value"]
      return unless content.is_a?(String)

      valid = case value["dtype"]
              when "byte", "file" then Types.binary?(content)
              when "bytes", "frame", "packet", "ipv4-packet", "ipv6-packet" then content.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
              when "boolean" then %w[true false 0 1].include?(content)
              when "integer" then content.match?(/\A[+-]?\d+\z/)
              when "real" then content.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)
              when "date-time", "ntpstamp", "ntp-stamp" then Types.datetime?(content)
              when "portlist" then Types.portlist?(content)
              when "url" then Types.uri?(content)
              when "character" then content.length == 1
              when "json" then json_content?(content)
              else true
              end
      add(Iodef.pointer(path, "value"), "dtype", "content does not match the declared data type") unless valid
      binary_size = if %w[byte file].include?(value["dtype"])
                      (content.bytesize / 4 * 3) - content.count("=")
                    elsif %w[bytes frame packet ipv4-packet ipv6-packet].include?(value["dtype"])
                      content.bytesize / 2
                    end
      raise LimitError.new("binary data exceeds max_binary_size", pointer: "#{path}/value") if binary_size && binary_size > limits[:max_binary_size]

      return unless value["dtype"] == "byte" && valid && content.unpack1("m0").bytesize != 1

      add("#{path}/value", "dtype", "byte content must encode exactly one octet")
    end

    def json_content?(content)
      JSON.parse(content, allow_duplicate_key: false, max_nesting: limits[:max_depth])
      true
    rescue JSON::ParserError
      false
    end
  end
end
