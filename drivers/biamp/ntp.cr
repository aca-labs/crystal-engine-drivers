# Biamp ATP/NTP protocol utilities.
# https://support.biamp.com/Audia-Nexia/Control/Audia-Nexia_Text_Protocol
module Biamp::NTP
  record Command,
    type : Type,
    device : Int32,
    attribute : String,
    instance : Int32? = nil,
    index_1 : Int32? = nil,
    index_2 : Int32? = nil,
    value : String | Int32 | Float32 | Nil = nil do
    macro [](type, *params)
      {% if type == :GET || type == :GETD %}
        {{@type.name}}.new({{type}}, {{params.splat}})
      {% else %}
        {{@type.name}}.new({{type}}, {{params[0...-1].splat}}, value: {{params[-1]}})
      {% end %}
    end

    enum Type
      SET
      SETD
      GET
      GETD
      INC
      INCD
      DEC
      DECD
      RECALL
      DIAL
    end

    def to_io(io : IO, format = nil)
      io << type
      {device, attribute, instance, index_1, index_2, value}.each do |field|
        next if field.nil?
        io << ' ' << field
      end
      io << '\n'
    end
  end

  module Response
    record FullPath, message : String, fields : Array(String)
    record OK
    record Error, message : String
    record Invalid, data : Bytes

    macro finished
      def self.parse(data : Bytes) : {{@type.constants.join(" | ").id}}
        case data[0]
        when '#'
          response = String.new data
          if response.includes? " -ERR"
            Error.new response
          else
            FullPath.new response, response[1..].split
          end
        when '+'
          OK.new
        when '-'
          Error.new String.new data
        else
          Invalid.new data
        end
      end
    end
  end
end
