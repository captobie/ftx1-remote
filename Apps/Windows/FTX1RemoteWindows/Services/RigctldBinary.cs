using System.ComponentModel;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace FTX1RemoteWindows.Services;

/// Which rigctld.exe Local mode launches, and how that choice is turned
/// into a path — port of Apps/Mac/FTX1RemoteMac/RigctldBinary.swift (see
/// Apps/Windows/README.md, "Bundled rigctld").
///
/// The app ships Hamlib's official Windows rigctld.exe in hamlib\ next to
/// the exe as a fallback: the FTX-1 (model 1051) first appears in Hamlib
/// 4.7, and an older installed rigctld just exits at once when started with
/// it. Automatic prefers a suitable installed copy (it may be newer, with
/// backend fixes) and falls back to the built-in one.
///
/// The probes run external processes: call Resolve/Probe off the UI thread
/// (they're async and don't capture a context).
public static partial class RigctldBinary
{
    /// What AppSettings.RigctldChoice stores: Automatic, BuiltIn, or an
    /// explicit path (used as is, even if too old — with a warning in
    /// Settings).
    public sealed record Choice
    {
        public static readonly Choice Automatic = new("automatic");
        public static readonly Choice BuiltIn = new("builtin");

        public static Choice ForPath(string path) => new(path);

        private Choice(string storedValue) => StoredValue = storedValue;

        public string StoredValue { get; }

        public bool IsAutomatic => StoredValue == Automatic.StoredValue;
        public bool IsBuiltIn => StoredValue == BuiltIn.StoredValue;
        /// The explicit path, or null for Automatic/BuiltIn.
        public string? ExplicitPath => IsAutomatic || IsBuiltIn ? null : StoredValue;

        public static Choice FromStored(string? stored) => stored switch
        {
            null or "" or "automatic" => Automatic,
            "builtin" => BuiltIn,
            _ => ForPath(stored),
        };
    }

    /// The oldest Hamlib with the FTX-1 backend.
    public static readonly HamlibVersion MinimumVersion = new(4, 7, 0);

    public static string BuiltInPath => Path.Combine(AppContext.BaseDirectory, "hamlib", "rigctld.exe");

