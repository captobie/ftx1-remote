using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The hub's command path (phase 2): every RigCommand the iPad sends, as the
/// Swift encoder wrote it into Tests/WireFixtures/rig-commands.json, parses
/// to the expected C# command and re-encodes to the same JSON; bad frames
/// are classified rather than thrown; and the dispatcher's gate and
/// memory-scan decisions (HubCommandPolicy).
public class HubCommandTests
{
    /// Wire name → C# type, one per Swift RigCommand case.
    private static readonly Dictionary<string, Type> ExpectedTypes = new()
    {
        ["set_freq"] = typeof(SetFrequency),
        ["set_secondary_freq"] = typeof(SetSecondaryFrequency),
        ["swap_active_vfo"] = typeof(SwapActiveVfo),
        ["set_mode"] = typeof(SetMode),
        ["set_secondary_mode"] = typeof(SetSecondaryMode),
        ["ptt"] = typeof(SetPtt),
        ["set_band"] = typeof(SetBand),
        ["set_power"] = typeof(SetPowerLevel),
        ["set_break_in"] = typeof(SetBreakIn),
        ["set_keyer"] = typeof(SetKeyer),
        ["set_cw_speed"] = typeof(SetCwSpeed),
        ["set_cw_pitch"] = typeof(SetCwPitch),
        ["set_bk_delay"] = typeof(SetBreakInDelay),
        ["set_cw_spot"] = typeof(SetCwSpot),
        ["zero_in"] = typeof(TriggerZeroIn),
        ["set_moni_level"] = typeof(SetMoniLevel),
        ["select_cw_message_channel"] = typeof(SelectCwMessageChannel),
        ["set_cw_message_recording"] = typeof(SetCwMessageRecording),
        ["play_cw_message"] = typeof(PlayCwMessage),
        ["play_cw_text_memory"] = typeof(PlayCwTextMemory),
        ["set_mox"] = typeof(SetMox),
        ["set_att"] = typeof(SetAtt),
        ["set_preamp"] = typeof(SetPreamp),
        ["set_tuner"] = typeof(SetTuner),
        ["trigger_antenna_tune"] = typeof(TriggerAntennaTune),
        ["set_display_contrast"] = typeof(SetDisplayContrast),
        ["set_display_dimmer"] = typeof(SetDisplayDimmer),
        ["set_display_level"] = typeof(SetDisplayLevel),
        ["set_display_peak"] = typeof(SetDisplayPeak),
        ["set_display_marker"] = typeof(SetDisplayMarker),
        ["set_mic_gain"] = typeof(SetMicGain),
        ["set_amc_level"] = typeof(SetAmcLevel),
        ["set_vox"] = typeof(SetVox),
        ["set_vox_gain"] = typeof(SetVoxGain),
        ["set_vox_delay"] = typeof(SetVoxDelay),
        ["set_dnf"] = typeof(SetDnf),
        ["set_agc"] = typeof(SetAgc),
        ["set_mic_eq"] = typeof(SetMicEq),
        ["set_proc_level"] = typeof(SetProcLevel),
        ["set_nb_level"] = typeof(SetNbLevel),
        ["set_dnr_level"] = typeof(SetDnrLevel),
        ["set_filter_width"] = typeof(SetFilterWidth),
        ["set_if_shift"] = typeof(SetIfShift),
        ["set_notch"] = typeof(SetNotch),
        ["set_notch_freq"] = typeof(SetNotchFrequency),
        ["set_contour"] = typeof(SetContour),
        ["set_contour_freq"] = typeof(SetContourFrequency),
        ["set_apf"] = typeof(SetApf),
        ["set_apf_offset"] = typeof(SetApfOffset),
        ["set_narrow"] = typeof(SetNarrow),
        ["set_filter_side"] = typeof(SetFilterSide),
        ["set_ant_select"] = typeof(SetAntSelect),
        ["set_txw"] = typeof(SetTxw),
        ["set_tx_side"] = typeof(SetTxSide),
        ["set_squelch_type"] = typeof(SetSquelchType),
        ["set_tone_freq"] = typeof(SetToneFrequency),
        ["set_dcs_code"] = typeof(SetDcsCode),
        ["set_repeater_shift"] = typeof(SetRepeaterShift),
        ["set_aprs_beacon_type"] = typeof(SetAprsBeaconType),
        ["set_fm_channel_step"] = typeof(SetFmChannelStep),
        ["set_menu_item"] = typeof(SetMenuItem),
        ["set_vfo_memory_mode"] = typeof(SetVfoMemoryMode),
        ["set_memory_channel"] = typeof(SetMemoryChannel),
        ["step_memory_channel"] = typeof(StepMemoryChannel),
        ["set_sub_memory_channel"] = typeof(SetSubMemoryChannel),
        ["step_sub_memory_channel"] = typeof(StepSubMemoryChannel),
        ["recall_memory_channel"] = typeof(RecallMemoryChannel),
        ["set_memory_scan"] = typeof(SetMemoryScan),
        ["refresh_memory_list"] = typeof(RefreshMemoryList),
        ["set_audio_channels_swapped"] = typeof(SetAudioChannelsSwapped),
        ["set_transmit_enabled"] = typeof(SetTransmitEnabled),
    };

