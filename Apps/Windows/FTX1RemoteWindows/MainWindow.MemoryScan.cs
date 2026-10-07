using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FTX1RemoteWindows;

/// The rig's own memory scan on MAIN or SUB — the Mac's (CLAUDE.md "Memory
/// scan"; HubService's memoryScanTick/publishMemoryScanStop/send). What the
/// 2026-10-06 probes found, which all of this follows:
///  - "SC<side><n>" (n 0 off, 1 up, 2 down) is a memory scan in Memory
///    mode (a VFO scan in VFO mode, so it's only offered in Memory mode).
///  - "RI0" P7 is the scan state for the whole radio, SUB included.
///  - Both sides can scan at once, but any stop stops both, so the app runs
///    one side at a time (user decision).
///  - Starting a scan moves the rig's TX/RX side ("VS", the same setting as
///    "FT") to that side. The app puts the previous TX side back when it
///    stops the scan itself (user decision) — not before a transmit, not
///    after a front-panel stop, and not once the operator picks a TX side.
///  - The same scan command again while paused resumes past the busy
///    channel (Skip).
///  - The rig steps ~10 channels a second, faster than any poll, so while
///    it scans the poll is replaced by a 250 ms "RI0" tick and the scanning
///    side's box is blanked; its channel is read the moment it pauses.
public sealed partial class MainWindow
{
    private enum ScanStopTxSide
    {
        /// Put the TX side back (Stop, or a tune/recall that stops the scan).
        Restore,
        /// Drop it: something is about to transmit on the side shown now.
        Keep,
        /// Leave it for the scan about to start on the other side.
        CarryOver,
    }

    private static readonly TimeSpan MemoryScanTickInterval = TimeSpan.FromMilliseconds(250);

    /// The TX side (true SUB) to put back when the app stops the scan it
    /// started; null when there's nothing to undo. Recorded whenever none
    /// is remembered yet, so a side switch keeps the original.
    private bool? _txSideBeforeScanSub;
    private bool _lastScanUp = true;
    /// When the app last started (or skipped) a scan: a "stopped" read just
    /// after may predate the rig acting on "SC".
    private DateTime? _scanStartedAt;
    /// Bumped by every start and Skip, so a pause read that a Skip has
    /// overtaken isn't published.
    private int _memoryScanStarts;

    private bool CanStartMemoryScan(bool sub) =>
        IsConnected && (sub ? _lastState.SubVfoMemoryRaw == 11 && _singleReceive != true : _lastState.VfoMemoryRaw == 11);

    private static string SideName(bool sub) => sub ? "SUB" : "MAIN";

    // Poll

    /// Runs first in every poll. While the rig scans, the scan tick replaces
    /// the poll (returns true). Otherwise reads "RI0" while either side is
    /// in Memory mode (or a scan was last seen running); if the rig turns
    /// out to be scanning — started from the front panel, or a BUSY resume
    /// — this poll stops before reading anything, since those reads would
    /// only catch a random channel.
    private async Task<bool> MemoryScanPollAsync(RigctldClient client)
    {
        if (_lastState.MemoryScan == MemoryScanState.Scanning)
        {
            await MemoryScanTickAsync(client);
            return true;
        }
        if (_lastState.VfoMemoryRaw != 11 && _lastState.SubVfoMemoryRaw != 11 && !_lastState.MemoryScanActive)
        {
            _lastState.MemoryScan = null;
            return false;
        }
        var generation = _commandGeneration;
        if (await ReadRadioInformationAsync(client) is not { } info || generation != _commandGeneration)
        {
            return false;
        }
        var wasActive = _lastState.MemoryScanActive;
        if (info.Scan != MemoryScanState.Stopped && !wasActive)
        {
            // A scan the app didn't start: "SC;" reads back its side.
            try
            {
                if (await client.GetMemoryScanSideAsync() is { } sub)
                {
                    _lastState.MemoryScanSub = sub;
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"poll: SC failed: {ex.Message}");
            }
            AppLog.Write($"memory scan: {SideName(_lastState.MemoryScanSub)} scan seen {info.Scan} (not started by the app)");
        }
        else if (info.Scan == MemoryScanState.Stopped && wasActive)
        {
            // Stopped without the app: leave the TX side as the rig has it.
            _txSideBeforeScanSub = null;
            AppLog.Write("memory scan: stopped on the rig");
        }
        _lastState.MemoryScan = info.Scan;
        if (info.Scan == MemoryScanState.Scanning)
        {
            _lastState.Ptt = info.IsTransmitting;
            UpdateScanDisplay();
            return true;
        }
        UpdateScanDisplay();
        return false;
    }

