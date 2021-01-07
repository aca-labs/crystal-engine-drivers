# TODO: figure out if I should use this
# require "placeos-driver/interface/muteable"

class Qsc::QSysRemote < PlaceOS::Driver
  # include Interface::Muteable

  # Discovery Information
  tcp_port 1710
  descriptive_name "QSC Audio DSP"
  generic_name :Mixer

  @id : Int32 = 0
  @db_based_faders : Val? = nil
  @integer_faders : Val? = nil

  Delimiter = "\0"
  JsonRpcVer = "2.0"

  alias Val = Int32 | Float64
  alias ValTup = NamedTuple(Name: String, Value: Val) | NamedTuple(Name: String, Position: Val)
  alias Vals = ValTup | Array(ValTup)
  alias Ids = String | Array(String)

  def on_load
    transport.tokenizer = Tokenizer.new(Delimiter)
    on_update
  end

  def on_update
    @db_based_faders = setting?(Float64, :db_based_faders)
    @integer_faders = setting?(Int32, :integer_faders)
  end

  def connected
    schedule.every(20.seconds) do
      logger.debug { "Maintaining Connection" }
      no_op
    end
    @id = 0
    logon
  end

  def disconnected
    schedule.clear
  end

  def no_op
    do_send(cmd: :NoOp, priority: 0)
  end

  def get_status
    do_send(next_id, cmd: :StatusGet, params: 0, priority: 0)
  end

  def logon(username : String? = nil, password : String? = nil)
    username ||= setting?(String, :username)
    password ||= setting?(String, :password)
    # Don't login if there is no username or password set
    return unless username || password

    do_send(
      cmd: :Logon,
      params: {
        :User => username,
        :Password => password
      },
      priority: 99
    )
  end

  def control_set(name : String, value : Val, ramp : Val? = nil, **options)
    if ramp
      params = {
        :Name =>  name,
        :Value => value,
        :Ramp => ramp
      } 
    else
      params = {
          :Name =>  name,
          :Value => value
      }
    end

    do_send(next_id, "Control.Set", params, **options)
  end

  def control_get(*names, **options)
    do_send(next_id, "Control.Get", names.to_a.flatten, **options)
  end

  # Example usage:
  # component_get 'My AMP', 'ent.xfade.gain', 'ent.xfade.gain2'
  def component_get(c_name : String, *controls, **options)
    do_send(next_id, "Component.Get", {
      :Name => c_name,
      :Controls => controls.to_a.flat_map { |ctrl| { :Name => ctrl } }
    }, **options)
  end

  # Example usage:
  # component_set 'My APM', { "Name" => 'ent.xfade.gain', "Value" => -100 }, {...}
  def component_set(c_name : String, values : Vals, **options)
    values = ensure_array(values)

    do_send(next_id, "Component.Set", {
      :Name => c_name,
      :Controls => values
    }, **options)
  end

  def component_trigger(component : String, trigger : String, **options)
    do_send(next_id, "Component.Trigger", {
      :Name => component,
      :Controls => [{:Name => trigger}]
    }, **options)
  end

  def get_components(**options)
    do_send(next_id, "Component.GetComponents", **options)
  end

  def change_group_add_controls(group_id : Val, *controls, **options)
    do_send(next_id, "ChangeGroup.AddControl", {
      :Id => group_id,
      :Controls => controls
    }, **options)
  end

  def change_group_remove_controls(group_id : Val, *controls, **options)
    do_send(next_id, "ChangeGroup.Remove", {
      :Id => group_id,
      :Controls => controls
    }, **options)
  end

  def change_group_add_component(group_id : Val, component_name : String, *controls, **options)
    controls.to_a.flat_map { |ctrl| {:Name => ctrl } }

    do_send(next_id, "ChangeGroup.AddComponentControl", {
      :Id => group_id,
      :Component => {
        :Name => component_name,
        :Controls => controls
      }
    }, **options)
  end

  # Returns values for all the controls
  def poll_change_group(group_id : Val, **options)
    do_send(next_id, "ChangeGroup.Poll", {:Id => group_id}, **options)
  end

  # Removes the change group
  def destroy_change_group(group_id : Val, **options)
    do_send(next_id, "ChangeGroup.Destroy", {:Id => group_id}, **options)
  end

  # Removes all controls from change group
  def clear_change_group(group_id : Val, **options)
    do_send(next_id, "ChangeGroup.Clear", {:Id => group_id}, **options)
  end

  # Where every is the number of seconds between polls
  def auto_poll_change_group(group_id : Val, every : Val, **options)
    do_send(next_id, "ChangeGroup.AutoPoll", {
      :Id => group_id,
      :Rate => every
    }, **options)#, wait: false)
  end

  # Example usage:
  # mixer 'Parade', {1 => [2,3,4], 3 => 6}, true
  # def mixer(name, inouts, mute = false, *_,  **options)
  def mixer(name : String, inouts : Hash(Int32, Int32 | Array(Int32)), mute : Bool = false, **options)
    inouts.each do |input, outputs|
      outputs = ensure_array(outputs)

      do_send(next_id, "Mixer.SetCrossPointMute", {
          :Mixer => name,
          :Inputs => input.to_s,
          :Outputs => outputs.join(' '),
          :Value => mute
      }, **options)
    end
  end

  Faders = {
    matrix_in: {
      type: :"Mixer.SetInputGain",
      pri: :Inputs
    },
    matrix_out: {
      type: :"Mixer.SetOutputGain",
      pri: :Outputs
    },
    matrix_crosspoint: {
      type: :"Mixer.SetCrossPointGain",
      pri: :Inputs,
      sec: :Outputs
    }
  }
  def matrix_fader(name : String, level : Val, index : Array(Int32), type : String = "matrix_out", **options)
    info = Faders[type]

    if sec = info[:sec]?
      params = {
        :Mixer => name,
        :Value => level,
        info[:pri] => index[0],
        sec => index[1]
      }
    else
      params = {
        :Mixer => name,
        :Value => level,
        info[:pri] => index
      }
    end

    do_send(next_id, info[:type], params, **options)
  end

  Mutes = {
    matrix_in: {
      type: :"Mixer.SetInputMute",
      pri: :Inputs
    },
    matrix_out: {
      type: :"Mixer.SetOutputMute",
      pri: :Outputs
    }
  }
  def matrix_mute(name : String, value : Val, index : Array(Int32), type : String = "matrix_out", **options)
    info = Mutes[type]

    do_send(next_id, info[:type], {
      :Mixer => name,
      :Value => value,
      info[:pri] => index
    }, **options)
  end

  def fader(fader_ids : Ids, level : Val, component : String? = nil, type : String = "fader", use_value : Bool = false)
    faders = ensure_array(fader_ids)
    if component
      if @db_based_faders || use_value
        level = level / 10 if @integer_faders && !use_value
        fads = faders.map { |fad| {Name: fad, Value: level} }
      else
        level = level / 1000 if @integer_faders
        fads = faders.map { |fad| {Name: fad, Position: level} }
      end
      logger.debug { "fads = #{fads}"}
      logger.debug { "fads.class = #{fads.class}"}
      logger.debug { fads.class === Vals }
      # TODO: figure out how to get compiling
      # component_set(component, fads, name: "level_#{faders[0]}").get
      component_get(component, faders)
    else
      reqs = faders.map { |fad| control_set(fad, level) }
      reqs.last.get
      control_get(faders)
    end
  end

  def faders(ids : Ids, level : Val, component : String? = nil, type : String = "fader")
    fader(ids, level, component, type)
  end

  def received(data, task)
  end

  def next_id
    @id += 1
    @id
  end

  private def do_send(id : Int32? = nil, cmd = nil, params = {} of String => String, **options)
    if id
      req = {
        id: id,
        jsonrpc: JsonRpcVer,
        method: cmd,
        params: params
    }
    else
      req = {
        jsonrpc: JsonRpcVer,
        method: cmd,
        params: params
    }
    end

    logger.debug { "requesting: #{req}" }

    cmd = req.to_json + Delimiter

    send(cmd, **options)
  end

  private def ensure_array(object)
    object.is_a?(Array) ? object : [object]
  end
end
