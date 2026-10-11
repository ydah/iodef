# frozen_string_literal: true

module Iodef
  # A pull reader bounds the tree before allocating descendants or expanding entities.
  class XMLTree
    XML_NS = "http://www.w3.org/XML/1998/namespace"
    XMLNS_NS = "http://www.w3.org/2000/xmlns/"
    Node = Data.define(:name, :uri, :local, :attributes, :namespaces, :parts, :lang)
    Markup = Data.define(:kind, :value)
    ENTITIES = { "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'" }.freeze

    def initialize(limits)
      @limits = limits
    end

    def parse(source)
      raise ParseError, "XML input must be a String" unless source.is_a?(String)
      raise LimitError, "input exceeds max_input_size" if source.bytesize > @limits[:max_input_size]

      source = source.dup.force_encoding(Encoding::UTF_8)
      check_characters(source)
      source.gsub!(/\r\n?/, "\n")
      parser = REXML::Parsers::PullParser.new(source)
      stack = []
      root = nil
      nodes = 0
      loop do
        event = parser.pull
        nodes += 1
        raise LimitError, "XML exceeds max_nodes" if nodes > @limits[:max_nodes]

        case event.event_type
        when :start_element
          raise LimitError, "XML exceeds max_depth" if stack.size >= @limits[:max_depth]
          raise ParseError, "XML must have exactly one root element" if stack.empty? && root

          attributes = event[1]
          raise LimitError, "XML attributes exceed max_collection_size" if attributes.size > @limits[:max_collection_size]
          raise ParseError, "unescaped XML attribute markup" if attributes.values.any? { |value| value.include?("<") }
          nodes += attributes.size
          raise LimitError, "XML exceeds max_nodes" if nodes > @limits[:max_nodes]

          namespaces = stack.empty? ? { "xml" => XML_NS } : stack.last.namespaces
          if attributes.keys.any? { |name| name == "xmlns" || name.start_with?("xmlns:") }
            nodes += namespaces.size
            raise LimitError, "XML namespace contexts exceed max_nodes" if nodes > @limits[:max_nodes]

            namespaces = namespaces.dup
          end
          attributes = attributes.transform_values { |value| decode_text(value.gsub(/[\t\r\n]/, " ")) }
          attributes.each do |name, value|
            next unless name == "xmlns" || name.start_with?("xmlns:")

            prefix = name == "xmlns" ? "" : name.delete_prefix("xmlns:")
            if prefix == "xmlns" || value == XMLNS_NS || (prefix == "xml") != (value == XML_NS) || (!prefix.empty? && value.empty?)
              raise ParseError, "invalid XML namespace declaration"
            end
            namespaces[prefix] = value
          end
          expanded = {}
          attributes.each_key do |name|
            next if name == "xmlns" || name.start_with?("xmlns:")

            pair = expand(name, namespaces, attribute: true)
            raise ParseError, "duplicate expanded XML attribute" if expanded.key?(pair)

            expanded[pair] = true
          end
          uri, local = expand(event[0], namespaces)
          lang = attributes.fetch("xml:lang", stack.last&.lang)
          node = Node.new(event[0], uri, local, attributes, namespaces, [], lang)
          stack.empty? ? root = node : append(stack.last, node)
          stack << node
        when :end_element
          raise ParseError, "unbalanced XML elements" if stack.empty? || stack.last.name != event[0]

          stack.pop
        when :text, :cdata
          raise ParseError, "CDATA outside the root element" if event.event_type == :cdata && stack.empty?
          raise ParseError, "invalid XML text" if event.event_type == :text && event[0].include?("]]>")

          content = event.event_type == :text ? decode_text(event[0]) : event[0]
          if stack.empty?
            raise ParseError, "text outside the root element" unless content.strip.empty?
          else
            append(stack.last, content)
          end
        when :xmldecl
          raise ParseError, "unsupported XML declaration" unless nodes == 1 && root.nil? && (event[0].nil? || event[0] == "1.0") &&
                                                                             (event[1].nil? || %w[UTF-8 US-ASCII].include?(event[1].upcase))
        when :comment
          append(stack.last, Markup.new(:comment, event[0])) unless stack.empty?
        when :processing_instruction
          raise ParseError, "reserved XML processing instruction" if event[0].downcase == "xml"

          append(stack.last, Markup.new(:instruction, [event[0], event[1]].join(" "))) unless stack.empty?
        when :end_document
          break
        else
          raise ParseError, "DTD and entity declarations are not supported"
        end
      end
      raise ParseError, "incomplete XML document" unless root && stack.empty?

      root
    rescue REXML::ParseException, EncodingError, ArgumentError, RangeError
      raise ParseError, "invalid XML input"
    end

    def expand(name, namespaces, attribute: false)
      names = name.split(":", -1)
      raise ParseError, "invalid XML qualified name" if names.size > 2 || names.any?(&:empty?)

      return [attribute ? "" : namespaces.fetch("", ""), name] if names.size == 1

      uri = namespaces[names.first]
      raise ParseError, "undeclared XML namespace prefix" unless uri

      [uri, names.last]
    end

    def serialize(node)
      writer = Writer.new(@limits)
      write_node(writer, node)
      writer.value
    end

    def write_node(writer, node, parent_namespaces = {}, detached: true)
      attrs = node.attributes.reject { |key, _| key == "xmlns" || key.start_with?("xmlns:") }
      if detached
        attrs["xmlns"] = "" unless node.namespaces.key?("")
        attrs["xml:lang"] = node.lang || "" unless attrs.key?("xml:lang")
      end
      node.namespaces.each do |prefix, uri|
        next if prefix == "xml" || parent_namespaces[prefix] == uri

        attrs[prefix.empty? ? "xmlns" : "xmlns:#{prefix}"] = uri
      end
      writer.open(node.name, attrs)
      node.parts.each do |part|
        case part
        when Node then write_node(writer, part, node.namespaces, detached: false)
        when Markup
          writer.append(part.kind == :comment ? "<!--#{part.value}-->" : "<?#{part.value}?>")
        else writer.text(part)
        end
      end
      writer.close(node.name)
    end

    private

    def check_characters(value)
      unless value.valid_encoding? && !value.match?(/[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/)
        raise ParseError, "XML must contain valid UTF-8 XML 1.0 characters"
      end
    end

    def decode_text(value)
      result = value.gsub(/&([^&;]*);|&/) do
        reference = Regexp.last_match(1)
        raise ParseError, "invalid XML entity reference" unless reference

        if ENTITIES.key?(reference)
          ENTITIES.fetch(reference)
        elsif reference.match?(/\A#(?:[0-9]+|x[0-9A-Fa-f]+)\z/)
          number = reference.start_with?("#x") ? reference[2..].to_i(16) : reference[1..].to_i
          raise ParseError, "invalid XML character reference" if number > 0x10ffff

          [number].pack("U")
        else
          raise ParseError, "unsupported XML entity reference"
        end
      end
      check_characters(result)
      result
    end

    def append(node, part)
      raise LimitError, "XML content exceeds max_collection_size" if node.parts.size >= @limits[:max_collection_size]

      node.parts << part
    end

    class Writer
      attr_reader :value

      def initialize(limits)
        @maximum = limits[:max_input_size]
        @value = +""
      end

      def append(value)
        raise LimitError, "output exceeds max_input_size" if @value.bytesize + value.bytesize > @maximum

        @value << value
      end

      def text(value, attribute: false)
        if value.is_a?(Float)
          value = format("%.17g", value)
          value += ".0" unless value.match?(/[.eE]/)
        else
          value = value.to_s
        end
        unless Types.string?(value) && !value.match?(/[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/)
          raise ConversionError, "value cannot be represented in XML 1.0"
        end
        escapes = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\r" => "&#13;", '"' => "&quot;", "\t" => "&#9;", "\n" => "&#10;" }
        append(value.gsub(attribute ? /[&<>\r"\t\n]/ : /[&<>\r]/) { |char| escapes.fetch(char) })
      end

      def open(name, attributes = {})
        append("<#{name}")
        attributes.each do |key, value|
          append(" #{key}=\"")
          text(value, attribute: true)
          # Attribute whitespace is emitted as references so XML normalization cannot alter it.
          append('"')
        end
        append(">")
      end

      def close(name)
        append("</#{name}>")
      end
    end
  end
end