    /// The poll while scanning, every MemoryScanTickInterval: "RI0", plus
    /// the side that isn't scanning kept live — MAIN's frequency and mode
    /// ("FA"/"MD0", explicitly MAIN: the scan made SUB the active side)
    /// during a SUB scan, SUB's memory channel ("MC1", then its "MR" entry
    /// when it changes) during a MAIN scan.
    private async Task MemoryScanTickAsync(RigctldClient client)
    {
        var sub = _lastState.MemoryScanSub;
        var generation = _commandGeneration;
        var info = await ReadRadioInformationAsync(client);
        if (info is null || generation != _commandGeneration || _lastState.MemoryScan != MemoryScanState.Scanning)
        {
            return;
        }
        if (info.Scan == MemoryScanState.Scanning)
        {
            var pttChanged = _lastState.Ptt != info.IsTransmitting;
            _lastState.Ptt = info.IsTransmitting;
            if (sub)
            {
                await RefreshMainDuringSubScanAsync(client);
            }
            else if (_lastState.SubVfoMemoryRaw == 11)
            {
                await RefreshSubDuringMainScanAsync(client);
            }
            if (pttChanged)
            {
                UpdateTransmitControls();
            }
            return;
        }
        if (info.Scan == MemoryScanState.Stopped && _scanStartedAt is { } started && DateTime.UtcNow - started < TimeSpan.FromSeconds(1))
        {
            return;
        }
        if (info.Scan == MemoryScanState.Stopped)
        {
            _txSideBeforeScanSub = null;
            AppLog.Write("memory scan: stopped on the rig");
        }
        await PublishMemoryScanStopAsync(client, info.Scan, sub);
    }

    private static async Task<RadioInformation?> ReadRadioInformationAsync(RigctldClient client)
    {
        try
        {
            return await client.GetRadioInformationAsync();
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: RI0 failed: {ex.Message}");
            return null;
        }
    }

    private async Task RefreshMainDuringSubScanAsync(RigctldClient client)
    {
        var generation = _commandGeneration;
        try
        {
            var hz = await client.GetMainFrequencyAsync();
            var code = await client.GetModeCodeAsync(sub: false);
            if (generation != _commandGeneration || _lastState.MemoryScan != MemoryScanState.Scanning)
            {
                return;
            }
            ApplyMainFrequency(hz);
            ApplyMainModeCode(code);
        }
        catch (Exception ex)
        {
            AppLog.Write($"memory scan: MAIN read during SUB scan failed: {ex.Message}");
        }
    }

    private async Task RefreshSubDuringMainScanAsync(RigctldClient client)
    {
        var generation = _commandGeneration;
        try
        {
            if (await client.GetMemoryChannelAsync(sub: true) is not { } channel || channel == _lastState.SubMemoryChannel)
            {
                return;
            }
            if (await client.ReadMemoryChannelAsync(channel) is not { } entry
                || generation != _commandGeneration || _lastState.MemoryScan != MemoryScanState.Scanning)
            {
                return;
            }
            ApplySubChannel(channel, entry);
        }
        catch (Exception ex)
        {
            AppLog.Write($"memory scan: SUB read during MAIN scan failed: {ex.Message}");
        }
    }

