require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
# require "placeos-driver/interface/switchable"

class Hitachi::Projector::CpTwSeriesBasic < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  # Discovery Information
  tcp_port 23
  descriptive_name "Hitachi CP-TW Projector (no auth)"
  generic_name :Display

  # Response time is slow
  # and as a make break device it may take time
  # to acctually setup the connection with the projector
  # delay on_receive: 100
  # wait_response timeout: 5000, retries: 3

  def on_load
    self[:power] = false

    # Stable by default (allows manual on and off)
    self[:stable_power] = true
    self[:stable_input] = true

    # Meta data for inquiring interfaces
    self[:type] = :projector

    on_update
  end

  def on_update
  end

  def connected
      schedule.every(50.seconds, true) { poll_1 }
      schedule.every(10.minutes, true) { poll_2 }
  end

  def poll_1
    power?(priority: 0).get
    if self[:power]?.try &.as_bool
      input?(priority: 0)
      audio_mute?(priority: 0)
      picture_mute?(priority: 0)
      freeze?(priority: 0)
    end
  end

  def poll_2
    lamp?(priority: 0)
    filter?(priority: 0)
    error?(priority: 0)
  end

  def disconnected
      schedule.clear
      # @recover_power = nil
      # @recover_input = nil
  end

  def power(state : Bool)
    self[:stable_power] = false

    if state
      logger.debug { "-- requested to power on" }
      self[:power_target] = true
      do_send("BA D2 01 00 00 60 01 00", name: :power)
    else
      logger.debug { "-- requested to power off" }
      self[:power_target] = false
      do_send("2A D3 01 00 00 60 00 00", name: :power)
    end
    power?.get
  end

  INPUTS = {
    "hdmi" => "0E D2 01 00 00 20 03 00",
    "hdmi2" => "6E D6 01 00 00 20 0D 00"
  }
  def switch_to(input : String)
    self[:stable_input] = false
    self[:input_target] = input
    do_send(INPUTS[input], name: :input)
    input?
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
  mute_video(state) if layer.video? || layer.audio_video?
  mute_audio(state) if layer.audio? || layer.audio_video?
  end

  def mute_video(state : Bool = true)
    if state
      do_send("6E F1 01 00 A0 20 01 00", name: :mute)
    else
      do_send("FE F0 01 00 A0 20 00 00", name: :mute)
    end
    picture_mute?
  end

  def mute_audio(state : Bool = true)
    if state
      do_send("D6 D2 01 00 02 20 01 00", name: :mute_audio)
    else
      do_send("46 D3 01 00 02 20 00 00", name: :mute_audio)
    end
    audio_mute?
  end

  QueryRequests = {
    power: "19 D3 02 00 00 60 00 00",
    input: "CD D2 02 00 00 20 00 00",
    error: "D9 D8 02 00 20 60 00 00",
    freeze: "B0 D2 02 00 02 30 00 00",
    audio_mute: "75 D3 02 00 02 20 00 00",
    picture_mute: "CD F0 02 00 A0 20 00 00",
    lamp: "C2 FF 02 00 90 10 00 00",
    filter: "C2 F0 02 00 A0 10 00 00"
  }
  {% for name, data in QueryRequests %}
    @[Security(Level::Administrator)]
    def {{name.id}}?(**options)
      do_send({{data}}, **options, name: {{name.id.stringify}} + '?')
    end
  {% end %}

  def lamp_hours_reset
    do_send("58 DC 06 00 30 70 00 00", name: :lamp_hours_reset)
    lamp?
  end

  def filter_hours_reset
    do_send("98 C6 06 00 40 70 00 00", name: :filter_hours_reset)
    filter?
  end

  enum ResponseCode
    Ack   = 0x06
    Nak   = 0x15
    Error = 0x1c
    Data  = 0x1d
    Busy  = 0x1f
  end

  enum InputCode
    Hdmi    = 0x03
    Hdmi2   = 0x0d
    HdbaSet = 0x11
  end

  enum ErrorCode
    Normal
    Cover
    Fan
    Lamp
    Temp
    AirFlow
    Cold
    Filter
  end

  def received(data, task)
    logger.debug { "received 0x#{data}" }
    command = task.try &.name

    case ResponseCode.from_value(data[0])
    when .ack?
      :success
    when .nak?
      task.try &.abort("NAK response")
    when .error?
      task.try &.abort("Error response")
    when .data?
      if command
        case command
        when :power?
          self[:power] = data[1] == 1
          self[:cooling] = data[1] == 2

          if self[:power] == self[:power_target]
            self[:stable_power] = true
          elsif !self[:stable_power]# && @recover_power.nil?
            logger.debug { "recovering power state #{self[:power]} != target #{self[:power_target]}" }
            # @recover_power = schedule.in(3.seconds) do
            #   @recover_power = nil
            #   power(self[:power_target])
            # end
          end
        when :input?
            self[:input] = InputCode.from_value?(data[1]) || :unknown

            if self[:input] == self[:input_target]
              self[:stable_input] = true
            elsif !self[:stable_input]# && @recover_input.nil?
                logger.debug { "recovering input #{self[:input]} != target #{self[:input_target]}" }
                # @recover_input = schedule.in(3.seconds) do
                #   @recover_input = nil
                #   switch_to(self[:input_target])
                # end
            end
        when :error?
          self[:error_status] = ErrorCode.from_value?(data[1]) || :unknown
        when :freeze?
          self[:frozen] = data[1] == 1
        when :audio_mute?
          self[:audio_mute] = data[1] == 1
        when :picture_mute?
          self[:mute] = data[1] == 1
        when :lamp?
          self[:lamp] = data[1] + (data[2] << 8)
        when :filter?
          self[:filter] = data[1] + (data[2] << 8)
        else
          logger.debug { "unknown command query: #{command}" }
        end

        :success
      else
        task.try &.abort("data received for unknown command")
      end
    when :busy
      if data[1] == 4 && data[2] == 0
        task.try &.abort("authentication enabled, please disable")
      else
        task.try &.retry("projector busy, retrying")
      end
    end
  end

  private def do_send(data : String, **options)
    cmd = "BEEF030600 #{data}"
    # options[:hex_string] = true
    logger.debug { "requesting \"0x#{cmd}\" name: #{options[:name]}" }
    send(cmd, **options)
  end
end