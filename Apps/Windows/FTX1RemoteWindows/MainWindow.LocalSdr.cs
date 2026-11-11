using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;

namespace FTX1RemoteWindows;

/// The MyKiwiSDR window (Controls/LocalSdrWindow.cs) — the Mac's Tools →
/// MyKiwiSDR. The window's model follows the rig and tunes it through the
/// same paths as the WebSDR window's.
public sealed partial class MainWindow
{
    private LocalSdrWindow? _localSdrWindow;
    /// The decoders' MyKiwiSDR source, shared by the CW and RTTY/PSK receivers
    /// and the MyKiwiSDR window.
    private readonly LocalSdrAudioSource _localSdrSource = new();
    private bool _webSdrHoldsMain;
    private bool _kiwiHoldsMain;

    /// The button shows only when Settings → Devices has MyKiwiSDR on; turning
    /// it off closes the window (which disconnects).
    private void ApplyLocalSdrVisibility()
    {
        var on = AppSettings.LocalSdr.IsEnabled;
        LocalSdrButton.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (!on)
        {
            _localSdrWindow?.Close();
        }
    }

    private void LocalSdrButton_Click(object sender, RoutedEventArgs e)
    {
        if (_localSdrWindow is null)
        {
            _localSdrWindow = new LocalSdrWindow(new LocalSdrRigLink
            {
                Current = CurrentRigSnapshot,
                Connected = () => IsConnected,
                Tune = (hz, mode) => _ = TuneFromWebSdrAsync(hz, mode),
                SetAudioActive = SetKiwiAudioActive,
                Source = _localSdrSource,
                RigFilter = () => IsConnected ? KiwiPassband.FromRigFilter(_lastState) : null,
            });
            _localSdrWindow.Closed += (_, _) => _localSdrWindow = null;
            _localSdrWindow.RecordingsRequested += ShowRecordings;
        }
        _localSdrWindow.Activate();
    }

    /// After every poll and on disconnect — the Mac's window subscribes to
    /// hub.$rigState instead.
    private void PushRigStateToLocalSdr() => _localSdrWindow?.Model.OnRigState();

    private void SetKiwiAudioActive(bool active)
    {
        _kiwiHoldsMain = active;
        ApplyMainAudioOverride(_webSdrHoldsMain || _kiwiHoldsMain);
    }
}