    /// Reads and shows the channel a scan paused or stopped on, straight
    /// away rather than at the next poll. The channel number is read again
    /// after the rest and the set retried if it changed (the scan may have
    /// moved on between the reads), and re-read if a command landed
    /// mid-read (the Mac's 2026-10-06 fix: the TX-side restore right behind
    /// the app's own stop did). SUB's frequency/mode come from the channel's
    /// "MR" entry — see RigctldClient.GetSubFrequencyAsync. Nothing is
    /// published once a Skip or new scan has overtaken it.
    private async Task PublishMemoryScanStopAsync(RigctldClient client, MemoryScanState state, bool sub)
    {
        var starts = _memoryScanStarts;
        var generation = _commandGeneration;
        bool CommandLanded()
        {
            if (generation == _commandGeneration)
            {
                return false;
            }
            generation = _commandGeneration;
            return true;
        }
        for (var attempt = 0; attempt < 4; attempt++)
        {
            if (starts != _memoryScanStarts || _client != client)
            {
                return;
            }
            try
            {
                if (sub)
                {
                    if (await client.GetMemoryChannelAsync(sub: true) is not { } channel
                        || await client.ReadMemoryChannelAsync(channel) is not { } entry
                        || await client.GetMemoryChannelAsync(sub: true) != channel
                        || CommandLanded() || starts != _memoryScanStarts)
                    {
                        continue;
                    }
                    ApplySubChannel(channel, entry);
                }
                else
                {
                    var channel = await client.GetMemoryChannelAsync(sub: false);
                    var hz = await client.GetMainFrequencyAsync();
                    var code = await client.GetModeCodeAsync(sub: false);
                    if (channel is not { } c || await client.GetMemoryChannelAsync(sub: false) != c)
                    {
                        continue;
                    }
                    var tag = await client.GetMemoryChannelTagAsync(c);
                    if (CommandLanded() || starts != _memoryScanStarts)
                    {
                        continue;
                    }
                    ApplyMainFrequency(hz);
                    ApplyMainModeCode(code);
                    _lastState.MemoryChannel = c;
                    _lastState.MemoryChannelTag = tag;
                }
                _lastState.MemoryScan = state;
                AppLog.Write($"memory scan: {SideName(sub)} {state} on CH {(sub ? _lastState.SubMemoryChannel : _lastState.MemoryChannel)}");
                UpdateScanDisplay();
                return;
            }
            catch (Exception ex)
            {
                AppLog.Write($"memory scan: reading the {SideName(sub)} channel failed: {ex.Message}");
            }
        }
    }

    private void ApplyMainFrequency(long hz)
    {
        _lastState.FrequencyHz = hz;
        Volatile.Write(ref _aprsMainGateHz, hz);
        FrequencyAText.Text = FormatHz(hz);
        SetComboSelection(BandComboBox, BandPlan.BandContaining(hz)?.Name);
    }

    /// MAIN's raw "MD0" mode code: C4FM ("H"/"I") sets MainIsC4fm; a code
    /// this app's RigMode doesn't have (CW-L, FM-N, ...) keeps the last mode.
    private void ApplyMainModeCode(char? code)
    {
        if (code is not { } c)
        {
            return;
        }
        _lastState.MainIsC4fm = c is 'H' or 'I';
        if (RigModeExtensions.FromCatModeCode(c) is { } mode)
        {
            _lastState.Mode = mode;
            SetComboSelection(ModeComboBox, mode.DisplayName());
        }
        UpdateModeTags();
    }

    private void ApplySubChannel(int channel, MemoryChannelEntry entry)
    {
        _lastState.SubMemoryChannel = channel;
        _lastState.SubMemoryChannelTag = entry.Tag;
        _lastState.SecondaryFrequencyHz = entry.FrequencyHz;
        Volatile.Write(ref _aprsSubGateHz, entry.FrequencyHz);
        FrequencyBText.Text = FormatHz(entry.FrequencyHz);
        if (entry.ModeCode.Length > 0)
        {
            var code = entry.ModeCode[0];
            _lastState.SubIsC4fm = code is 'H' or 'I';
            _lastState.SubMode = RigModeExtensions.FromCatModeCode(code) ?? _lastState.SubMode;
        }
        UpdateMemoryDisplay();
        UpdateModeTags();
    }

    // Commands

    private async Task StartMemoryScanAsync(bool sub, bool up)
    {
        if (_client is not { } client)
        {
            return;
        }
        if (!CanStartMemoryScan(sub))
        {
            StatusText.Text = sub && _singleReceive == true
                ? "SUB isn't shown in single-receive display"
                : $"Put {SideName(sub)} in Memory mode to scan";
            return;
        }
        try
        {
            if (_lastState.MemoryScanActive && _lastState.MemoryScanSub != sub)
            {
                await StopMemoryScanAsync(client, ScanStopTxSide.CarryOver);
            }
            var txSub = _txSideSub ?? false;
            if (_txSideBeforeScanSub is null && txSub != sub)
            {
                _txSideBeforeScanSub = txSub;
            }
            _commandGeneration++;
            _memoryScanStarts++;
            await client.SetMemoryScanAsync(sub, up ? 1 : 2);
            AppLog.Write($"memory scan: {SideName(sub)} {(up ? "up" : "down")} started (TX side to restore: {(_txSideBeforeScanSub is { } t ? SideName(t) : "none")})");
            _lastScanUp = up;
            _scanStartedAt = DateTime.UtcNow;
            _lastState.MemoryScan = MemoryScanState.Scanning;
            _lastState.MemoryScanSub = sub;
            // The rig moves its TX/RX side to the scanning side.
            _txSideSub = sub;
            UpdateTxRxIndicators();
            StatusText.Text = "";
            UpdateScanDisplay();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Memory scan failed: {ex.Message}";
            AppLog.Write($"memory scan: start failed: {ex.Message}");
        }
    }

