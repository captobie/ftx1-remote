using System.Globalization;

namespace FTX1RemoteWindows.Services;

/// Where recordings go and what they're called — the static half of the
/// Mac's AudioRecorder (recordingsDirectory/newRecordingURL/label). Only
/// the WebSDR window records on Windows so far (the KiwiSDR/WebSDR page's
/// own recorder, see SdrPageBridge); the CW page's PLAY/RECORD are still
/// placeholders. Same naming scheme as the Mac, so the files read the same
/// on both: "Recording 2026-09-24 07.47.30 14.074.000 USB KiwiSDR.wav".
public static class Recordings
{
    /// %LOCALAPPDATA%\FTX1RemoteWindows\Recordings, next to settings.json
    /// (the Mac's Application Support/FTX1Remote/Recordings). The WebSDR
    /// window's Recordings button opens it in Explorer — there's no
    /// Recordings window here yet.
    public static string Directory
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FTX1RemoteWindows",
                "Recordings");
            System.IO.Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string NewRecordingPath(string label, DateTime date)
    {
        var stamp = date.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture);
        // The Mac only has "/" to worry about; Windows file names lose more.
        var invalid = Path.GetInvalidFileNameChars();
        var sanitized = new string(label.Select(c => invalid.Contains(c) ? '-' : c).ToArray()).Trim();
        var name = sanitized.Length == 0 ? $"Recording {stamp}" : $"Recording {stamp} {sanitized}";
        return Path.Combine(Directory, name + ".wav");
    }

    /// "147.380.000 FM" — dot-grouped like the VFO display, so a file name
    /// reads the way the rig's own display does.
    public static string Label(long frequencyHz, string modeName)
    {
        var digits = frequencyHz.ToString(CultureInfo.InvariantCulture);
        var groups = new List<string>();
        for (var end = digits.Length; end > 0; end -= 3)
        {
            groups.Insert(0, digits[Math.Max(0, end - 3)..end]);
        }
        var frequency = string.Join(".", groups);
        return modeName.Length == 0 ? frequency : $"{frequency} {modeName}";
    }
}
