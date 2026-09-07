using System.Diagnostics;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace FTX1RemoteWindows;

/// v1 core-rig-control window: VFO A/B, mode, PTT, power, SWR, band — see
/// Apps/Windows/README.md's "v1 scope". No MENU grid / Deep Settings /
/// waterfall / APRS here yet, all deliberately deferred.
public sealed partial class MainWindow : Window
{
    private RigctldClient? _client;
    private readonly DispatcherQueueTimer _pollTimer;

    /// Suppresses ComboBox SelectionChanged handlers while the poll loop
    /// is writing a freshly-read value into them, so reading the rig's
    /// current mode/band doesn't turn around and re-send it as a set
    /// command.
    private bool _suppressSelectionEvents;

    private RigState _lastState = new();

    public MainWindow()
    {
        InitializeComponent();

        PiHostBox.Text = AppSettings.PiHost;

        _suppressSelectionEvents = true;
        foreach (RigMode mode in Enum.GetValues<RigMode>())
        {
            ModeComboBox.Items.Add(new ComboBoxItem { Content = mode.DisplayName(), Tag = mode });
        }
        foreach (var band in BandPlan.All)
        {
            BandComboBox.Items.Add(new ComboBoxItem { Content = band.Name, Tag = band });
        }
        _suppressSelectionEvents = false;

        _pollTimer = DispatcherQueue.CreateTimer();
        _pollTimer.Interval = TimeSpan.FromSeconds(1);
        _pollTimer.Tick += async (_, _) => await PollOnceAsync();
    }