    private async Task SkipMemoryScanChannelAsync()
    {
        if (_client is not { } client || _lastState.MemoryScan != MemoryScanState.Paused)
        {
            return;
        }
        try
        {
            _commandGeneration++;
            _memoryScanStarts++;
            await client.SetMemoryScanAsync(_lastState.MemoryScanSub, _lastScanUp ? 1 : 2);
            _scanStartedAt = DateTime.UtcNow;
            _lastState.MemoryScan = MemoryScanState.Scanning;
            UpdateScanDisplay();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Skip failed: {ex.Message}";
        }
    }

    /// The Stop button: stop, put the TX side back, then show where it
    /// stopped.
    private async Task StopMemoryScanFromButtonAsync()
    {
        if (_client is not { } client || !_lastState.MemoryScanActive)
        {
            return;
        }
        var sub = _lastState.MemoryScanSub;
        try
        {
            await StopMemoryScanAsync(client, ScanStopTxSide.Restore);
            await PublishMemoryScanStopAsync(client, MemoryScanState.Stopped, sub);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Stop scan failed: {ex.Message}";
        }
    }

    /// "SC…0" (stops both sides' scans) and, for Restore, the TX side the
    /// scan moved — sent in that order, ahead of whatever the caller sends
    /// next, so e.g. a mode change after it reaches MAIN again rather than
    /// the SUB side a SUB scan made active.
    private async Task StopMemoryScanAsync(RigctldClient client, ScanStopTxSide txSide)
    {
        _commandGeneration++;
        await client.SetMemoryScanAsync(_lastState.MemoryScanSub, 0);
        _lastState.MemoryScan = MemoryScanState.Stopped;
        var previous = _txSideBeforeScanSub;
        if (txSide != ScanStopTxSide.CarryOver)
        {
            _txSideBeforeScanSub = null;
        }
        if (txSide == ScanStopTxSide.Restore && previous is { } previousSub)
        {
            await client.SetRawIntAsync("FT", previousSub ? 1 : 0, 1);
            _txSideSub = previousSub;
            UpdateTxRxIndicators();
        }
        AppLog.Write($"memory scan: {SideName(_lastState.MemoryScanSub)} stopped by the app ({txSide}{(txSide == ScanStopTxSide.Restore && previous is { } p ? $", TX back to {SideName(p)}" : "")})");
        UpdateScanDisplay();
    }

    /// Stops a running scan before a command that would fight it — the
    /// Mac's memoryScanStop(for:scanSide:). onlySub: only that side's scan
    /// (null: either). "F currVFO", "M currVFO" and "CH" follow the rig's
    /// active side, which a SUB scan made SUB, so main-frequency, mode, band
    /// and channel-step commands pass null; restoring the TX side first
    /// lands them on MAIN as meant.
    private async Task StopMemoryScanForAsync(RigctldClient client, bool? onlySub, ScanStopTxSide txSide)
    {
        if (!_lastState.MemoryScanActive || (onlySub is { } s && s != _lastState.MemoryScanSub))
        {
            return;
        }
        try
        {
            await StopMemoryScanAsync(client, txSide);
        }
        catch (Exception ex)
        {
            AppLog.Write($"memory scan: stop before a command failed: {ex.Message}");
        }
    }

    /// Before anything that transmits (PTT, MOX, ANT TUNE, a CW chunk): stop the scan
    /// but keep the TX side, so it keys the side the display shows.
    private Task StopMemoryScanBeforeTransmitAsync() =>
        _client is { } client ? StopMemoryScanForAsync(client, null, ScanStopTxSide.Keep) : Task.CompletedTask;

    // UI

