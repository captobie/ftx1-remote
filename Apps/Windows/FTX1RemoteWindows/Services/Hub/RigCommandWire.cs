using System.Text.Json;
using System.Text.Json.Nodes;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.Hub;

/// A client's `{"cmd": …, "value": …}` — Sources/FTX1Core/Networking/
/// WireMessage.swift's RigCommand, one record per case. The value shapes are
/// Swift's, not designed here (Tests/WireFixtures/rig-commands.json has one
/// of each, made by the Swift encoder): modes are RigMode raw values, sides
/// are 0/1, and set_menu_item / recall_memory_channel / set_memory_scan
/// carry small objects. Compiled into the test project too, so keep it free
/// of WinUI types.
public abstract record RigCommand
{
    /// The wire name ("set_freq", "ptt", …).
    public abstract string Name { get; }

    /// The "value" as Swift encodes it; null for the momentary commands,
    /// which carry none.
    public abstract JsonNode? WireValue { get; }

    /// "set_freq 14074000", for the log. Sealed, so the derived records
    /// don't synthesize their own.
    public sealed override string ToString() => WireValue is null ? Name : $"{Name} {WireValue.ToJsonString()}";
}

// Value shapes. Each concrete command below is one of these plus its name.

public abstract record MomentaryCommand : RigCommand
{
    public override JsonNode? WireValue => null;
}

public abstract record BoolCommand(bool On) : RigCommand
{
    public override JsonNode? WireValue => JsonValue.Create(On);
}

public abstract record IntCommand(int Value) : RigCommand
{
    public override JsonNode? WireValue => JsonValue.Create(Value);
}

public abstract record DoubleCommand(double Value) : RigCommand
{
    public override JsonNode? WireValue => JsonValue.Create(Value);
}

/// A RigMode raw value — see <see cref="HubMode"/>.
public abstract record ModeCommand(string Mode) : RigCommand
{
    public override JsonNode? WireValue => JsonValue.Create(Mode);
}

public abstract record SideCommand(FilterSide Side) : RigCommand
{
    public override JsonNode? WireValue => JsonValue.Create((int)Side);
}

public sealed record SetFrequency(long Hz) : RigCommand
{
    public override string Name => "set_freq";
    public override JsonNode? WireValue => JsonValue.Create(Hz);
}

public sealed record SetSecondaryFrequency(long Hz) : RigCommand
{
    public override string Name => "set_secondary_freq";
    public override JsonNode? WireValue => JsonValue.Create(Hz);
}

public sealed record SwapActiveVfo : MomentaryCommand { public override string Name => "swap_active_vfo"; }
public sealed record SetMode(string Mode) : ModeCommand(Mode) { public override string Name => "set_mode"; }
public sealed record SetSecondaryMode(string Mode) : ModeCommand(Mode) { public override string Name => "set_secondary_mode"; }
public sealed record SetPtt(bool On) : BoolCommand(On) { public override string Name => "ptt"; }

public sealed record SetBand(string Band) : RigCommand
{
    public override string Name => "set_band";
    public override JsonNode? WireValue => JsonValue.Create(Band);
}

