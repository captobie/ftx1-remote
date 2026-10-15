using System.Threading.Channels;
using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.Hub;

/// What the dispatcher drives: MainWindow (MainWindow.Hub.cs), through the
/// same methods its own controls use, plus the MENU grid's and the Filter
/// rows' public setters. Everything here runs on the UI thread.
public interface IHubRigHost
{
    RigctldClient? Client { get; }
    bool TransmitEnabled { get; }
    /// MAIN's frequency, which every transmit gate checks.
    long MainFrequencyHz { get; }
    bool MemoryScanActive { get; }
    bool MemoryScanSub { get; }
    MenuGrid Menu { get; }
    FilterPanel Filter { get; }

    Task StopMemoryScanAsync(HubScanStop stop);
    Task SetMainFrequencyAsync(long hz);
    Task SetSubFrequencyAsync(long hz);
    Task SwapVfoAsync();
    Task SetMainModeAsync(RigMode mode);
    Task SetMainModeC4fmAsync();
    Task SetSubModeAsync(RigMode? mode, bool c4fm);
    Task SetBandAsync(Band band);
    Task SendPttOffAsync();
    Task SetPowerLevelAsync(double level);
    Task SetTxSideAsync(bool sub);
    Task SetVfoMemoryModeAsync(bool memory);
    Task SetMemoryChannelAsync(bool sub, int channel);
    Task StepMemoryChannelAsync(bool sub, bool up);
    Task RecallMemoryChannelAsync(int channel, bool sub);
    Task StartMemoryScanAsync(bool sub, bool up);
    Task StopMemoryScanFromButtonAsync();
    Task SetTransmitEnabledAsync(bool enabled);
    void SetAudioChannelsSwapped(bool swapped);
}

/// Runs the iPad's commands (Apps/Windows/README.md, "Desktop hub for the
/// iPad", phase 2): one FIFO for every client, as the Mac's
/// RigWebSocketServer orders everything through one stream, each command
/// run to completion on the UI thread before the next. Each goes through
/// the code the Windows window uses for the same action, so the window
/// shows what the iPad changed and the two can't drift apart; where this
/// app has no such control, the Mac's HubService/CommandQueue behaviour.
///
/// Before a command runs: the transmit gate and value checks
/// (HubCommandPolicy.RefusalReason), then the memory-scan stop-before rule
/// (HubCommandPolicy.MemoryScanStop, through MainWindow's own scan stop).
/// Refused and unmapped commands are logged ("hub: …") and dropped.
public sealed class RigCommandDispatcher(IHubRigHost host)
{
    /// Deep enough for a burst of slider releases; a client that floods
    /// past it has its commands dropped (logged) rather than the receive
    /// loop blocking.
    private const int QueueLimit = 256;

