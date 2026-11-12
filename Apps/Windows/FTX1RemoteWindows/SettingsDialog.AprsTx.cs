using System.Globalization;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml.Controls;

namespace FTX1RemoteWindows;

/// Settings → APRS → Transmit: what beacons and messages carry and how they
/// go out (the Mac's APRSTransmitSettingsSection). Applies on Save like every
/// other tab here.
public sealed partial class SettingsDialog
{
    /// Common primary-table symbols; anything else can be typed.
    private static readonly (string Code, string NameKey)[] AprsSymbols =
    [
        ("/-", "aprsSymbol.house"), ("/y", "aprsSymbol.yagi"), ("/>", "aprsSymbol.car"), ("/k", "aprsSymbol.truck"),
        ("/R", "aprsSymbol.rv"), ("/[", "aprsSymbol.person"), ("/b", "aprsSymbol.bicycle"), ("/s", "aprsSymbol.boat"),
        ("/'", "aprsSymbol.aircraft"), ("/;", "aprsSymbol.portable"),
    ];

    private bool _aprsTxLoading;

    private void InitAprsTx()
    {
        _aprsTxLoading = true;
        var data = AppSettings.AprsTx;
        AprsTxEnabledCheckBox.IsChecked = data.Enabled;

        AprsTxSsidComboBox.Items.Clear();
        for (var ssid = 0; ssid <= 15; ssid++)
        {
            AprsTxSsidComboBox.Items.Add(ssid == 0 ? Loc.S("settings.aprsTransmit.ssidNone") : $"-{ssid}");
        }
        AprsTxSsidComboBox.SelectedIndex = AprsTransmitSettings.Ssid;

        AprsTxLatitudeBox.Text = CoordinateText(data.Latitude);
        AprsTxLongitudeBox.Text = CoordinateText(data.Longitude);

        AprsTxAmbiguityComboBox.Items.Clear();
        foreach (var key in new[] { "settings.aprsTransmit.ambiguityExact", "settings.aprsTransmit.ambiguity1",
                     "settings.aprsTransmit.ambiguity2", "settings.aprsTransmit.ambiguity3", "settings.aprsTransmit.ambiguity4" })
        {
            AprsTxAmbiguityComboBox.Items.Add(Loc.S(key));
        }
        AprsTxAmbiguityComboBox.SelectedIndex = AprsTransmitSettings.Ambiguity;

        AprsTxSymbolBox.Text = AprsTransmitSettings.Symbol;
        AprsTxSymbolPresetComboBox.Items.Clear();
        foreach (var (code, nameKey) in AprsSymbols)
        {
            AprsTxSymbolPresetComboBox.Items.Add($"{Loc.S(nameKey)}  {code}");
        }
        AprsTxSymbolPresetComboBox.SelectedIndex = -1;

        AprsTxCommentBox.Text = AprsTransmitSettings.Comment;
        AprsTxPathBox.Text = AprsTransmitSettings.Path;

        AprsTxBeaconComboBox.Items.Clear();
        foreach (var minutes in AprsTransmitSettings.BeaconChoices)
        {
            AprsTxBeaconComboBox.Items.Add(minutes == 0
                ? Loc.S("settings.aprsTransmit.beaconOff")
                : Loc.P("settings.aprsTransmit.minutes", minutes));
        }
        var beaconIndex = Array.IndexOf(AprsTransmitSettings.BeaconChoices, AprsTransmitSettings.BeaconMinutes);
        AprsTxBeaconComboBox.SelectedIndex = Math.Max(0, beaconIndex);

        AprsTxAutoAckCheckBox.IsChecked = AprsTransmitSettings.AutoAck;
        AprsTxLevelSlider.Value = AprsTransmitSettings.LevelDb;
        UpdateAprsTxLevelHeader();
        AprsTxDelayBox.Value = AprsTransmitSettings.TxDelayMs;
        _aprsTxLoading = false;
        UpdateAprsTxSentAs();
    }