    /// Where Automatic looks, in order: the rigctld.exe PATH resolves to,
    /// Hamlib's installer folders (C:\Program Files[ (x86)]\hamlib*\bin,
    /// newest version first, from the folder name), and C:\Tools\hamlib\bin.
    /// Only existing files, without duplicates.
    ///
    /// Debug builds honour FTX1REMOTE_RIGCTLD_SEARCH_PATHS (semicolon-
    /// separated rigctld.exe paths; missing files are skipped, so "none"
    /// means no installed copy — an empty variable is the same as unset on
    /// Windows) instead: the way to test the fallback without touching the
    /// installed Hamlib, e.g. $env:FTX1REMOTE_RIGCTLD_SEARCH_PATHS = "none"
    /// before launching the app.
    public static IReadOnlyList<string> SearchPaths()
    {
#if DEBUG
        var overridePaths = Environment.GetEnvironmentVariable(SearchPathsOverrideVariable);
        if (overridePaths is not null)
        {
            return overridePaths.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(File.Exists)
                .ToList();
        }
#endif
        var candidates = new List<string>();
        if (FindOnPath() is { } onPath)
        {
            candidates.Add(onPath);
        }
        var installerDirs = new[]
            {
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            }
            .Where(root => root.Length > 0 && Directory.Exists(root))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .SelectMany(root =>
            {
                try
                {
                    return Directory.EnumerateDirectories(root, "hamlib*");
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    return [];
                }
            })
            .OrderByDescending(dir => HamlibVersion.ParseLoose(Path.GetFileName(dir)) ?? new HamlibVersion(0, 0, 0));
        candidates.AddRange(installerDirs.Select(dir => Path.Combine(dir, "bin", "rigctld.exe")));
        candidates.Add(@"C:\Tools\hamlib\bin\rigctld.exe");
        return candidates
            .Where(File.Exists)
            .Select(Path.GetFullPath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

#if DEBUG
    public const string SearchPathsOverrideVariable = "FTX1REMOTE_RIGCTLD_SEARCH_PATHS";
#endif

    private static string? FindOnPath()
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), "rigctld.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (ArgumentException)
            {
                // A malformed PATH entry.
            }
        }
        return null;
    }

    public static string RigName(int model) => model == 1051 ? "the FTX-1" : $"model {model}";

    // --- Probing ---

    public sealed record Probe(string Path)
    {
        /// What --version printed, without the "rigctld " prefix, e.g.
        /// "Hamlib 4.7.2 2026-06-21T13:07:37Z SHA=40f63488f 64-bit".
        public string? VersionLine { get; init; }
        public HamlibVersion? Version { get; init; }
        /// Whether "rigctld -l" lists the model; null if -l didn't run.
        public bool? ListsModel { get; init; }

        public string ShortVersion => Version is { } v ? $"Hamlib {v}" : "unknown version";

        public bool IsSuitable => Version is { } v && v >= MinimumVersion && ListsModel == true;

        /// Why this copy can't drive the rig, or null if it can.
        public string? Problem(int model)
        {
            if (VersionLine is null) return $"{Path} didn't answer --version";
            if (Version is not { } v) return $"{Path} reported no Hamlib version";
            if (v < MinimumVersion) return $"{Path} is {v}, too old for {RigName(model)}";
            if (ListsModel != true) return $"{Path} ({v}) doesn't list {RigName(model)}";
            return null;
        }
    }

    /// Runs --version and -l on `path`, capped at 3 s and 5 s so a binary
    /// that hangs can't stall the connect.
    public static async Task<Probe> ProbeAsync(string path, int model)
    {
        var result = new Probe(path);
        var versionOutput = await RunAsync(path, "--version", TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        if (versionOutput is null)
        {
            return result;
        }
        var line = FirstLine(versionOutput);
        result = result with
        {
            VersionLine = line.StartsWith("rigctld ", StringComparison.Ordinal) ? line["rigctld ".Length..] : line,
            Version = HamlibVersion.Parse(line),
        };
        if (await RunAsync(path, "-l", TimeSpan.FromSeconds(5)).ConfigureAwait(false) is { } list)
        {
            var modelText = model.ToString();
            result = result with
            {
                // "  1051  Yaesu  FTX-1  …": the model number is the first field.
                ListsModel = list.Split('\n').Any(l => l.TrimStart().Split(' ', '\t', '\r')[0] == modelText),
            };
        }
        return result;
    }

    private static string FirstLine(string output) =>
        output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? "";

    // --- Resolution ---

    /// <param name="Path">What to launch; null only when the built-in copy
    /// is missing from the app folder.</param>
    /// <param name="Summary">One sentence for Settings and the log, e.g.
    /// "Using built-in Hamlib 4.7.2 — C:\Tools\hamlib\bin\rigctld.exe is
    /// 4.5.5, too old for the FTX-1."</param>
    /// <param name="Warning">Set when an explicitly chosen copy looks unable
    /// to drive the rig.</param>
    public sealed record Resolution(string? Path, bool IsBuiltIn, string Summary, string? Warning = null);

    public static async Task<Resolution> ResolveAsync(Choice choice, int model)
    {
        if (choice.IsAutomatic)
        {
            var rejected = new List<string>();
            foreach (var path in SearchPaths())
            {
                var probe = await ProbeAsync(path, model).ConfigureAwait(false);
                if (probe.IsSuitable)
                {
                    var skipped = rejected.Count == 0 ? "" : " — " + string.Join("; ", rejected);
                    return new Resolution(path, false, $"Using installed {path} ({probe.ShortVersion}){skipped}.");
                }
                rejected.Add(probe.Problem(model) ?? $"{path} is unusable");
            }
            var because = rejected.Count == 0 ? "no installed rigctld found" : string.Join("; ", rejected);
            return await BuiltInAsync(because).ConfigureAwait(false);
        }
        if (choice.IsBuiltIn)
        {
            return await BuiltInAsync("chosen in Settings").ConfigureAwait(false);
        }

        var chosen = choice.ExplicitPath!;
        if (!File.Exists(chosen))
        {
            return new Resolution(chosen, false, $"Using {chosen} (chosen in Settings).", "No rigctld.exe at this path.");
        }
        var chosenProbe = await ProbeAsync(chosen, model).ConfigureAwait(false);
        return new Resolution(chosen, false,
            $"Using {chosen} ({chosenProbe.ShortVersion}, chosen in Settings).",
            chosenProbe.Problem(model) is { } problem ? $"{problem}. Automatic would use a newer copy or the built-in one." : null);
    }

    private static async Task<Resolution> BuiltInAsync(string reason)
    {
        var path = BuiltInPath;
        if (!File.Exists(path))
        {
            return new Resolution(null, true,
                $"No usable rigctld: the built-in copy is missing from the app folder ({reason}).",
                "Reinstall FTX1Remote, or install Hamlib 4.7 or later.");
        }
        var version = await BuiltInVersionAsync().ConfigureAwait(false);
        return new Resolution(path, true,
            $"Using built-in {(version is { } v ? $"Hamlib {v}" : "rigctld")} — {reason}.");
    }

    private static readonly Lazy<Task<HamlibVersion?>> BuiltInVersion = new(async () =>
    {
        var output = await RunAsync(BuiltInPath, "--version", TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        return output is null ? null : HamlibVersion.Parse(output);
    });

    /// The bundled copy's version, read once per launch.
    public static Task<HamlibVersion?> BuiltInVersionAsync() => BuiltInVersion.Value;

    /// Runs `path` with one argument and returns its stdout+stderr, or null
    /// if it couldn't be started, exited non-zero, or was still running
    /// after `timeout` (then it's killed).
    public static async Task<string?> RunAsync(string path, string argument, TimeSpan timeout)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = path,
                ArgumentList = { argument },
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
            },
        };
        try
        {
            process.Start();
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            return null;
        }
        process.StandardInput.Close();
        // Both pipes read concurrently: -l prints ~50 KB, more than a pipe
        // buffer holds.
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
            {
                // Exited meanwhile.
            }
            return null;
        }
        var output = await stdout.ConfigureAwait(false) + await stderr.ConfigureAwait(false);
        return process.ExitCode == 0 ? output : null;
    }
}