/// 0.0-1.0 of RFPOWER, not watts.
public sealed record SetPowerLevel(double Value) : DoubleCommand(Value) { public override string Name => "set_power"; }
public sealed record SetBreakIn(bool On) : BoolCommand(On) { public override string Name => "set_break_in"; }
public sealed record SetKeyer(bool On) : BoolCommand(On) { public override string Name => "set_keyer"; }
public sealed record SetCwSpeed(int Value) : IntCommand(Value) { public override string Name => "set_cw_speed"; }
public sealed record SetCwPitch(int Value) : IntCommand(Value) { public override string Name => "set_cw_pitch"; }
/// Milliseconds, one of RigDelayCode's values.
public sealed record SetBreakInDelay(int Value) : IntCommand(Value) { public override string Name => "set_bk_delay"; }
public sealed record SetCwSpot(bool On) : BoolCommand(On) { public override string Name => "set_cw_spot"; }
public sealed record TriggerZeroIn : MomentaryCommand { public override string Name => "zero_in"; }
public sealed record SetMoniLevel(int Value) : IntCommand(Value) { public override string Name => "set_moni_level"; }
public sealed record SelectCwMessageChannel(int Value) : IntCommand(Value) { public override string Name => "select_cw_message_channel"; }
public sealed record SetCwMessageRecording(bool On) : BoolCommand(On) { public override string Name => "set_cw_message_recording"; }
/// 0 stops, 1-5 plays that CW MESSAGE channel.
public sealed record PlayCwMessage(int Value) : IntCommand(Value) { public override string Name => "play_cw_message"; }
/// 0 stops, 1-5 plays that CW TEXT keyer memory.
public sealed record PlayCwTextMemory(int Value) : IntCommand(Value) { public override string Name => "play_cw_text_memory"; }
public sealed record SetMox(bool On) : BoolCommand(On) { public override string Name => "set_mox"; }
public sealed record SetAtt(bool On) : BoolCommand(On) { public override string Name => "set_att"; }
public sealed record SetPreamp(int Value) : IntCommand(Value) { public override string Name => "set_preamp"; }
public sealed record SetTuner(bool On) : BoolCommand(On) { public override string Name => "set_tuner"; }
public sealed record TriggerAntennaTune : MomentaryCommand { public override string Name => "trigger_antenna_tune"; }
public sealed record SetDisplayContrast(int Value) : IntCommand(Value) { public override string Name => "set_display_contrast"; }
public sealed record SetDisplayDimmer(int Value) : IntCommand(Value) { public override string Name => "set_display_dimmer"; }
public sealed record SetDisplayLevel(double Value) : DoubleCommand(Value) { public override string Name => "set_display_level"; }
public sealed record SetDisplayPeak(int Value) : IntCommand(Value) { public override string Name => "set_display_peak"; }
public sealed record SetDisplayMarker(bool On) : BoolCommand(On) { public override string Name => "set_display_marker"; }
public sealed record SetMicGain(int Value) : IntCommand(Value) { public override string Name => "set_mic_gain"; }
public sealed record SetAmcLevel(int Value) : IntCommand(Value) { public override string Name => "set_amc_level"; }
public sealed record SetVox(bool On) : BoolCommand(On) { public override string Name => "set_vox"; }
public sealed record SetVoxGain(int Value) : IntCommand(Value) { public override string Name => "set_vox_gain"; }
/// Milliseconds, one of RigDelayCode's values.
public sealed record SetVoxDelay(int Value) : IntCommand(Value) { public override string Name => "set_vox_delay"; }
public sealed record SetDnf(bool On) : BoolCommand(On) { public override string Name => "set_dnf"; }
public sealed record SetAgc(int Value) : IntCommand(Value) { public override string Name => "set_agc"; }
public sealed record SetMicEq(bool On) : BoolCommand(On) { public override string Name => "set_mic_eq"; }
public sealed record SetProcLevel(int Value) : IntCommand(Value) { public override string Name => "set_proc_level"; }
public sealed record SetNbLevel(int Value) : IntCommand(Value) { public override string Name => "set_nb_level"; }
public sealed record SetDnrLevel(int Value) : IntCommand(Value) { public override string Name => "set_dnr_level"; }
public sealed record SetFilterWidth(int Value) : IntCommand(Value) { public override string Name => "set_filter_width"; }
public sealed record SetIfShift(int Value) : IntCommand(Value) { public override string Name => "set_if_shift"; }
public sealed record SetNotch(bool On) : BoolCommand(On) { public override string Name => "set_notch"; }
public sealed record SetNotchFrequency(int Value) : IntCommand(Value) { public override string Name => "set_notch_freq"; }
public sealed record SetContour(bool On) : BoolCommand(On) { public override string Name => "set_contour"; }
public sealed record SetContourFrequency(int Value) : IntCommand(Value) { public override string Name => "set_contour_freq"; }
public sealed record SetApf(bool On) : BoolCommand(On) { public override string Name => "set_apf"; }
public sealed record SetApfOffset(int Value) : IntCommand(Value) { public override string Name => "set_apf_offset"; }
public sealed record SetNarrow(bool On) : BoolCommand(On) { public override string Name => "set_narrow"; }
public sealed record SetFilterSide(FilterSide Side) : SideCommand(Side) { public override string Name => "set_filter_side"; }
public sealed record SetAntSelect(int Value) : IntCommand(Value) { public override string Name => "set_ant_select"; }
public sealed record SetTxw(bool On) : BoolCommand(On) { public override string Name => "set_txw"; }
public sealed record SetTxSide(FilterSide Side) : SideCommand(Side) { public override string Name => "set_tx_side"; }
public sealed record SetSquelchType(int Value) : IntCommand(Value) { public override string Name => "set_squelch_type"; }
/// Index into RigCtcssTone.AllValuesHz.
public sealed record SetToneFrequency(int Value) : IntCommand(Value) { public override string Name => "set_tone_freq"; }
/// Index into RigDcsCode.AllValues.
public sealed record SetDcsCode(int Value) : IntCommand(Value) { public override string Name => "set_dcs_code"; }
public sealed record SetRepeaterShift(int Value) : IntCommand(Value) { public override string Name => "set_repeater_shift"; }
public sealed record SetAprsBeaconType(int Value) : IntCommand(Value) { public override string Name => "set_aprs_beacon_type"; }
public sealed record SetFmChannelStep(int Value) : IntCommand(Value) { public override string Name => "set_fm_channel_step"; }

