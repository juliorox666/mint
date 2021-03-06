module Mint
  class TypeChecker
    alias Checkable = Type | Record | Variable

    class Variable
      @@id = 0

      property parameters : Array(Checkable) = [] of Checkable
      property instance : Checkable?
      getter name : String
      getter id : Int32

      def initialize(@name)
        @id = (@@id += 1)
      end

      def to_mint
        to_s
      end

      def to_s(io : IO)
        if obj = @instance
          obj.to_s(io)
        else
          io << name
        end
      end

      def to_pretty
        @instance.try(&.to_pretty) || name
      end

      def have_holes?
        true
      end
    end

    class Type
      getter parameters : Array(Checkable)
      getter name : String

      def initialize(@name, @parameters = [] of Checkable)
      end

      def to_mint
        to_s
      end

      def to_pretty
        if parameters.empty?
          name
        else
          params =
            parameters.map(&.to_pretty.as(String))

          if params.any?(&.includes?('\n')) || params.size > 4
            "#{name}(\n#{params.join(",\n").indent})"
          else
            "#{name}(#{params.join(", ")})"
          end
        end
      end

      def have_holes?
        parameters.any?(&.have_holes?)
      end

      def to_s(io : IO)
        io << name
        unless parameters.empty?
          io << '('
          parameters.join(io, ", ")
          io << ')'
        end
      end
    end

    class Record
      property parameters : Array(Checkable) = [] of Checkable
      getter name, fields, mappings

      def initialize(@name : String, @fields = {} of String => Checkable, @mappings = {} of String => String?)
      end

      def to_pretty
        return name if fields.empty?

        defs =
          fields
            .map do |key, value|
              result = value.to_pretty
              if result.includes?('\n')
                "#{key}:\n#{value.to_pretty.indent}"
              else
                "#{key}: #{value.to_pretty}"
              end
            end

        if defs.any?(&.includes?('\n')) || defs.size > 4
          "#{name}(\n#{defs.join(",\n").indent})"
        else
          "#{name}(#{defs.join(", ")})"
        end
      end

      def to_mint
        name
      end

      def to_s(io : IO)
        io << name
        unless fields.empty?
          io << '('
          fields.join(io, ", ") do |(key, value), inner_io|
            inner_io << key << ": " << value
          end
          io << ')'
        end
      end

      def have_holes?
        fields.values.any?(&.have_holes?)
      end

      def ==(other : Record)
        self == other.fields
      end

      def ==(other : Hash(String, Checkable))
        return false unless fields.size == other.size

        other.all? do |key, type|
          next false unless fields[key]?
          !Comparer.compare(fields[key], type).nil?
        end
      end
    end

    class PartialRecord < Record
      def to_s(io : IO)
        if fields.empty?
          io << "(...)"
        else
          io << '('
          fields.join(io, ", ") do |(key, value), inner_io|
            inner_io << key << ": " << value
          end
          io << ", ...)"
        end
      end

      def to_pretty
        return "(...)" if fields.empty?

        defs =
          fields
            .map do |key, value|
              result = value.to_pretty
              if result.includes?('\n')
                "#{key}:\n#{value.to_pretty.indent}"
              else
                "#{key}: #{value.to_pretty}"
              end
            end

        defs << "..."

        if defs.any?(&.includes?('\n')) || defs.size > 4
          "(\n#{defs.join(",\n").indent})"
        else
          "(#{defs.join(", ")})"
        end
      end

      def ==(other : Hash(String, Checkable))
        fields.all? do |key, type|
          next false unless other[key]?
          !Comparer.compare(other[key], type).nil?
        end
      end
    end

    module Comparer
      extend self

      def matches_any?(node, targets)
        targets.any? { |target| compare(node, target) }
      end

      def compare(node1, node2)
        prune(unify(fresh(prune(node1)), fresh(prune(node2))))
      rescue
        nil
      end

      def compare_raw(node1, node2)
        unify(fresh(prune(node1)), fresh(prune(node2)))
      rescue
        nil
      end

      def fill(node, mapping : Hash(String, Checkable))
        node = prune(node)

        case node
        when Variable
          mapping[node.name]? || node
        when Type
          parameters =
            node.parameters.map { |param| fill(param, mapping).as(Checkable) }

          Type.new(node.name, parameters)
        else
          node
        end
      end

      def unify(node1, node2)
        node1 = prune(node1)
        node2 = prune(node2)

        case
        when node1.is_a?(Variable)
          unless node1 == node2
            if occurns_in_type(node1, node2)
              raise "Recursive unification!"
            end
            node1.instance = node2
          end
          node1
        when node2.is_a?(Variable)
          unify(node2, node1)
        when node1.is_a?(Record) && node2.is_a?(Type)
          raise "Not unified!" unless node1.name == node2.name
          node1
        when node2.is_a?(Record) && node1.is_a?(Type)
          unify(node2, node1)
        when node1.is_a?(Record) && node2.is_a?(Record)
          raise "Not unified!" unless node1 == node2
          node1
        when node1.is_a?(Type) && node2.is_a?(Type)
          if node1.name != node2.name || node1.parameters.size != node2.parameters.size
            raise "Type error: #{node1} is not #{node2}!"
          else
            node1.parameters.each_with_index do |item, index|
              unify(item, node2.parameters[index])
            end
          end
          node1
        else
          raise "Not unified!"
        end
      end

      def occurns_in_type(node1, node2)
        node2 = prune(node2)

        case
        when node1 == node2
          true
        when node2.is_a?(Type)
          occurns_in_type_array(node1, node2.parameters)
        else
          false
        end
      end

      def occurns_in_type_array(node, parameters)
        parameters.any? { |type| occurns_in_type node, type }
      end

      def normalize(type : Type, mapping = {} of String => Variable)
        type.parameters.map! do |parameter|
          case parameter
          when Variable
            mapping[parameter.name]? || (mapping[parameter.name] = parameter)
          when Type
            normalize(parameter, mapping)
          else
            parameter
          end
        end

        type
      end

      def normalize(node : Record)
        node
      end

      def normalize(node : Variable)
        node
      end

      def fresh(node : Variable)
        Variable.new(node.name)
      end

      def fresh(node : Type, mapping = {} of Int32 => Variable)
        params =
          node
            .parameters
            .map do |parameter|
              case parameter
              when Variable
                mapping[parameter.id]? || (mapping[parameter.id] = fresh(parameter)).as(Checkable)
              when Type
                fresh(parameter, mapping).as(Checkable)
              else
                fresh(parameter).as(Checkable)
              end
            end

        Type.new(node.name, params)
      end

      def fresh(node : PartialRecord)
        fields =
          node
            .fields
            .each_with_object({} of String => Checkable) do |(key, value), memo|
              memo[key] = fresh value
            end

        PartialRecord.new(node.name, fields)
      end

      def fresh(node : Record)
        fields =
          node
            .fields
            .each_with_object({} of String => Checkable) do |(key, value), memo|
              memo[key] = fresh value
            end

        Record.new(node.name, fields)
      end

      def prune(node : Variable)
        node.instance.try { |instance| prune instance } || node
      end

      def prune(node : Type)
        node.parameters.map! { |param| prune param }
        node
      end

      def prune(node : Record)
        node
      end
    end
  end
end