    private static List<JsonElement> FixtureCommands()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(HubWireTests.FixturesDir, "rig-commands.json")));
        return doc.RootElement.EnumerateArray().Select(e => e.Clone()).ToList();
    }

    public static IEnumerable<object[]> FixtureCommandNames() =>
        FixtureCommands().Select(e => new object[] { e.GetProperty("cmd").GetString()! });

    [Fact]
    public void FixtureHasEveryCommandOnce()
    {
        var names = FixtureCommands().Select(e => e.GetProperty("cmd").GetString()!).ToList();
        Assert.Equal(71, names.Count);
        Assert.Equal(names.Count, names.Distinct().Count());
        Assert.Equal(ExpectedTypes.Keys.Order(), names.Order());
        Assert.Equal(ExpectedTypes.Keys.Order(), RigCommandWire.Names.Order());
    }

    [Theory]
    [MemberData(nameof(FixtureCommandNames))]
    public void FixtureCommandParsesAndRoundTrips(string name)
    {
        var original = FixtureCommands().Single(e => e.GetProperty("cmd").GetString() == name);
        var inbound = RigCommandWire.ParseInbound(original.GetRawText());
        Assert.Equal(InboundKind.Command, inbound.Kind);
        var command = Assert.IsAssignableFrom<RigCommand>(inbound.Command);
        Assert.Equal(ExpectedTypes[name], command.GetType());
        Assert.Equal(name, command.Name);

        using var reencoded = JsonDocument.Parse(RigCommandWire.Serialize(command));
        HubWireTests.AssertJsonEqual(original, reencoded.RootElement, name);
    }

    [Fact]
    public void FixtureValuesLandInTheRightFields()
    {
        var byName = FixtureCommands().ToDictionary(e => e.GetProperty("cmd").GetString()!,
            e => RigCommandWire.ParseInbound(e.GetRawText()).Command);
        Assert.Equal(new SetFrequency(14_074_000), byName["set_freq"]);
        Assert.Equal(new SetSecondaryFrequency(146_940_000), byName["set_secondary_freq"]);
        Assert.Equal(new SetMode("PKTUSB"), byName["set_mode"]);
        Assert.Equal(new SetSecondaryMode(HubMode.C4fm), byName["set_secondary_mode"]);
        Assert.Equal(new SetPtt(true), byName["ptt"]);
        Assert.Equal(new SetBand("20m"), byName["set_band"]);
        Assert.Equal(new SetPowerLevel(0.25), byName["set_power"]);
        Assert.Equal(new SetDisplayLevel(-5.5), byName["set_display_level"]);
        Assert.Equal(new SetIfShift(-120), byName["set_if_shift"]);
        Assert.Equal(new SetFilterSide(FilterSide.Sub), byName["set_filter_side"]);
        Assert.Equal(new SetTxSide(FilterSide.Sub), byName["set_tx_side"]);
        Assert.Equal(new SetMenuItem(6, 1, 3, "1"), byName["set_menu_item"]);
        Assert.Equal(new RecallMemoryChannel(278, true), byName["recall_memory_channel"]);
        Assert.Equal(new SetMemoryScan(MemoryScanDirection.Up, FilterSide.Main), byName["set_memory_scan"]);
        Assert.Equal(new StepSubMemoryChannel(false), byName["step_sub_memory_channel"]);
        Assert.Equal(new SetTransmitEnabled(false), byName["set_transmit_enabled"]);
    }

    [Theory]
    [InlineData("""{"cmd":"set_freq","value":14074000}""")]
    [InlineData("""{"cmd":"swap_active_vfo","value":null}""")]
    [InlineData("""{"cmd":"set_memory_scan","value":{"direction":"off","side":1}}""")]
    [InlineData("""{"cmd":"set_mode","value":"UNKNOWN"}""")]
    [InlineData("""{"cmd":"set_power","value":1}""")]
    public void AcceptsOtherWellFormedCommands(string json) =>
        Assert.Equal(InboundKind.Command, RigCommandWire.ParseInbound(json).Kind);

    [Fact]
    public void UnknownCommandIsIgnoredNotInvalid()
    {
        var inbound = RigCommandWire.ParseInbound("""{"cmd":"set_hologram","value":true}""");
        Assert.Equal(InboundKind.UnknownCommand, inbound.Kind);
        Assert.Null(inbound.Command);
        Assert.Contains("set_hologram", inbound.Error);
    }

    [Theory]
    [InlineData("""{"cmd":"set_freq","value":"14074000"}""")]
    [InlineData("""{"cmd":"set_freq","value":14074000.5}""")]
    [InlineData("""{"cmd":"set_freq"}""")]
    [InlineData("""{"cmd":"set_cw_speed","value":99999999999}""")]
    [InlineData("""{"cmd":"set_mode","value":"WFM"}""")]
    [InlineData("""{"cmd":"set_mode","value":3}""")]
    [InlineData("""{"cmd":"ptt","value":1}""")]
    [InlineData("""{"cmd":"ptt","value":null}""")]
    [InlineData("""{"cmd":"set_filter_side","value":2}""")]
    [InlineData("""{"cmd":"set_tx_side","value":"sub"}""")]
    [InlineData("""{"cmd":"set_power","value":"high"}""")]
    [InlineData("""{"cmd":"set_menu_item","value":{"p1":6,"p2":1,"rawValue":"1"}}""")]
    [InlineData("""{"cmd":"set_menu_item","value":[6,1,3,"1"]}""")]
    [InlineData("""{"cmd":"recall_memory_channel","value":{"channel":278,"sub":"yes"}}""")]
    [InlineData("""{"cmd":"set_memory_scan","value":{"direction":"sideways","side":0}}""")]
    [InlineData("""{"cmd":"set_memory_scan","value":{"direction":"up"}}""")]
    [InlineData("""{"cmd":42}""")]
    [InlineData("""{"value":true}""")]
    [InlineData("""{"type":"bogus"}""")]
    [InlineData("""[1,2,3]""")]
    [InlineData("""not json""")]
    [InlineData("")]
    [InlineData("""{"cmd":"set_freq","value":1""")]
    public void BadFramesAreInvalidWithoutThrowing(string json)
    {
        var inbound = RigCommandWire.ParseInbound(json);
        Assert.Equal(InboundKind.Invalid, inbound.Kind);
        Assert.Null(inbound.Command);
        Assert.False(string.IsNullOrEmpty(inbound.Error));
    }

    /// The iPad sends commands as binary frames of JSON; only a
    /// 0x02-tagged binary frame with audio after the tag is TX audio.
    [Fact]
    public void BinaryJsonIsACommandAndOnlyTaggedFramesAreAudio()
    {
        var json = System.Text.Encoding.UTF8.GetBytes("""{"cmd":"set_transmit_enabled","value":false}""");
        Assert.False(RigCommandWire.IsTxAudioFrame(json));
        Assert.Equal(new SetTransmitEnabled(false),
            RigCommandWire.ParseInbound(System.Text.Encoding.UTF8.GetString(json)).Command);
        Assert.True(RigCommandWire.IsTxAudioFrame(new byte[] { 0x02, 0x10, 0x00 }));
        Assert.False(RigCommandWire.IsTxAudioFrame(new byte[] { 0x02 }));
        Assert.False(RigCommandWire.IsTxAudioFrame(new byte[] { 0x00, 0x10, 0x00 }));
        Assert.False(RigCommandWire.IsTxAudioFrame([]));
    }

    [Fact]
    public void RequestMessagesAreRecognized()
    {
        Assert.Equal(InboundKind.MenuItemRead,
            RigCommandWire.ParseInbound("""{"type":"read_menu_item","p1":6,"p2":1,"p3":3}""").Kind);
        Assert.Equal(InboundKind.CwKeyer,
            RigCommandWire.ParseInbound("""{"type":"cw_keyer","id":7,"slot":1,"text":"CQ"}""").Kind);
    }

    // Gates (HubCommandPolicy.RefusalReason). 14.074 MHz is in 20 m;
    // 15 MHz (WWV) is outside every amateur band.

    private const long InBand = 14_074_000;
    private const long OutOfBand = 15_000_000;

    // Phase 5: PTT on goes through the transmit gate like MOX.
    [Fact]
    public void PttOnIsGatedByEnableTransmitAndBand()
    {
        Assert.Null(HubCommandPolicy.RefusalReason(new SetPtt(true), true, InBand));
        Assert.Equal("Transmit disabled", HubCommandPolicy.RefusalReason(new SetPtt(true), false, InBand));
        Assert.Equal("Transmit disabled: outside an amateur band", HubCommandPolicy.RefusalReason(new SetPtt(true), true, OutOfBand));
        Assert.Equal(TransmitAction.PttOn, HubCommandPolicy.TransmitActionFor(new SetPtt(true)));
        Assert.Equal(HubScanStop.Keep, HubCommandPolicy.MemoryScanStop(new SetPtt(true), scanSub: true));
    }

    [Theory]
    [MemberData(nameof(UnkeyCommands))]
    public void UnkeyingIsNeverGated(RigCommand command)
    {
        Assert.Null(HubCommandPolicy.RefusalReason(command, transmitEnabled: false, OutOfBand));
        Assert.Null(HubCommandPolicy.TransmitActionFor(command));
    }

    public static IEnumerable<object[]> UnkeyCommands() =>
    [
        [new SetPtt(false)],
        [new SetMox(false)],
        [new PlayCwTextMemory(0)],
        [new PlayCwMessage(0)],
    ];

    [Theory]
    [MemberData(nameof(KeyingCommands))]
    public void KeyingCommandsFollowTheTransmitGate(RigCommand command)
    {
        Assert.NotNull(HubCommandPolicy.TransmitActionFor(command));
        Assert.Equal("Transmit disabled", HubCommandPolicy.RefusalReason(command, transmitEnabled: false, InBand));
        Assert.Equal("Transmit disabled: outside an amateur band",
            HubCommandPolicy.RefusalReason(command, transmitEnabled: true, OutOfBand));
        // Before the first poll MAIN reads 0, outside every band.
        Assert.NotNull(HubCommandPolicy.RefusalReason(command, transmitEnabled: true, 0));
        Assert.Null(HubCommandPolicy.RefusalReason(command, transmitEnabled: true, InBand));
    }

    public static IEnumerable<object[]> KeyingCommands() =>
    [
        [new SetMox(true)],
        [new TriggerAntennaTune()],
        [new PlayCwTextMemory(1)],
        [new PlayCwMessage(3)],
    ];

    [Theory]
    [MemberData(nameof(SettingsCommands))]
    public void SettingsAreNotGatedByTransmit(RigCommand command) =>
        Assert.Null(HubCommandPolicy.RefusalReason(command, transmitEnabled: false, OutOfBand));

    public static IEnumerable<object[]> SettingsCommands() =>
    [
        [new SetFrequency(InBand)],
        [new SetMode("CW")],
        [new SetMode(HubMode.C4fm)],
        [new SetBand("2m")],
        [new SetPowerLevel(0.05)],
        [new SetTuner(true)],
        [new SetBreakIn(true)],
        [new SetBreakInDelay(300)],
        [new SetMenuItem(6, 1, 3, "1")],
        [new SwapActiveVfo()],
        [new SetMemoryScan(MemoryScanDirection.Up, FilterSide.Sub)],
    ];

    [Theory]
    [MemberData(nameof(BadValues))]
    public void ValuesTheRigShouldNotGetAreRefused(RigCommand command) =>
        Assert.NotNull(HubCommandPolicy.RefusalReason(command, transmitEnabled: true, InBand));

    public static IEnumerable<object[]> BadValues() =>
    [
        [new SetFrequency(0)],
        [new SetMode(HubMode.Unknown)],
        [new SetSecondaryMode(HubMode.Unknown)],
        [new SetBand("SW 41m")],
        [new SetPowerLevel(1.5)],
        [new SetBreakInDelay(301)],
        [new SetVoxDelay(-5)],
        [new SetCwSpeed(99)],
        [new SetCwPitch(705)],
        [new SetProcLevel(-1)],
        [new SetToneFrequency(50)],
        [new SetDisplayLevel(31)],
        [new PlayCwTextMemory(9)],
        [new SetMenuItem(6, 1, 3, "1;MX1")],
        [new SetMenuItem(6, 1, 3, "")],
        [new SetMenuItem(100, 1, 3, "1")],
        [new RecallMemoryChannel(0, false)],
    ];

    // Memory-scan stop-before (HubCommandPolicy.MemoryScanStop), the Mac's
    // memoryScanStop(for:scanSide:).

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void TuningTheActiveSideStopsEitherScanAndRestoresTx(bool scanSub)
    {
        foreach (var command in new RigCommand[]
                 {
                     new SetFrequency(InBand), new SetMode("USB"), new SetBand("20m"), new SwapActiveVfo(),
                     new StepMemoryChannel(true),
                 })
        {
            Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(command, scanSub));
        }
    }

    [Fact]
    public void SideCommandsStopOnlyTheirOwnSidesScan()
    {
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new SetVfoMemoryMode(false), scanSub: false));
        Assert.Null(HubCommandPolicy.MemoryScanStop(new SetVfoMemoryMode(false), scanSub: true));
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new SetMemoryChannel(2), scanSub: false));
        Assert.Null(HubCommandPolicy.MemoryScanStop(new SetMemoryChannel(2), scanSub: true));
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new SetSecondaryFrequency(InBand), scanSub: true));
        Assert.Null(HubCommandPolicy.MemoryScanStop(new SetSecondaryFrequency(InBand), scanSub: false));
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new SetSecondaryMode("FM"), scanSub: true));
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new StepSubMemoryChannel(true), scanSub: true));
        Assert.Null(HubCommandPolicy.MemoryScanStop(new SetSubMemoryChannel(5), scanSub: false));
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new RecallMemoryChannel(5, true), scanSub: true));
        Assert.Null(HubCommandPolicy.MemoryScanStop(new RecallMemoryChannel(5, true), scanSub: false));
        Assert.Equal(HubScanStop.Restore, HubCommandPolicy.MemoryScanStop(new RecallMemoryChannel(5, false), scanSub: false));
    }

    [Fact]
    public void TransmittingStopsTheScanButKeepsTheTxSide()
    {
        Assert.Equal(HubScanStop.Keep, HubCommandPolicy.MemoryScanStop(new SetMox(true), scanSub: true));
        Assert.Equal(HubScanStop.Keep, HubCommandPolicy.MemoryScanStop(new TriggerAntennaTune(), scanSub: false));
        Assert.Equal(HubScanStop.Keep, HubCommandPolicy.MemoryScanStop(new PlayCwTextMemory(1), scanSub: false));
    }

    [Fact]
    public void SettingsLeaveTheScanRunning()
    {
        foreach (var command in new RigCommand[]
                 {
                     new SetAtt(true), new SetMox(false), new SetPtt(false), new SetFilterWidth(9), new SetFilterSide(FilterSide.Sub),
                     new SetMenuItem(6, 1, 3, "1"), new SetTxSide(FilterSide.Main), new SetPowerLevel(0.5),
                     new SetMemoryScan(MemoryScanDirection.Off, FilterSide.Main), new PlayCwTextMemory(0),
                 })
        {
            Assert.Null(HubCommandPolicy.MemoryScanStop(command, scanSub: false));
            Assert.Null(HubCommandPolicy.MemoryScanStop(command, scanSub: true));
        }
    }
}