/// One Deep Settings ("EX") item; RawValue is already encoded for the rig.
public sealed record SetMenuItem(int P1, int P2, int P3, string RawValue) : RigCommand
{
    public override string Name => "set_menu_item";
    public override JsonNode? WireValue => new JsonObject
    {
        ["p1"] = P1,
        ["p2"] = P2,
        ["p3"] = P3,
        ["rawValue"] = RawValue,
    };
}

/// true: enter Memory mode on MAIN; false: back to VFO.
public sealed record SetVfoMemoryMode(bool On) : BoolCommand(On) { public override string Name => "set_vfo_memory_mode"; }
public sealed record SetMemoryChannel(int Value) : IntCommand(Value) { public override string Name => "set_memory_channel"; }
/// On = up.
public sealed record StepMemoryChannel(bool On) : BoolCommand(On) { public override string Name => "step_memory_channel"; }
public sealed record SetSubMemoryChannel(int Value) : IntCommand(Value) { public override string Name => "set_sub_memory_channel"; }
/// On = up.
public sealed record StepSubMemoryChannel(bool On) : BoolCommand(On) { public override string Name => "step_sub_memory_channel"; }

public sealed record RecallMemoryChannel(int Channel, bool Sub) : RigCommand
{
    public override string Name => "recall_memory_channel";
    public override JsonNode? WireValue => new JsonObject { ["channel"] = Channel, ["sub"] = Sub };
}

public enum MemoryScanDirection
{
    Off,
    Up,
    Down,
}

public sealed record SetMemoryScan(MemoryScanDirection Direction, FilterSide Side) : RigCommand
{
    public override string Name => "set_memory_scan";
    public override JsonNode? WireValue => new JsonObject
    {
        ["direction"] = Direction.ToString().ToLowerInvariant(),
        ["side"] = (int)Side,
    };
}

public sealed record RefreshMemoryList : MomentaryCommand { public override string Name => "refresh_memory_list"; }
public sealed record SetAudioChannelsSwapped(bool On) : BoolCommand(On) { public override string Name => "set_audio_channels_swapped"; }
public sealed record SetTransmitEnabled(bool On) : BoolCommand(On) { public override string Name => "set_transmit_enabled"; }