    private async void MemoryScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (_lastState.MemoryScanActive)
        {
            await StopMemoryScanFromButtonAsync();
            return;
        }
        // SUB first, matching the boxes' left-to-right order.
        var menu = new MenuFlyout();
        foreach (var sub in new[] { true, false })
        {
            var item = new MenuFlyoutItem { Text = $"Scan {SideName(sub)}", IsEnabled = CanStartMemoryScan(sub) };
            item.Click += async (_, _) => await StartMemoryScanAsync(sub, up: true);
            menu.Items.Add(item);
        }
        menu.ShowAt(MemoryScanButton);
    }

    private async void MemoryScanSkipButton_Click(object sender, RoutedEventArgs e) =>
        await SkipMemoryScanChannelAsync();

    /// Everything the scan state shows in: the poll interval, the boxes
    /// (via the memory label, mode tag and indicator line — see their own
    /// overrides), the scanning side's frequency, the buttons and the
    /// memory list window.
    private void UpdateScanDisplay()
    {
        var scanning = _lastState.MemoryScan == MemoryScanState.Scanning;
        var interval = scanning ? MemoryScanTickInterval : TimeSpan.FromMilliseconds(AppSettings.PollIntervalMs);
        if (_pollTimer.Interval != interval)
        {
            _pollTimer.Interval = interval;
        }
        if (_lastState.MemoryScanOn(false) == MemoryScanState.Scanning)
        {
            FrequencyAText.Text = "—";
        }
        else if (IsConnected && _lastState.FrequencyHz > 0)
        {
            FrequencyAText.Text = FormatHz(_lastState.FrequencyHz);
        }
        if (_lastState.MemoryScanOn(true) == MemoryScanState.Scanning)
        {
            FrequencyBText.Text = "—";
        }
        else if (IsConnected && _lastState.SecondaryFrequencyHz is { } subHz)
        {
            FrequencyBText.Text = FormatHz(subHz);
        }
        // Also runs UpdateMemoryScanControls.
        UpdateMemoryDisplay();
        UpdateC4fmDisplay();
    }

    /// The Scan/Skip buttons and the memory list window's scan controls —
    /// from UpdateMemoryDisplay, so they follow each poll's Memory-mode read.
    private void UpdateMemoryScanControls()
    {
        var active = _lastState.MemoryScanActive;
        MemoryScanButton.Content = active ? $"Stop {SideName(_lastState.MemoryScanSub)}" : "Scan";
        var style = (Style)Application.Current.Resources[active ? "AccentButtonStyle" : "DefaultButtonStyle"];
        if (MemoryScanButton.Style != style)
        {
            MemoryScanButton.Style = style;
        }
        MemoryScanButton.IsEnabled = IsConnected && (active || CanStartMemoryScan(false) || CanStartMemoryScan(true));
        MemoryScanSkipButton.IsEnabled = IsConnected && _lastState.MemoryScan == MemoryScanState.Paused;
        _memoryListWindow?.SetMemoryScan(_lastState.MemoryScan, _lastState.MemoryScanSub,
            CanStartMemoryScan(false), CanStartMemoryScan(true),
            _lastState.MemoryScanSub ? _lastState.SubMemoryChannel : _lastState.MemoryChannel);
    }

    /// A box's memory label while its side scans (UpdateMemoryDisplay).
    private void ShowScanningMemoryLabels()
    {
        foreach (var (label, sub) in new[] { (MemoryChannelAText, false), (MemoryChannelBText, true) })
        {
            if (_lastState.MemoryScanOn(sub) == MemoryScanState.Scanning)
            {
                label.Text = "SCANNING";
                label.Visibility = Visibility.Visible;
            }
        }
    }

    /// The indicator line while a side scans or is paused, and no callsign
    /// mid-scan (UpdateC4fmDisplay).
    private void ShowScanIndicators()
    {
        foreach (var (callsign, reflector, sub) in new[] { (C4fmCallsignAText, C4fmReflectorAText, false), (C4fmCallsignBText, C4fmReflectorBText, true) })
        {
            switch (_lastState.MemoryScanOn(sub))
            {
                case MemoryScanState.Scanning:
                    callsign.Text = "";
                    reflector.Text = "SCAN";
                    break;
                case MemoryScanState.Paused:
                    reflector.Text = "SCAN PAUSED";
                    break;
            }
        }
    }
}
