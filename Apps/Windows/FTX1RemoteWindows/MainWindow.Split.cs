using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FTX1RemoteWindows;

/// SPLIT and quick split — the Mac's (CLAUDE.md "Split"; HubService's
/// quickSplit/refreshAfterSplit). What the rig does, read on it 2026-10-31:
///  - "ST1" isn't "transmit on the SUB receiver". It turns the dual display
///    off ("FR01"); MAIN receives, and the rig transmits from a second VFO
///    that "FB" (and hamlib's "f Sub") reads, always in MAIN's mode. "FT"
///    stays 0.
///  - The SUB receiver keeps its own state ("VM1"/"MC1"/"MD1" still describe
///    it), so in split the left box shows the TX VFO instead: its frequency,
///    MAIN's mode, a TX tag, no memory channel.
///  - "ST0" brings the dual display back.
public sealed partial class MainWindow
{
    /// Quick split offsets, kHz: the usual "up 1"/"up 5" and friends.
    private static readonly int[] QuickSplitOffsetsKHz = [1, 2, 3, 5, 10, -1, -5];

    /// Whether SPLIT can be switched now: connected, not transmitting
    /// (switching it moves the transmitter to the other VFO's frequency),
    /// and no memory scan running (the scan moves the TX side itself).
    private bool CanChangeSplit =>
        IsConnected && !_pttHeld && !_lastState.Ptt && _lastState.MoxEnabled != true && !_lastState.MemoryScanActive;

    private bool CanQuickSplit => CanChangeSplit && _lastState.FrequencyHz > 0;

    private void InitSplitControls()
    {
        var menu = new MenuFlyout();
        foreach (var kHz in QuickSplitOffsetsKHz)
        {
            var item = new MenuFlyoutItem
            {
                Text = kHz > 0 ? Loc.F("mainWindow.quickSplitUp", kHz) : Loc.F("mainWindow.quickSplitDown", -kHz),
            };
            item.Click += async (_, _) => await QuickSplitAsync(kHz * 1000);
            menu.Items.Add(item);
        }
        QuickSplitButton.Flyout = menu;
        UpdateSplitControls();
    }

    private async void SplitToggle_Click(object sender, RoutedEventArgs e) => await SetSplitAsync(_splitOn != true);

    /// The SPLIT button, and the Desktop hub's set_split.
    private async Task SetSplitAsync(bool on)
    {
        if (_client is not { } client || !CanChangeSplit)
        {
            AppLog.Write($"split: ignored {(on ? "on" : "off")}: not connected, transmitting or scanning");
            UpdateSplitControls();
            return;
        }
        // Chosen by the operator: not undone when a memory scan stops.
        _txSideBeforeScanSub = null;
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        try
        {
            await client.SetRawBoolAsync("ST", on);
            AppLog.Write($"split: ST{(on ? 1 : 0)} sent");
            await RefreshAfterSplitAsync(client);
        }
        catch (Exception ex)
        {
            StatusText.Text = Loc.F("mainWindow.setSplitFailed", ex.Message);
            AppLog.Write($"split: ST failed: {ex.Message}");
        }
        UpdateSplitControls();
    }

    /// Quick split: SPLIT on, then the TX VFO to MAIN's frequency plus
    /// <paramref name="offsetHz"/>. In that order: only in split does "FB"
    /// address the TX VFO — before, it's the SUB receiver. No mode to set:
    /// the TX VFO follows MAIN's.
    private async Task QuickSplitAsync(int offsetHz)
    {
        if (_client is not { } client || !CanQuickSplit)
        {
            AppLog.Write($"split: ignored quick split (offset {offsetHz} Hz)");
            return;
        }
        var target = _lastState.FrequencyHz + offsetHz;
        if (target <= 0)
        {
            return;
        }
        AppLog.Write($"split: quick split, TX VFO to {target} Hz");
        _txSideBeforeScanSub = null;
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        try
        {
            await client.SetRawBoolAsync("ST", true);
            await client.SetSecondaryFrequencyAsync(target);
            await RefreshAfterSplitAsync(client);
        }
        catch (Exception ex)
        {
            StatusText.Text = Loc.F("mainWindow.setSplitFailed", ex.Message);
            AppLog.Write($"split: quick split failed: {ex.Message}");
        }
        UpdateSplitControls();
    }

    /// Reads what a split write changes right away instead of waiting for
    /// the slow tier: SPLIT, the TX side, the display mode and "FB", which
    /// switches between the TX VFO and the SUB receiver — so the left box,
    /// the tags and the transmit gate follow at once.
    private async Task RefreshAfterSplitAsync(RigctldClient client)
    {
        await Task.Delay(300);
        if (_client != client)
        {
            return;
        }
        // Best-effort, each on its own: the write has already gone out, and
        // the slow tier picks up whatever fails here.
        var split = await Read(() => client.GetRawBoolAsync("ST"));
        var txSide = await Read(() => client.GetRawDigitAsync("FT"));
        var fr = await Read(() => client.GetRawIntAsync("FR"));
        var fb = await Read(() => client.GetRawIntAsync("FB"));
        AppLog.Write($"split: after write ST={Show(split)} FT={Show(txSide)} FR={Show(fr)} FB={Show(fb)}");
        if (_client != client)
        {
            return;
        }
        // A poll that straddled the write has the old values.
        _commandGeneration++;
        if (split is { } on)
        {
            _splitOn = on;
        }
        if (txSide is { } side)
        {
            _txSideSub = side == 1;
        }
        if (fr is { } value)
        {
            ApplySingleReceive(value);
        }
        if (fb is { } hz and > 0)
        {
            _lastState.SecondaryFrequencyHz = hz;
            Volatile.Write(ref _aprsSubGateHz, hz);
            FrequencyBText.Text = FormatHz(hz);
            _swapTracker.ResetBaseline();
        }
        UpdateSplitDisplay();
        // The gate checks the transmitting frequency, which just moved.
        UpdateTransmitControls();

        static string Show<T>(T? value) where T : struct => value?.ToString() ?? "?";

        static async Task<T?> Read<T>(Func<Task<T?>> read) where T : struct
        {
            try
            {
                return await read();
            }
            catch (Exception ex)
            {
                AppLog.Write($"split: read-back failed: {ex.Message}");
                return null;
            }
        }
    }

    /// An "FR" reply (0 dual, 1 single), from the slow tier or a split write.
    private void ApplySingleReceive(int fr)
    {
        var single = fr == 1;
        if (single != _singleReceive)
        {
            AppLog.Write($"audio-routing: FR reply {fr} — {(single ? "single" : "dual")} receive");
        }
        _singleReceive = single;
        _filterPanel.SingleReceive = single;
        // The Mac's VFODisplayBox: SUB's border goes gray while it isn't shown.
        ApplySubVfoBorder();
    }

    /// A session starts from unread; the slow tier reads "ST" on its first poll.
    private void ClearSplitState()
    {
        _splitOn = null;
        UpdateSplitDisplay();
    }

    /// Everything on screen that depends on "ST".
    private void UpdateSplitDisplay()
    {
        SubLabelText.Text = _splitOn == true ? "SPLIT" : "SUB";
        ApplySubVfoBorder();
        UpdateTxRxIndicators();
        // Also runs UpdateMemoryScanControls → UpdateSplitControls.
        UpdateMemoryDisplay();
        // Also runs UpdateModeTags.
        UpdateC4fmDisplay();
    }

    private void UpdateSplitControls()
    {
        SplitToggle.IsChecked = _splitOn == true;
        SplitToggle.IsEnabled = CanChangeSplit;
        QuickSplitButton.IsEnabled = CanQuickSplit;
    }
}