/// RigMode raw values as the wire carries them. Swift's RigMode has C4FM and
/// UNKNOWN on top of this app's RigMode cases.
public static class HubMode
{
    public const string C4fm = "C4FM";
    public const string Unknown = "UNKNOWN";

    public static bool IsKnown(string raw) =>
        raw is C4fm or Unknown || RigModeExtensions.FromRawValue(raw) is not null;
}

/// What a client's text frame turned out to be.
public enum InboundKind
{
    /// A RigCommand this hub knows.
    Command,
    /// `{"type":"read_menu_item"…}` (phase 4).
    MenuItemRead,
    /// `{"type":"cw_keyer"…}` (phase 6).
    CwKeyer,
    /// A well-formed command this hub doesn't know — a newer iPad. Ignored,
    /// as an older Mac hub ignores what it can't decode.
    UnknownCommand,
    /// Not JSON, or a known command with a value of the wrong shape.
    Invalid,
}

public sealed record InboundMessage(InboundKind Kind, RigCommand? Command = null, string? Error = null);

/// Parses and encodes <see cref="RigCommand"/>s. Never throws on bad input:
/// the hub's receive loop has to survive whatever a client sends.
public static class RigCommandWire
{
    private delegate RigCommand Parser(JsonElement? value);

    private static readonly Dictionary<string, Parser> Parsers = Build();

    /// Every command name this hub understands (71, one per Swift case).
    public static IReadOnlyCollection<string> Names => Parsers.Keys;