/// A Hamlib release number, parsed out of e.g. "rigctld Hamlib 4.7.2 …".
/// A missing patch number reads as 0. Port of the Mac's HamlibVersion.
public readonly partial record struct HamlibVersion(int Major, int Minor, int Patch) : IComparable<HamlibVersion>
{
    public static HamlibVersion? Parse(string text) => FromMatch(HamlibPattern().Match(text));

    /// Any "x.y[.z]" in `text` — for Hamlib's installer folder names like
    /// "hamlib-w64-4.7.2".
    public static HamlibVersion? ParseLoose(string text) => FromMatch(BarePattern().Match(text));

    private static HamlibVersion? FromMatch(Match match) =>
        match.Success
            ? new HamlibVersion(int.Parse(match.Groups[1].Value), int.Parse(match.Groups[2].Value),
                match.Groups[3].Success ? int.Parse(match.Groups[3].Value) : 0)
            : null;

    [GeneratedRegex(@"Hamlib\s+(\d+)\.(\d+)(?:\.(\d+))?")]
    private static partial Regex HamlibPattern();

    [GeneratedRegex(@"(\d+)\.(\d+)(?:\.(\d+))?")]
    private static partial Regex BarePattern();

    public int CompareTo(HamlibVersion other) =>
        (Major, Minor, Patch).CompareTo((other.Major, other.Minor, other.Patch));

    public static bool operator <(HamlibVersion a, HamlibVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(HamlibVersion a, HamlibVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(HamlibVersion a, HamlibVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(HamlibVersion a, HamlibVersion b) => a.CompareTo(b) >= 0;

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}