    private void AprsTxSsidComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_aprsTxLoading)
        {
            UpdateAprsTxSentAs();
        }
    }

    private void AprsTxSymbolPresetComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_aprsTxLoading && AprsTxSymbolPresetComboBox.SelectedIndex is >= 0 and var index)
        {
            AprsTxSymbolBox.Text = AprsSymbols[index].Code;
        }
    }

    private void AprsTxLevelSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        UpdateAprsTxLevelHeader();
    }

    private void UpdateAprsTxLevelHeader() =>
        AprsTxLevelSlider.Header = Loc.F("settings.aprsTransmit.levelDb", (int)AprsTxLevelSlider.Value);

    /// "N0CALL-5" from the Station tab's callsign and the SSID chosen here,
    /// or the reminder to set a callsign.
    private void UpdateAprsTxSentAs()
    {
        var call = AprsTransmitSettings.SourceCallFor(CallsignBox.Text, Math.Max(0, AprsTxSsidComboBox.SelectedIndex));
        AprsTxSentAsText.Text = call ?? Loc.S("settings.aprsTransmit.needCallsign");
    }

    /// Why the Transmit section can't be saved, null when it can.
    private string? AprsTxProblem()
    {
        if (ParseCoordinate(AprsTxLatitudeBox.Text, 90, out _) is false)
        {
            return Loc.S("settings.aprsTransmit.badCoordinate");
        }
        if (ParseCoordinate(AprsTxLongitudeBox.Text, 180, out _) is false)
        {
            return Loc.S("settings.aprsTransmit.badCoordinate");
        }
        var symbol = AprsTxSymbolBox.Text;
        if (symbol.Length != 2 || symbol.Any(c => c > 0x7E || c < 0x20))
        {
            return Loc.S("aprsMessaging.badSymbol");
        }
        if (Ax25Encoder.ParsePath(AprsTxPathBox.Text) is null)
        {
            return Loc.S("aprsTransmit.badPath");
        }
        return null;
    }

    private void SaveAprsTx()
    {
        var data = AppSettings.AprsTx;
        data.Enabled = AprsTxEnabledCheckBox.IsChecked == true;
        data.Ssid = Math.Max(0, AprsTxSsidComboBox.SelectedIndex);
        ParseCoordinate(AprsTxLatitudeBox.Text, 90, out var latitude);
        ParseCoordinate(AprsTxLongitudeBox.Text, 180, out var longitude);
        data.Latitude = latitude;
        data.Longitude = longitude;
        data.Ambiguity = Math.Max(0, AprsTxAmbiguityComboBox.SelectedIndex);
        data.Symbol = AprsTxSymbolBox.Text;
        data.Comment = AprsOutgoing.Sanitized(AprsTxCommentBox.Text);
        data.Path = AprsTxPathBox.Text.Trim();
        data.BeaconMinutes = AprsTransmitSettings.BeaconChoices[Math.Max(0, AprsTxBeaconComboBox.SelectedIndex)];
        data.AutoAck = AprsTxAutoAckCheckBox.IsChecked == true;
        data.LevelDb = AprsTxLevelSlider.Value;
        data.TxDelayMs = double.IsNaN(AprsTxDelayBox.Value)
            ? AprsTransmitSettings.DefaultTxDelayMs
            : (int)Math.Clamp(Math.Round(AprsTxDelayBox.Value), AprsTransmitSettings.MinTxDelayMs, AprsTransmitSettings.MaxTxDelayMs);
        AppSettings.SaveAprsTx();
    }

    /// Empty is fine (no position); otherwise decimal degrees with "." or ",".
    private static bool ParseCoordinate(string text, double limit, out double? value)
    {
        value = null;
        var cleaned = text.Trim().Replace(',', '.');
        if (cleaned.Length == 0)
        {
            return true;
        }
        if (!double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            || !double.IsFinite(parsed) || Math.Abs(parsed) > limit)
        {
            return false;
        }
        value = parsed;
        return true;
    }

    /// Decimal degrees with a "." whatever the locale, at most 6 places.
    private static string CoordinateText(double? value) =>
        value is { } v ? v.ToString("0.######", CultureInfo.InvariantCulture) : "";
}