    private bool IsConnected => _client is not null;

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        if (IsConnected)
        {
            _pollTimer.Stop();
            await (_client?.DisposeAsync() ?? ValueTask.CompletedTask);
            _client = null;
            ConnectionStateText.Text = "Disconnected";
            ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray);
            ConnectButton.Content = "Connect";
            return;
        }

        var host = PiHostBox.Text.Trim();
        if (host.Length == 0)
        {
            StatusText.Text = "Enter the Pi's Tailscale hostname first.";
            return;
        }
        AppSettings.PiHost = host;

        ConnectButton.IsEnabled = false;
        ConnectionStateText.Text = "Connecting…";
        ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Orange);
        StatusText.Text = "";

        var client = new RigctldClient(host);
        try
        {
            // TODO (Apps/Windows/README.md "Reconnect / connection-state
            // UI"): distinguish a TCP-connect failure (Pi/Tailscale
            // unreachable) from a connected-but-bad-CAT-reply failure here
            // once that split is designed — right now both surface as the
            // same generic RigctldError.
            await client.ConnectAsync();
            _client = client;
            ConnectionStateText.Text = $"Connected to {host}:4532";
            ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green);
            ConnectButton.Content = "Disconnect";
            _pollTimer.Start();
            await PollOnceAsync();
        }
        catch (Exception ex)
        {
            await client.DisposeAsync();
            ConnectionStateText.Text = "Disconnected";
            ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray);
            StatusText.Text = $"Connect failed: {ex.Message}";
        }
        finally
        {
            ConnectButton.IsEnabled = true;
        }
    }

    /// Polls each field independently, falling back to the last-known
    /// value on any individual failure rather than tearing down the whole
    /// connection. This is not incidental caution — see
    /// Apps/Windows/README.md's porting table entry for "Poll loop": the
    /// Mac app shipped exactly this bug (one unwrapped read in the poll
    /// cycle causing reconnect storms over the Tailscale hop) and only
    /// caught it during real-hardware validation on 2026-09-07.
    private async Task PollOnceAsync()
    {
        if (_client is not { } client)
        {
            return;
        }

        try
        {
            var hz = await client.GetFrequencyAsync();
            _lastState.FrequencyHz = hz;
            FrequencyAText.Text = FormatHz(hz);
            var band = BandPlan.BandContaining(hz);
            SetComboSelection(BandComboBox, band?.Name);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getFrequency failed: {ex.Message}");
        }

        try
        {
            var hz = await client.GetSecondaryFrequencyAsync();
            _lastState.SecondaryFrequencyHz = hz;
            FrequencyBText.Text = FormatHz(hz);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getSecondaryFrequency failed: {ex.Message}");
        }

        try
        {
            var mode = await client.GetModeAsync();
            _lastState.Mode = mode;
            SetComboSelection(ModeComboBox, mode?.DisplayName());
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getMode failed: {ex.Message}");
        }

        try
        {
            var ptt = await client.GetPttAsync();
            _lastState.Ptt = ptt;
            PttToggle.IsChecked = ptt;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getPtt failed: {ex.Message}");
        }

        try
        {
            var level = await client.GetLevelAsync("RFPOWER");
            if (level is { } l)
            {
                _lastState.PowerLevel = l;
                PowerSlider.Value = l * 100;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getLevel(RFPOWER) failed: {ex.Message}");
        }

        try
        {
            var watts = await client.GetLevelAsync("RFPOWER_METER_WATTS");
            if (watts is { } w)
            {
                _lastState.PowerWatts = w;
                PowerWattsText.Text = $"{w:F1} W";
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getLevel(RFPOWER_METER_WATTS) failed: {ex.Message}");
        }

        try
        {
            var swr = await client.GetLevelAsync("SWR");
            if (swr is { } s)
            {
                _lastState.Swr = s;
                SwrText.Text = $"{s:F2}";
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getLevel(SWR) failed: {ex.Message}");
        }
    }

    private void SetComboSelection(ComboBox box, string? tagText)
    {
        if (tagText is null)
        {
            return;
        }
        _suppressSelectionEvents = true;
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if (Equals(item.Content, tagText) || (item.Tag is Band b && b.Name == tagText))
            {
                box.SelectedItem = item;
                break;
            }
        }
        _suppressSelectionEvents = false;
    }

    private static string FormatHz(long hz) => hz.ToString("N0") + " Hz";

    private async void SetFrequencyButton_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        if (!long.TryParse(FrequencyEntryBox.Text.Trim(), out var hz))
        {
            StatusText.Text = "Enter a frequency in Hz.";
            return;
        }
        try
        {
            await _client.SetFrequencyAsync(hz);
            StatusText.Text = "";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set frequency failed: {ex.Message}";
        }
    }

    private async void SwapVfoButton_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        try
        {
            await _client.SwapActiveVfoAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Swap VFO failed: {ex.Message}";
        }
    }

    private async void ModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents || _client is null)
        {
            return;
        }
        if (ModeComboBox.SelectedItem is not ComboBoxItem { Tag: RigMode mode })
        {
            return;
        }
        try
        {
            await _client.SetModeAsync(mode);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set mode failed: {ex.Message}";
        }
    }

    /// rigctld has no "set band" verb — same gap CommandQueue.apply's
    /// .setBand case documents on the Swift side (it's normally resolved
    /// into a .setFrequency by HubService before reaching that queue).
    /// This always jumps to the band's default calling frequency; there's
    /// no per-band "last used frequency" memory yet (Mac's BandMemory
    /// equivalent) — out of v1 scope, add if it turns out to matter.
    private async void BandComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents || _client is null)
        {
            return;
        }
        if (BandComboBox.SelectedItem is not ComboBoxItem { Tag: Band band })
        {
            return;
        }
        try
        {
            await _client.SetFrequencyAsync(band.DefaultFrequencyHz);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set band failed: {ex.Message}";
        }
    }

    private async void PttToggle_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        try
        {
            await _client.SetPttAsync(PttToggle.IsChecked == true);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set PTT failed: {ex.Message}";
        }
    }

    private async void PowerSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        try
        {
            await _client.SetPowerLevelAsync(e.NewValue / 100.0);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set power failed: {ex.Message}";
        }
    }
}
