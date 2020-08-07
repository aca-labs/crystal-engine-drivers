require "driver/interface/powerable"
require "driver/interface/muteable"
require "driver/interface/switchable"

module Samsung; end

class Samsung::Displays::MDCProtocol < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  INDICATOR = 0xAA_u8

  enum Inputs
    Vga           = 0x14 # pc in manual
    Dvi           = 0x18
    Dvi_Video     = 0x1F
    Hdmi          = 0x21
    Hdmi_Pc       = 0x22
    Hdmi2         = 0x23
    Hdmi2_Pc      = 0x24
    Hdmi3         = 0x31
    Hdmi3_Pc      = 0x32
    Hdmi4         = 0x33
    Hdmi4_Pc      = 0x34
    Display_Port  = 0x25
    Dtv           = 0x40
    Media         = 0x60
    Widi          = 0x61
    Magic_Info    = 0x20
    Whiteboard    = 0x64
  end
  include PlaceOS::Driver::Interface::InputSelection(Inputs)

  # Discovery Information
  tcp_port 1515
  descriptive_name "Samsung MD, DM & QM Series LCD"
  generic_name :Display

  # Markdown description
  description <<-DESC
  For DM displays configure the following 1:

  1. Network Standby = ON
  2. Set Auto Standby = OFF
  3. Set Eco Solution, Auto Off = OFF

  Hard Power off displays each night and hard power ON in the morning.
  DESC

  default_settings({
    display_id: 0,
    rs232_control: false
  })

  @id : Int32 = 0
  @rs232 : Bool = false
  @blank : Input?
  @previous_volume : Int32 = 50
  # Meta data for inquiring interfaces
  @input_stable : Bool = true
  @input_target : Input = Input::Hdmi
  @power_stable : Bool = true

  def on_load
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.peek
      # Ensure message indicator is well-formed
      disconnect unless bytes.first == INDICATOR
      logger.debug { "Received: #{bytes}" }
      # [header, command, id, data.size, [data], checksum]
      # return 0 if the message is incomplete
      bytes.size < 4 ? 0 : bytes[3].to_i + 5
    end

    on_update
  end

  def on_update
    @id = setting(Int32, :display_id)
    @rs232 = setting(Bool, :rs232_control)
    if blanking_input = setting?(String, :blanking_input)
      @blank = Input.parse?(blanking_input)
    end
  end

  def connected
    do_device_config unless self[:hard_off]?

    schedule.every(30.seconds, true) do
      do_poll
    end
  end

  def disconnected
    self[:power] = false unless @rs232
    schedule.clear
  end

  # As true power off disconnects the server we only want to
  # power off the panel. This doesn't work in video walls
  # so if a nominal blank input is
  # TODO: check type for broadcast is correct
  def power(power : Bool, broadcast : String? = nil)
    self[:power_target] = power
    @power_stable = false

    if !power
      # Blank the screen before turning off panel if required
      # required by some video walls where screens are chained
      if (blanking_input = @blank) && self[:power]?
        switch_to(blanking_input)
      end
      do_send(Command::Panel_Mute, 1)
    elsif !@rs232 && !self[:connected]? && (broadcast_string = broadcast)
       wake_device(broadcast_string)
    else
      # Power on
      do_send(Command::Hard_Off, 1)
      do_send(Command::Panel_Mute, 0)
    end
  end

  def hard_off
    do_send(Command::Panel_Mute, 0) if self[:power]?
    do_send(Command::Hard_Off, 0)
  end

  # TODO: figure out what block is for
  # def power?(**options, &block)
  def power?(**options)
    # options[:emit] = block unless block.nil?
    do_send(Command::Panel_Mute, Bytes.empty, **options)
  end

  # Mutes audio + video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    logger.debug { "requested mute state: #{state}" }
    mute_video(state)
    mute_audio(state)
  end

  # Adds mute states compatible with projectors
  def mute_video(state : Bool = true)
    state = state ? 1 : 0
    do_send(Command::Panel_Mute, state)
  end

  def unmute_video
    mute_video(false)
  end

  # Emulate mute
  def mute_audio(val : Bool = true)
    if val
      if !self[:audio_mute]?
        self[:audio_mute] = true
        @previous_volume = self[:volume].as_i
        volume(0)
      end
    else
      unmute_audio
    end
  end

  def unmute_audio
    if self[:audio_mute]?
      self[:audio_mute] = false
      volume(@previous_volume)
    end
  end

  # check software version
  def software_version?
    do_send(Command::Software_Version)
  end

  def serial_number?
    do_send(Command::Serial_Number)
  end

  def switch_to(input : Input, **options)
    @input_stable = false
    @input_target = input
    do_send(Command::Input, input.value, **options)
  end

  enum SpeakerModes
    Internal = 0
    External = 1
  end

  def speaker_select(mode : String, **options)
    do_send(Command::Speaker, SpeakerModes.parse(mode).value, **options)
  end

  def do_poll
    do_send(Command::Status, Bytes.empty, priority: 0)
    power? unless self[:hard_off]?
  end

  # Enable power on (without WOL)
  def network_standby(enable : Bool, **options)
    state = enable ? 1 : 0
    do_send(Command::Net_Standby, state, **options)
  end

  # Eco auto power off timer
  def auto_off_timer(enable : Bool, **options)
    state = enable ? 1 : 0
    do_send(Command::Eco_Solution, Bytes[0x81, state], **options)
  end

  # Device auto power control (presumably signal based?)
  def auto_power(enable : Bool, **options)
    state = enable ? 1 : 0
    do_send(Command::Auto_Power, state, **options)
  end

  # Display control
  {% for name in ["volume", "contrast", "brightness", "sharpness", "colour", "tint", "red_gain", "green_gain", "blue_gain"] %}
    @[Security(Level::Administrator)]
    def {{name.id}}(val : Int32, **options)
      val = val.clamp(0, 100)
      do_send(Command.parse({{name.id.stringify}}), val, **options)
    end
  {% end %}

  DEVICE_SETTINGS = [
    :network_standby,
    :auto_off_timer,
    :auto_power,
    :contrast,
    :brightness,
    :sharpness,
    :colour,
    :tint,
    :red_gain,
    :green_gain,
    :blue_gain,
]

  def do_device_config
    logger.debug { "Syncronising device state with settings" }
    DEVICE_SETTINGS.each do |name|
      value = setting?(Int32, name)
      # TODO: find out if these are equivalent
      # __send__(name, value) unless value.nil?
      do_send(Command.parse(value.to_s), value) unless value.nil?
    end
  end

  enum ResponseStatus
    Ack = 0x41 # A
    Nak = 0x4e # N
  end

  def received(data, task)
    hex = data.hexstring
    logger.debug { "Samsung sent: #{hex}" }
    data = data.map(&.to_i).to_a

    # Calculate checksum of response
    checksum = data[1..-2].reduce(&.+)

    # Pop also removes the checksum from the response here
    if data.pop != checksum
      logger.error { "Invalid checksum\nChecksum should be: #{checksum.to_s(16)}" }
      return task.try &.retry
    end

    status = ResponseStatus.from_value(data[4])
    command = Command.from_value(data[5])
    values = data[6..-1]
    value = values.first

    case status
    when .ack?
      case command
      when .status?
        self[:hard_off]   = values[0] == 0
        self[:power]      = false if self[:hard_off]
        self[:volume]     = values[1]
        self[:audio_mute] = values[2] == 1
        self[:input]      = Inputs.from_value(values[3]).to_s
        check_power_state
      when .panel_mute?
        self[:power] = value == 0
        check_power_state
      when .volume?
        self[:volume] = value
        self[:audio_mute] = false if value > 0
      when .brightness?
        self[:brightness] = value
      when .input?
        self[:input] = Inputs.from_value(value).to_s
        # The input feedback behaviour seems to go a little odd when
        # screen split is active. Ignore any input forcing when on.
        unless self[:screen_split]
          @input_stable = self[:input] == @input_target
          switch_to(@input_target) unless @input_stable
        end
      when .speaker?
        self[:speaker] = SpeakerModes.from_value(value).to_s
      when .hard_off?
        self[:hard_off] = value == 0
        self[:power] = false if self[:hard_off]
      when .screen_split?
        self[:screen_split] = value >= 0
      when .software_version?
        self[:software_version] = values.join
      when .serial_number?
        self[:serial_number] = values.join
      else
        logger.debug { "Samsung responded with ACK: #{value}" }
      end

      task.try &.success
    when .nak?
      task.try &.abort("Samsung responded with NAK: #{hex}")
    else
      task.try &.abort("Samsung aborted with: #{hex}")
    end
  end

  def check_power_state
    return if @power_stable
    if self[:power]? == self[:power_target]?
      @power_stable = true
    else
      power(self[:power_target].as_bool)
    end
  end

  enum Command
    Status           = 0x00
    Hard_Off         = 0x11 # Completely powers off
    Panel_Mute       = 0xF9 # Screen blanking / visual mute
    Volume           = 0x12
    Contrast         = 0x24
    Brightness       = 0x25
    Sharpness        = 0x26
    Colour           = 0x27
    Tint             = 0x28
    Red_Gain         = 0x29
    Green_Gain       = 0x2A
    Blue_Gain        = 0x2B
    Input            = 0x14
    Mode             = 0x18
    Size             = 0x19
    Pip              = 0x3C # picture in picture
    Auto_Adjust      = 0x3D
    Wall_Mode        = 0x5C # Video wall mode
    Safety           = 0x5D
    Wall_On          = 0x84 # Video wall enabled
    Wall_User        = 0x89 # Video wall user control
    Speaker          = 0x68
    Net_Standby      = 0xB5 # Keep NIC active in standby
    Eco_Solution     = 0xE6 # Eco options (auto power off)
    Auto_Power       = 0x33
    Screen_Split     = 0xB2 # Tri / quad split (larger panels only)
    Software_Version = 0x0E
    Serial_Number    = 0x0B
    Time             = 0xA7
    Timer            = 0xA4

    def build(id : Int32, data : Bytes) : Bytes
      Bytes.new(data.size + 5).tap do |bytes|
        bytes[0] = 0xAA_u8                              # Header
        bytes[1] = self.to_u8                           # Command
        bytes[2] = id.to_u8                             # Display ID
        bytes[3] = data.size.to_u8                      # Data size
        data.each_with_index(4) { |b, i| bytes[i] = b } # Data
        bytes[-1] = bytes[1..-2].reduce(&.+)            # Checksum
      end
    end
  end

  private def do_send(command : Command, data : Int | Bytes = Bytes.empty, **options)
    data = Bytes[data] if data.is_a?(Int)
    bytes = command.build(@id, data)
    logger.debug { "Sending to Samsung: #{bytes.hexstring}" }
    send(bytes, **options)
    # TODO: find out if this is necessary
    # send(array_to_str(data), options).catch do |reason|
    #   disconnect
    #   thread.reject(reason)
    # end
  end
end
