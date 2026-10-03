using System.Globalization;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services;

public sealed record Recording(string Path, DateTime Date, TimeSpan Duration)
{
    public string Name => System.IO.Path.GetFileNameWithoutExtension(Path);
}

/// Where recordings go, what they're called, and the file operations behind
/// the Recordings window — the static half of the Mac's AudioRecorder
/// (recordingsDirectory/newRecordingURL/label/listRecordings/delete/rename/
/// export). Written by the CW page's RECORD (AudioRecorder) and the WebSDR
/// window's Record. Same naming scheme as the Mac, so the files read the
/// same on both: "Recording 2026-09-24 07.47.30 14.074.000 USB KiwiSDR.wav".
public static class Recordings
{
    /// %LOCALAPPDATA%\FTX1RemoteWindows\Recordings, next to settings.json
    /// (the Mac's Application Support/FTX1Remote/Recordings).
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

    /// Read fresh each call, newest first — the Recordings window reloads on
    /// open and on every change, so there's no index to keep in step with
    /// the folder.
    public static List<Recording> List()
    {
        var result = new List<Recording>();
        try
        {
            foreach (var path in System.IO.Directory.EnumerateFiles(Directory, "*.wav"))
            {
                result.Add(new Recording(path, File.GetLastWriteTime(path), Duration(path)));
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"recordings: couldn't list the folder: {ex.Message}");
        }
        return result.OrderByDescending(r => r.Date).ToList();
    }

    /// Zero for a file that isn't a readable WAV (or is still being
    /// written: its header's sizes are filled in on Stop).
    private static TimeSpan Duration(string path)
    {
        try
        {
            using var reader = new WaveFileReader(path);
            return reader.TotalTime;
        }
        catch
        {
            return TimeSpan.Zero;
        }
    }

    public static bool Delete(Recording recording)
    {
        try
        {
            File.Delete(recording.Path);
            return true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"recordings: couldn't delete {recording.Name}: {ex.Message}");
            return false;
        }
    }

    /// Renames to <paramref name="newName"/> (a typed ".wav" is dropped so
    /// it isn't doubled; characters Windows doesn't allow become "-").
    /// Returns an error message, or null on success (including no change).
    public static string? Rename(Recording recording, string newName)
    {
        var trimmed = newName.Trim();
        if (trimmed.EndsWith(".wav", StringComparison.OrdinalIgnoreCase))
        {
            trimmed = trimmed[..^4].TrimEnd();
        }
        var invalid = Path.GetInvalidFileNameChars();
        var sanitized = new string(trimmed.Select(c => invalid.Contains(c) ? '-' : c).ToArray()).Trim();
        if (sanitized.Length == 0)
        {
            return "The name can't be empty.";
        }
        var newPath = Path.Combine(Directory, sanitized + ".wav");
        if (string.Equals(newPath, recording.Path, StringComparison.Ordinal))
        {
            return null;
        }
        // A case-only rename is the same file to Windows, so let it through.
        if (File.Exists(newPath) && !string.Equals(newPath, recording.Path, StringComparison.OrdinalIgnoreCase))
        {
            return $"There's already a recording named \"{sanitized}\".";
        }
        try
        {
            File.Move(recording.Path, newPath);
            return null;
        }
        catch (Exception ex)
        {
            AppLog.Write($"recordings: couldn't rename {recording.Name}: {ex.Message}");
            return ex.Message;
        }
    }

    /// Copies each recording into <paramref name="folder"/>; the app's own
    /// copies are untouched. A name already taken there gets an
    /// Explorer-style " (2)" suffix rather than being overwritten. Returns
    /// how many were copied.
    public static int Export(IEnumerable<Recording> recordings, string folder)
    {
        var copied = 0;
        foreach (var recording in recordings)
        {
            var destination = Path.Combine(folder, recording.Name + ".wav");
            for (var n = 2; File.Exists(destination); n++)
            {
                destination = Path.Combine(folder, $"{recording.Name} ({n}).wav");
            }
            try
            {
                File.Copy(recording.Path, destination);
                copied++;
            }
            catch (Exception ex)
            {
                AppLog.Write($"recordings: couldn't export {recording.Name}: {ex.Message}");
            }
        }
        return copied;
    }
}