    private static Dictionary<string, Parser> Build()
    {
        var p = new Dictionary<string, Parser>();
        void Momentary(string name, Func<RigCommand> make) => p[name] = _ => make();
        void Bool(string name, Func<bool, RigCommand> make) => p[name] = v => make(ReadBool(v));
        void Int(string name, Func<int, RigCommand> make) => p[name] = v => make(ReadInt(v));
        void Double(string name, Func<double, RigCommand> make) => p[name] = v => make(ReadDouble(v));
        void Mode(string name, Func<string, RigCommand> make) => p[name] = v => make(ReadMode(v));
        void Side(string name, Func<FilterSide, RigCommand> make) => p[name] = v => make(ReadSide(Value(v)));

        p["set_freq"] = v => new SetFrequency(ReadLong(v));
        p["set_secondary_freq"] = v => new SetSecondaryFrequency(ReadLong(v));
        Momentary("swap_active_vfo", () => new SwapActiveVfo());
        Mode("set_mode", m => new SetMode(m));
        Mode("set_secondary_mode", m => new SetSecondaryMode(m));
        Bool("ptt", b => new SetPtt(b));
        p["set_band"] = v => new SetBand(ReadString(v));
        Double("set_power", d => new SetPowerLevel(d));
        Bool("set_break_in", b => new SetBreakIn(b));
        Bool("set_keyer", b => new SetKeyer(b));
        Int("set_cw_speed", i => new SetCwSpeed(i));
        Int("set_cw_pitch", i => new SetCwPitch(i));
        Int("set_bk_delay", i => new SetBreakInDelay(i));
        Bool("set_cw_spot", b => new SetCwSpot(b));
        Momentary("zero_in", () => new TriggerZeroIn());
        Int("set_moni_level", i => new SetMoniLevel(i));
        Int("select_cw_message_channel", i => new SelectCwMessageChannel(i));
        Bool("set_cw_message_recording", b => new SetCwMessageRecording(b));
        Int("play_cw_message", i => new PlayCwMessage(i));
        Int("play_cw_text_memory", i => new PlayCwTextMemory(i));
        Bool("set_mox", b => new SetMox(b));
        Bool("set_att", b => new SetAtt(b));
        Int("set_preamp", i => new SetPreamp(i));
        Bool("set_tuner", b => new SetTuner(b));
        Momentary("trigger_antenna_tune", () => new TriggerAntennaTune());
        Int("set_display_contrast", i => new SetDisplayContrast(i));
        Int("set_display_dimmer", i => new SetDisplayDimmer(i));
        Double("set_display_level", d => new SetDisplayLevel(d));
        Int("set_display_peak", i => new SetDisplayPeak(i));
        Bool("set_display_marker", b => new SetDisplayMarker(b));
        Int("set_mic_gain", i => new SetMicGain(i));
        Int("set_amc_level", i => new SetAmcLevel(i));
        Bool("set_vox", b => new SetVox(b));
        Int("set_vox_gain", i => new SetVoxGain(i));
        Int("set_vox_delay", i => new SetVoxDelay(i));
        Bool("set_dnf", b => new SetDnf(b));
        Int("set_agc", i => new SetAgc(i));
        Bool("set_mic_eq", b => new SetMicEq(b));
        Int("set_proc_level", i => new SetProcLevel(i));
        Int("set_nb_level", i => new SetNbLevel(i));
        Int("set_dnr_level", i => new SetDnrLevel(i));
        Int("set_filter_width", i => new SetFilterWidth(i));
        Int("set_if_shift", i => new SetIfShift(i));
        Bool("set_notch", b => new SetNotch(b));
        Int("set_notch_freq", i => new SetNotchFrequency(i));
        Bool("set_contour", b => new SetContour(b));
        Int("set_contour_freq", i => new SetContourFrequency(i));
        Bool("set_apf", b => new SetApf(b));
        Int("set_apf_offset", i => new SetApfOffset(i));
        Bool("set_narrow", b => new SetNarrow(b));
        Side("set_filter_side", s => new SetFilterSide(s));
        Int("set_ant_select", i => new SetAntSelect(i));
        Bool("set_txw", b => new SetTxw(b));
        Side("set_tx_side", s => new SetTxSide(s));
        Int("set_squelch_type", i => new SetSquelchType(i));
        Int("set_tone_freq", i => new SetToneFrequency(i));
        Int("set_dcs_code", i => new SetDcsCode(i));
        Int("set_repeater_shift", i => new SetRepeaterShift(i));
        Int("set_aprs_beacon_type", i => new SetAprsBeaconType(i));
        Int("set_fm_channel_step", i => new SetFmChannelStep(i));
        p["set_menu_item"] = v =>
        {
            var o = Object(v);
            return new SetMenuItem(ReadInt(Field(o, "p1")), ReadInt(Field(o, "p2")), ReadInt(Field(o, "p3")),
                ReadString(Field(o, "rawValue")));
        };
        Bool("set_vfo_memory_mode", b => new SetVfoMemoryMode(b));
        Int("set_memory_channel", i => new SetMemoryChannel(i));
        Bool("step_memory_channel", b => new StepMemoryChannel(b));
        Int("set_sub_memory_channel", i => new SetSubMemoryChannel(i));
        Bool("step_sub_memory_channel", b => new StepSubMemoryChannel(b));
        p["recall_memory_channel"] = v =>
        {
            var o = Object(v);
            return new RecallMemoryChannel(ReadInt(Field(o, "channel")), ReadBool(Field(o, "sub")));
        };
        p["set_memory_scan"] = v =>
        {
            var o = Object(v);
            var direction = ReadString(Field(o, "direction")) switch
            {
                "off" => MemoryScanDirection.Off,
                "up" => MemoryScanDirection.Up,
                "down" => MemoryScanDirection.Down,
                var other => throw new FormatException($"unknown scan direction \"{other}\""),
            };
            return new SetMemoryScan(direction, ReadSide(Field(o, "side")));
        };
        Momentary("refresh_memory_list", () => new RefreshMemoryList());
        Bool("set_audio_channels_swapped", b => new SetAudioChannelsSwapped(b));
        Bool("set_transmit_enabled", b => new SetTransmitEnabled(b));
        return p;
    }