    private readonly Channel<(int ClientId, RigCommand Command)> _queue = Channel.CreateBounded<(int, RigCommand)>(
        new BoundedChannelOptions(QueueLimit) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });

    /// From the hub's receive loops, on any thread.
    public void Enqueue(int clientId, RigCommand command)
    {
        if (!_queue.Writer.TryWrite((clientId, command)))
        {
            AppLog.Write($"hub: client {clientId}: {command} dropped (command queue full)");
        }
    }

    /// The FIFO. Start once, on the UI thread: its awaits resume there.
    public async Task RunAsync()
    {
        await foreach (var (clientId, command) in _queue.Reader.ReadAllAsync())
        {
            try
            {
                await ExecuteAsync(clientId, command);
            }
            catch (Exception ex)
            {
                AppLog.Write($"hub: client {clientId}: {command} failed: {ex.Message}");
            }
        }
    }

    private async Task ExecuteAsync(int clientId, RigCommand command)
    {
        void Log(string message) => AppLog.Write($"hub: client {clientId}: {command} — {message}");

        // The hub's own settings: no rig needed.
        switch (command)
        {
            case SetTransmitEnabled t:
                Log($"Enable Transmit {(t.On ? "on" : "off")}");
                await host.SetTransmitEnabledAsync(t.On);
                return;
            case SetAudioChannelsSwapped s:
                Log("audio channel override");
                host.SetAudioChannelsSwapped(s.On);
                return;
            case RefreshMemoryList:
                Log("ignored (the memory list arrives in phase 4)");
                return;
        }

        if (HubCommandPolicy.RefusalReason(command, host.TransmitEnabled, host.MainFrequencyHz) is { } reason)
        {
            Log($"refused: {reason}");
            return;
        }
        if (host.Client is not { } client)
        {
            Log("dropped: not connected to the rig");
            return;
        }
        AppLog.Write($"hub: client {clientId}: {command}");
        if (host.MemoryScanActive && HubCommandPolicy.MemoryScanStop(command, host.MemoryScanSub) is { } stop)
        {
            await host.StopMemoryScanAsync(stop);
        }

        var menu = host.Menu;
        var filter = host.Filter;
        switch (command)
        {
            // VFOs, mode, band, power
            case SetFrequency c: await host.SetMainFrequencyAsync(c.Hz); break;
            case SetSecondaryFrequency c: await host.SetSubFrequencyAsync(c.Hz); break;
            case SwapActiveVfo: await host.SwapVfoAsync(); break;
            case SetMode { Mode: HubMode.C4fm }: await host.SetMainModeC4fmAsync(); break;
            case SetMode c: await host.SetMainModeAsync(RigModeExtensions.FromRawValue(c.Mode)!.Value); break;
            case SetSecondaryMode c: await host.SetSubModeAsync(RigModeExtensions.FromRawValue(c.Mode), c.Mode == HubMode.C4fm); break;
            case SetBand c: await host.SetBandAsync(BandPlan.BandNamed(c.Band)!); break;
            // PTT on is refused above (HubCommandPolicy.PttNotYet).
            case SetPtt: await host.SendPttOffAsync(); break;
            case SetPowerLevel c: await host.SetPowerLevelAsync(c.Value); break;
            case SetTxSide c: await host.SetTxSideAsync(c.Side == FilterSide.Sub); break;

            // MENU grid, SSB page
            case SetDisplayLevel c: await menu.SetDisplayLevelAsync(c.Value); break;
            case SetDisplayPeak c: await menu.SetDisplayPeakAsync(c.Value); break;
            case SetDisplayMarker c: await menu.SetDisplayMarkerAsync(c.On); break;
            case SetDisplayContrast c: await menu.SetDisplayContrastAsync(c.Value); break;
            case SetDisplayDimmer c: await menu.SetDisplayDimmerAsync(c.Value); break;
            case SetMox c: await menu.SetMoxAsync(c.On); break;
            case SetAtt c: await menu.SetAttAsync(c.On); break;
            case SetPreamp c: await menu.SetPreampAsync(c.Value); break;
            case SetDnf c: await menu.SetDnfAsync(c.On); break;
            case SetAgc c: await menu.SetAgcAsync(c.Value); break;
            case SetMicEq c: await menu.SetMicEqAsync(c.On); break;
            case SetProcLevel c: await menu.SetProcLevelAsync(c.Value); break;
            case TriggerAntennaTune: await menu.TriggerAntennaTuneAsync(); break;
            case SetTuner c: await menu.SetTunerAsync(c.On); break;
            case SetNbLevel c: await menu.SetNbLevelAsync(c.Value); break;
            case SetDnrLevel c: await menu.SetDnrLevelAsync(c.Value); break;
            case SetAntSelect c: await menu.SetAntSelectAsync(c.Value); break;
            case SetMicGain c: await menu.SetMicGainAsync(c.Value); break;
            case SetAmcLevel c: await menu.SetAmcLevelAsync(c.Value); break;
            case SetVox c: await menu.SetVoxAsync(c.On); break;
            case SetVoxGain c: await menu.SetVoxGainAsync(c.Value); break;
            case SetVoxDelay c: await menu.SetVoxDelayAsync(c.Value); break;
            // TXW is a disabled placeholder in both grids; the Mac sends
            // the bare "TS", and so does this.
            case SetTxw c: await client.SetRawBoolAsync("TS", c.On); break;

            // MENU grid, CW page
            case SetMoniLevel c: await menu.SetMoniLevelAsync(c.Value); break;
            case SetKeyer c: await menu.SetKeyerAsync(c.On); break;
            case SetBreakIn c: await menu.SetBreakInAsync(c.On); break;
            case SetCwSpeed c: await menu.SetCwSpeedAsync(c.Value); break;
            case SetCwPitch c: await menu.SetCwPitchAsync(c.Value); break;
            case SetBreakInDelay c: await menu.SetBreakInDelayAsync(c.Value); break;
            case TriggerZeroIn: await menu.TriggerZeroInAsync(); break;
            case SetCwSpot c: await menu.SetCwSpotAsync(c.On); break;
            // CW MESSAGE memory: a disabled placeholder in every grid, so no
            // client sends these today; the Mac's CommandQueue mapping. The
            // play is gated above, and the scan was stopped (Keep).
            case SelectCwMessageChannel c: await client.SetRawIntAsync("LM0", c.Value, 1); break;
            case SetCwMessageRecording c: await client.SetRawBoolAsync("LM1", c.On); break;
            case PlayCwMessage c: await client.SetRawIntAsync("KY1", c.Value, 1); break;
            // The CW send pane's own "KY0n" (CwSender). The keyer memory
            // write that goes before it is cw_keyer, phase 6.
            case PlayCwTextMemory c: await client.SetRawIntAsync("KY0", c.Value, 1); break;

            // MENU grid, FM page
            case SetRepeaterShift c: await menu.SetRepeaterShiftAsync(c.Value); break;
            case SetAprsBeaconType c: await menu.SetAprsBeaconTypeAsync(c.Value); break;
            case SetFmChannelStep c: await menu.SetFmChannelStepAsync(c.Value); break;
            case SetSquelchType c: await menu.SetSquelchTypeAsync(c.Value); break;
            case SetToneFrequency c: await menu.SetToneIndexAsync(c.Value); break;
            case SetDcsCode c: await menu.SetDcsIndexAsync(c.Value); break;
            // Deep Settings: the dialog's own write (DeepSettingsDialog).
            case SetMenuItem c: await client.SetMenuItemAsync(c.P1, c.P2, c.P3, c.RawValue); break;

            // Filter rows
            case SetFilterWidth c: await filter.SetWidthAsync(c.Value); break;
            case SetIfShift c: await filter.SetShiftAsync(c.Value); break;
            case SetNotch c: await filter.SetNotchAsync(c.On); break;
            case SetNotchFrequency c: await filter.SetNotchFrequencyAsync(c.Value); break;
            case SetContour c: await filter.SetContourAsync(c.On); break;
            case SetContourFrequency c: await filter.SetContourFrequencyAsync(c.Value); break;
            case SetApf c: await filter.SetApfAsync(c.On); break;
            case SetApfOffset c: await filter.SetApfOffsetAsync(c.Value); break;
            case SetNarrow c: await filter.SetNarrowAsync(c.On); break;
            case SetFilterSide c:
                if (!filter.SelectSide(c.Side))
                {
                    Log("refused: SUB isn't shown in single-receive display");
                }
                break;

            // Memory channels and scan
            case SetVfoMemoryMode c: await host.SetVfoMemoryModeAsync(c.On); break;
            case SetMemoryChannel c: await host.SetMemoryChannelAsync(sub: false, c.Value); break;
            case SetSubMemoryChannel c: await host.SetMemoryChannelAsync(sub: true, c.Value); break;
            case StepMemoryChannel c: await host.StepMemoryChannelAsync(sub: false, up: c.On); break;
            case StepSubMemoryChannel c: await host.StepMemoryChannelAsync(sub: true, up: c.On); break;
            case RecallMemoryChannel c: await host.RecallMemoryChannelAsync(c.Channel, c.Sub); break;
            case SetMemoryScan { Direction: MemoryScanDirection.Off }: await host.StopMemoryScanFromButtonAsync(); break;
            // Also the iPad's Skip: the same scan again resumes past a busy
            // channel (the Mac sends it the same way).
            case SetMemoryScan c: await host.StartMemoryScanAsync(c.Side == FilterSide.Sub, c.Direction == MemoryScanDirection.Up); break;

            default:
                Log("ignored: no mapping on Windows");
                break;
        }
    }
}
