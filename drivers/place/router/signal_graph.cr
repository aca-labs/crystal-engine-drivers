require "set"
require "./digraph"

# Structures and types for mapping between sys,mod,idx,io referencing and the
# underlying graph structure.
#
# The SignalGraph class _does not_ perform any direct interaction with devices,
# but does provide the ability to discover routes and available connectivity
# when may then be acted on.
class Place::Router::SignalGraph
  # Reference to a PlaceOS module that provides IO nodes within the graph.
  private class Mod
    getter sys  : String
    getter name : String
    getter idx  : Int32

    getter id   : String

    def initialize(@sys, @name, @idx)
      id = PlaceOS::Driver::Proxy::System.module_id? sys, name, idx
      @id = id || raise %("#{name}/#{idx}" does not exist in #{sys})
    end

    def metadata
      PlaceOS::Driver::Proxy::System.driver_metadata?(@id).not_nil!
    end

    macro finished
      {% for interface in PlaceOS::Driver::Interface.constants %}
        def {{interface.underscore}}?
          PlaceOS::Driver::Interface::{{interface}}.to_s.in? metadata.implements
        end
      {% end %}
    end

    def_equals_and_hash @id

    def to_s(io)
      io << sys
      io << '/'
      io << name
      io << '_'
      io << idx
    end
  end

  # Input reference on a device.
  alias Input = Int32 | String

  # Output reference on a device.
  alias Output = Int32 | String

  # Reference to a signal output from a device.
  record DeviceOutput, mod : Mod, output : Output do
    def initialize(sys, name, idx, @output)
      @mod = Mod.new sys, name, idx
    end
  end

  # Reference to a signal input to a device.
  record DeviceInput, input : Input, mod : Mod do
    def initialize(sys, name, idx, @input)
      @mod = Mod.new sys, name, idx
    end
  end

  # Node labels containing the metadata to track at each vertex.
  class Node
    property source : UInt64? = nil
    property locked : Bool = false
  end

  module Edge
    # Edge label for storing associated behaviour.
    alias Type = Static | Active

    class Static
      class_getter instance : Static { Static.new }
      protected def initialize; end
    end

    record Active, mod : Mod, func : Func::Type

    module Func
      record Mute,
        state : Bool,
        index : Int32 | String = 0
        # layer : Int32 | String = "AudioVideo"

      record Switch,
        input : Input

      record Route,
        input : Input
        output : Output
        # layer : 

      # NOTE: currently not supported. Requires interaction via
      # Proxy::RemoteDriver to support dynamic method execution.
      #record Custom,
      #  func : String,
      #  args : Hash(String, JSON::Any::Type)

      macro finished
        alias Type = {{ @type.constants.join(" | ").id }}
      end
    end
  end

  # Virtual node representing (any) mute source
  Mute = Node.new.tap &.source = 0

  @graph : Digraph(Node, Edge::Type)

  private def initialize(@graph)
    @graph[0] = Mute
  end

  private alias IOSets = { Set(Input), Set(Output) }

  # Construct a graph from a pre-parsed configuration.
  #
  # *inputs* must contain the list of all device inputs across the system. This
  # include those at the "edge" of the signal network (e.g. a laptop connected
  # to a switcher) as well as inputs in use on intermediate device (e.g. a input
  # on a display, which in turn is attached to the switcher above).
  #
  # *connections* declares the physical links that exist between devices.
  def self.from_io(inputs : Enumerable(DeviceInput), connections : Enumerable({DeviceOutput, DeviceInput}))
    g = Digraph(Node, Edge::Type).new initial_capacity: connections.size * 2

    m = Hash(Mod, IOSets).new { |h, k| h[k] = {Set(Input).new, Set(Output).new} }

    inputs.each do |input|
      # Create a node for the device input
      id = input.hash
      g[id] = Node.new

      # Track the input for active edge creation
      i, _ = m[input.mod]
      i << input.input
    end

    connections.each do |src, dst|
      # Create a node for the device output
      succ = src.hash
      g[succ] = Node.new

      # Ensure the input node was declared
      unless m[dst.mod].try { |i, _| i.includes? dst.input }
        raise ArgumentError.new "connection to #{dst} declared, but no matching input exists"
      end

      # Insert a static edge for the  physical link
      pred = dst.hash
      g[pred, succ] = Edge::Static.instance

      # Track device outputs for active edge creation
      _, o = m[src.mod]
      o << src.output
    end

    # Insert active edges
    m.each do |mod, (inputs, outputs)|
      puts mod
      puts inputs
      puts outputs

      if mod.switchable?
        Array.each_product(inputs.to_a, outputs.to_a) do |x|
          puts x
        end
      end

      if mod.selectable?
        inputs.each do |input|
          puts input
        end
      end

      if mod.mutable?
        outputs.each do |output|
          pred = mod.hash
          #!!! Sink.new ???
          #g[mod.hash
        end
      end
    end

    puts g

    new g
  end
end