    /// Classifies one text frame. A `"type"` field marks the request/reply
    /// messages kept beside RigCommand (as the Mac's server tries them
    /// first); anything else is a command.
    public static InboundMessage ParseInbound(string text)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(text);
        }
        catch (JsonException ex)
        {
            return new InboundMessage(InboundKind.Invalid, Error: $"not JSON: {ex.Message}");
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return new InboundMessage(InboundKind.Invalid, Error: "not a JSON object");
            }
            if (root.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String)
            {
                return type.GetString() switch
                {
                    "read_menu_item" => new InboundMessage(InboundKind.MenuItemRead),
                    "cw_keyer" => new InboundMessage(InboundKind.CwKeyer),
                    var other => new InboundMessage(InboundKind.Invalid, Error: $"unknown message type \"{other}\""),
                };
            }
            if (!root.TryGetProperty("cmd", out var cmd) || cmd.ValueKind != JsonValueKind.String)
            {
                return new InboundMessage(InboundKind.Invalid, Error: "no \"cmd\"");
            }
            var name = cmd.GetString()!;
            if (!Parsers.TryGetValue(name, out var parse))
            {
                return new InboundMessage(InboundKind.UnknownCommand, Error: $"unknown command \"{name}\"");
            }
            JsonElement? value = root.TryGetProperty("value", out var v) ? v : null;
            try
            {
                return new InboundMessage(InboundKind.Command, parse(value));
            }
            catch (Exception ex) when (ex is FormatException or InvalidOperationException or OverflowException or KeyNotFoundException)
            {
                return new InboundMessage(InboundKind.Invalid, Error: $"{name}: bad value: {ex.Message}");
            }
        }
    }

    /// The command as Swift's encoder writes it: `{"cmd":…,"value":…}`, with
    /// no "value" for the momentary ones.
    public static string Serialize(RigCommand command)
    {
        var o = new JsonObject { ["cmd"] = command.Name };
        if (command.WireValue is { } value)
        {
            o["value"] = value;
        }
        return o.ToJsonString();
    }

    private static JsonElement Value(JsonElement? v) =>
        v is { ValueKind: not JsonValueKind.Null } e ? e : throw new FormatException("missing value");

    private static JsonElement Object(JsonElement? v)
    {
        var e = Value(v);
        return e.ValueKind == JsonValueKind.Object ? e : throw new FormatException("expected an object");
    }

    private static JsonElement Field(JsonElement o, string name) =>
        o.TryGetProperty(name, out var f) ? f : throw new FormatException($"missing \"{name}\"");

    private static bool ReadBool(JsonElement? v) => Value(v).ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new FormatException("expected true/false"),
    };

    private static int ReadInt(JsonElement? v) =>
        Value(v) is { ValueKind: JsonValueKind.Number } e && e.TryGetInt32(out var i) ? i : throw new FormatException("expected an integer");

    private static long ReadLong(JsonElement? v) =>
        Value(v) is { ValueKind: JsonValueKind.Number } e && e.TryGetInt64(out var l) ? l : throw new FormatException("expected an integer");

    private static double ReadDouble(JsonElement? v)
    {
        var e = Value(v);
        return e.ValueKind == JsonValueKind.Number && e.TryGetDouble(out var d) && double.IsFinite(d)
            ? d
            : throw new FormatException("expected a number");
    }

    private static string ReadString(JsonElement? v) =>
        Value(v) is { ValueKind: JsonValueKind.String } e ? e.GetString()! : throw new FormatException("expected a string");

    private static string ReadMode(JsonElement? v)
    {
        var raw = ReadString(v);
        return HubMode.IsKnown(raw) ? raw : throw new FormatException($"unknown mode \"{raw}\"");
    }

    private static FilterSide ReadSide(JsonElement e) =>
        e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out var i) && i is 0 or 1
            ? (FilterSide)i
            : throw new FormatException("expected a side, 0 or 1");
}
