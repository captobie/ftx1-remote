using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

/// The CW page's PLAY — the Mac's RecordingsListView: every recording in
/// the Recordings folder (the CW page's RECORD and the WebSDR window's
/// Record), newest first, each with play/stop, rename and delete, plus
/// check boxes for Export Selected / Delete Selected, and Delete All. Its
/// own window, like the APRS lists, so it can stay open beside the main
/// one. A plain file browser: nothing here needs the rig.
///
/// Reloads from the folder when it opens or is activated, on Refresh, after
/// its own changes, and when a file appears, disappears or is renamed
/// (a FileSystemWatcher on names only, so a recording being written doesn't
/// rebuild the list on every block). Windows additions to the Mac's: Open
/// Folder, and the row of the recording being made shows as such.
public sealed class RecordingsWindow : Window
{
    private readonly AudioRecorder _recorder;
    private readonly RecordingPlayer _player;
    private readonly Grid _root = new() { Padding = new Thickness(12), RowSpacing = 8 };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBlock _countText = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray), VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _emptyPanel = new() { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420 };
    private readonly Button _exportSelectedButton = new();
    private readonly Button _deleteSelectedButton = new();
    private readonly Button _deleteAllButton = new();
    private readonly FileSystemWatcher? _watcher;
    private bool _reloadScheduled;

    private List<Recording> _recordings = [];
    /// Checked rows, by path — reloads drop paths that are gone (deleted or
    /// renamed), as the Mac's selection does.
    private readonly HashSet<string> _selection = new(StringComparer.OrdinalIgnoreCase);

    private static readonly SolidColorBrush Gray = new(Microsoft.UI.Colors.Gray);

    public RecordingsWindow(AudioRecorder recorder)
    {
        _recorder = recorder;
        _player = new RecordingPlayer(DispatcherQueue);
        _player.Changed += Rebuild;
        Title = "Recordings";
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(760 * scale), (int)(480 * scale)));

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var toolbar = new Grid();
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(_countText);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        // Shown only while something's checked, as on the Mac.
        SetContent(_exportSelectedButton, "", "Export Selected");
        _exportSelectedButton.Click += async (_, _) => await ExportSelectedAsync();
        SetContent(_deleteSelectedButton, "", "Delete Selected");
        _deleteSelectedButton.Click += async (_, _) => await DeleteSelectedAsync();
        SetContent(_deleteAllButton, "", "Delete All");
        _deleteAllButton.Click += async (_, _) => await DeleteAllAsync();
        var refreshButton = new Button();
        SetContent(refreshButton, "", "Refresh");
        refreshButton.Click += (_, _) => Reload();
        var folderButton = new Button();
        SetContent(folderButton, "", "Open Folder");
        ToolTipService.SetToolTip(folderButton, "Show the Recordings folder in File Explorer");
        folderButton.Click += (_, _) => OpenFolder();
        buttons.Children.Add(_exportSelectedButton);
        buttons.Children.Add(_deleteSelectedButton);
        buttons.Children.Add(_deleteAllButton);
        buttons.Children.Add(refreshButton);
        buttons.Children.Add(folderButton);
        Grid.SetColumn(buttons, 1);
        toolbar.Children.Add(buttons);
        _root.Children.Add(toolbar);

        _emptyPanel.Children.Add(new TextBlock
        {
            Text = "No Recordings Yet",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        _emptyPanel.Children.Add(new TextBlock
        {
            Text = "Recordings made with the CW page's RECORD button or the WebSDR window's Record button will appear here.",
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            Foreground = Gray,
        });
        Grid.SetRow(_list, 1);
        Grid.SetRow(_emptyPanel, 1);
        _root.Children.Add(_list);
        _root.Children.Add(_emptyPanel);

        Content = _root;
        ApplyTheme();

        try
        {
            _watcher = new FileSystemWatcher(Recordings.Directory, "*.wav") { NotifyFilter = NotifyFilters.FileName };
            _watcher.Created += (_, _) => ScheduleReload();
            _watcher.Deleted += (_, _) => ScheduleReload();
            _watcher.Renamed += (_, _) => ScheduleReload();
            _watcher.EnableRaisingEvents = true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"recordings: can't watch the folder: {ex.Message}");
        }

        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated)
            {
                Reload();
            }
        };
        Closed += (_, _) =>
        {
            _watcher?.Dispose();
            _player.Changed -= Rebuild;
            _player.Dispose();
        };
        Reload();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        _root.RequestedTheme = AppSettings.Theme.ElementTheme();
        _root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
    }

    /// Re-reads the folder. MainWindow also calls this when RECORD starts or
    /// stops, so the new file's row and length are current.
    public void Reload()
    {
        _recordings = Recordings.List();
        _selection.IntersectWith(_recordings.Select(r => r.Path));
        Rebuild();
    }

    /// Coalesces a burst of watcher events (they arrive on a worker thread).
    private void ScheduleReload()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_reloadScheduled)
            {
                return;
            }
            _reloadScheduled = true;
            var timer = DispatcherQueue.CreateTimer();
            timer.Interval = TimeSpan.FromMilliseconds(300);
            timer.IsRepeating = false;
            timer.Tick += (_, _) =>
            {
                _reloadScheduled = false;
                Reload();
            };
            timer.Start();
        });
    }

    private void Rebuild()
    {
        _list.Items.Clear();
        var recordingPath = _recorder.CurrentPath;
        foreach (var recording in _recordings)
        {
            _list.Items.Add(Row(recording, isBeingRecorded: string.Equals(recording.Path, recordingPath, StringComparison.OrdinalIgnoreCase)));
        }
        var count = _recordings.Count;
        _countText.Text = count == 0 ? "" : $"{count} recording{(count == 1 ? "" : "s")}";
        _emptyPanel.Visibility = count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _deleteAllButton.IsEnabled = count > 0;
        var selected = _selection.Count;
        _exportSelectedButton.Visibility = _deleteSelectedButton.Visibility =
            selected > 0 ? Visibility.Visible : Visibility.Collapsed;
        SetContent(_exportSelectedButton, "", $"Export Selected ({selected})");
        SetContent(_deleteSelectedButton, "", $"Delete Selected ({selected})");
    }

    private Grid Row(Recording recording, bool isBeingRecorded)
    {
        var isPlaying = string.Equals(_player.PlayingPath, recording.Path, StringComparison.OrdinalIgnoreCase);
        var row = new Grid { ColumnSpacing = 6 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var check = new CheckBox
        {
            IsChecked = _selection.Contains(recording.Path),
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(check, $"Select {recording.Name}");
        check.Click += (_, _) =>
        {
            if (check.IsChecked == true)
            {
                _selection.Add(recording.Path);
            }
            else
            {
                _selection.Remove(recording.Path);
            }
            Rebuild();
        };
        row.Children.Add(check);

        var play = IconButton(isPlaying ? "" : "", isPlaying ? "Stop" : "Play");
        play.IsEnabled = !isBeingRecorded;
        play.Click += async (_, _) =>
        {
            if (isPlaying)
            {
                _player.Stop();
            }
            else if (_player.Play(recording) is { } error)
            {
                await ShowMessageAsync("Can't Play", error);
            }
        };
        Grid.SetColumn(play, 1);
        row.Children.Add(play);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { Text = recording.Name, TextTrimming = TextTrimming.CharacterEllipsis };
        ToolTipService.SetToolTip(name, recording.Name);
        text.Children.Add(name);
        var detail = isBeingRecorded
            ? "Recording…"
            : $"{recording.Date.ToString("g", CultureInfo.CurrentCulture)} · {DurationLabel(recording.Duration)}";
        text.Children.Add(new TextBlock { Text = detail, FontSize = 12, Foreground = isBeingRecorded ? new SolidColorBrush(Microsoft.UI.Colors.Firebrick) : Gray });
        Grid.SetColumn(text, 2);
        row.Children.Add(text);

        var rename = IconButton("", "Rename");
        rename.IsEnabled = !isBeingRecorded;
        rename.Click += async (_, _) => await RenameAsync(recording);
        Grid.SetColumn(rename, 3);
        row.Children.Add(rename);

        var delete = IconButton("", "Delete");
        delete.IsEnabled = !isBeingRecorded;
        delete.Click += (_, _) =>
        {
            if (isPlaying)
            {
                _player.Stop();
            }
            Recordings.Delete(recording);
            _selection.Remove(recording.Path);
            Reload();
        };
        Grid.SetColumn(delete, 4);
        row.Children.Add(delete);
        return row;
    }

    private async Task RenameAsync(Recording recording)
    {
        if (string.Equals(_player.PlayingPath, recording.Path, StringComparison.OrdinalIgnoreCase))
        {
            _player.Stop();
        }
        var box = new TextBox { Text = recording.Name, MinWidth = 420 };
        box.SelectAll();
        var dialog = Dialog("Rename Recording", box);
        dialog.PrimaryButtonText = "Rename";
        dialog.CloseButtonText = "Cancel";
        dialog.DefaultButton = ContentDialogButton.Primary;
        if (await ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        if (Recordings.Rename(recording, box.Text) is { } error)
        {
            await ShowMessageAsync("Can't Rename", error);
        }
        Reload();
    }

    private async Task DeleteSelectedAsync()
    {
        var count = _selection.Count;
        if (count == 0 || !await ConfirmAsync($"Delete {count} selected recording{(count == 1 ? "" : "s")}? This can't be undone.", "Delete Selected"))
        {
            return;
        }
        if (_player.PlayingPath is { } playing && _selection.Contains(playing))
        {
            _player.Stop();
        }
        foreach (var recording in _recordings.Where(r => _selection.Contains(r.Path)).ToList())
        {
            Recordings.Delete(recording);
        }
        _selection.Clear();
        Reload();
    }

    /// Spares the recording being made, which RECORD is still writing.
    private async Task DeleteAllAsync()
    {
        var count = _recordings.Count;
        if (count == 0 || !await ConfirmAsync($"Delete all {count} recordings? This can't be undone.", "Delete All"))
        {
            return;
        }
        _player.Stop();
        var recordingPath = _recorder.CurrentPath;
        foreach (var recording in Recordings.List())
        {
            if (!string.Equals(recording.Path, recordingPath, StringComparison.OrdinalIgnoreCase))
            {
                Recordings.Delete(recording);
            }
        }
        _selection.Clear();
        Reload();
    }

    private async Task ExportSelectedAsync()
    {
        var toExport = _recordings.Where(r => _selection.Contains(r.Path)).ToList();
        if (toExport.Count == 0)
        {
            return;
        }
        var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(AppWindow.Id)
        {
            CommitButtonText = "Export",
        };
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null)
        {
            return;
        }
        var copied = Recordings.Export(toExport, folder.Path);
        var noun = toExport.Count == 1 ? "recording" : "recordings";
        var leaf = Path.GetFileName(folder.Path.TrimEnd('\\'));
        await ShowMessageAsync("Export Complete", $"Exported {copied} of {toExport.Count} {noun} to {(leaf.Length > 0 ? leaf : folder.Path)}.");
    }

    private static void OpenFolder()
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Recordings.Directory}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Write($"recordings: couldn't open the folder: {ex.Message}");
        }
    }

    // Dialogs

    private ContentDialog Dialog(string title, object content) => new()
    {
        Title = title,
        Content = content,
        XamlRoot = _root.XamlRoot,
        RequestedTheme = _root.RequestedTheme,
    };

    private async Task<bool> ConfirmAsync(string message, string action)
    {
        var dialog = Dialog(action, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        dialog.PrimaryButtonText = action;
        dialog.CloseButtonText = "Cancel";
        dialog.DefaultButton = ContentDialogButton.Close;
        return await ShowAsync(dialog) == ContentDialogResult.Primary;
    }

    private async Task ShowMessageAsync(string title, string message)
    {
        var dialog = Dialog(title, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        dialog.CloseButtonText = "OK";
        await ShowAsync(dialog);
    }

    /// Only one ContentDialog can be open per window; a second just doesn't
    /// show.
    private static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        try
        {
            return await dialog.ShowAsync();
        }
        catch (COMException)
        {
            return ContentDialogResult.None;
        }
    }

    // Helpers

    private static Button IconButton(string glyph, string name)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Padding = new Thickness(8, 6, 8, 6),
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(button, name);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        return button;
    }

    private static void SetContent(Button button, string glyph, string text)
    {
        button.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                new FontIcon { Glyph = glyph, FontSize = 14 },
                new TextBlock { Text = text },
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, text);
    }

    private static string DurationLabel(TimeSpan duration) =>
        $"{(int)duration.TotalMinutes}:{duration.Seconds:00}";

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
