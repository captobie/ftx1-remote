using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

/// "Manage Favorites…" from the WebSDR window's Favorites menu — the Mac's
/// WebSDRFavoritesView: rename (click a name and type), reorder, and remove
/// saved stations. Reordering is per-row up/down buttons rather than the
/// Mac's drag: a ListView's drag-reorder didn't take with a name TextBox in
/// every row, and buttons work from the keyboard too. Adding happens elsewhere — the star next to the
/// host field, or the Stations window's star column.
public sealed class WebSdrFavoritesDialog : ContentDialog
{
    private readonly WebSdrFollowModel _model;
    private readonly ListView _list = new()
    {
        SelectionMode = ListViewSelectionMode.None,
        Height = 320,
    };
    /// Rows in the list, keyed by favorite id, with their name box.
    private readonly Dictionary<string, TextBox> _nameBoxes = [];

    public WebSdrFavoritesDialog(XamlRoot root, ElementTheme theme, WebSdrFollowModel model)
    {
        _model = model;
        XamlRoot = root;
        RequestedTheme = theme;
        Title = "Favorites";
        CloseButtonText = "Done";
        DefaultButton = ContentDialogButton.None;
        Resources["ContentDialogMaxWidth"] = 640.0;

        var panel = new StackPanel { Spacing = 8, Width = 560 };
        panel.Children.Add(_list);
        panel.Children.Add(new TextBlock
        {
            Text = "Click a name to rename it; use the arrows to reorder.",
            FontSize = 12,
            Foreground = new SolidColorBrush(Colors.Gray),
        });
        Content = panel;

        // Done (or Escape) without Enter still keeps an edit.
        Closing += (_, _) => CommitAll();
        Rebuild();
    }

    private void CommitAll()
    {
        foreach (var (id, box) in _nameBoxes)
        {
            _model.RenameFavorite(id, box.Text);
        }
    }

    private void Rebuild()
    {
        _list.Items.Clear();
        _nameBoxes.Clear();
        for (var i = 0; i < _model.Favorites.Count; i++)
        {
            _list.Items.Add(Row(_model.Favorites[i], i));
        }
        if (_model.Favorites.Count == 0)
        {
            _list.Items.Add(new TextBlock { Text = "No favorites. Star a station to add it.", Foreground = new SolidColorBrush(Colors.Gray), Tag = "" });
        }
    }

    /// Name editable in place (committed on Enter, on leaving the field, or
    /// when the dialog closes); platform, host, location and range
    /// underneath for telling similar names apart.
    private Grid Row(WebSdrFavorite favorite, int index)
    {
        var row = new Grid { Tag = favorite.Id, ColumnSpacing = 4, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var fields = new StackPanel { Spacing = 2 };
        var name = new TextBox { Text = favorite.Name, BorderThickness = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(name, "Name");
        name.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                _model.RenameFavorite(favorite.Id, name.Text);
            }
        };
        name.LostFocus += (_, _) => _model.RenameFavorite(favorite.Id, name.Text);
        _nameBoxes[favorite.Id] = name;
        fields.Children.Add(name);

        var parts = new List<string>();
        if (favorite.Platform is { } platform)
        {
            parts.Add(platform.DisplayName());
        }
        parts.Add(favorite.HostPort);
        if (favorite.Location.Length > 0)
        {
            parts.Add(favorite.Location);
        }
        parts.Add(favorite.BandRanges is { } bands
            ? FrequencyRange.Describe(bands)
            : favorite.Platform == SdrPlatform.WebSdr ? "range read on next connect" : "0–30 MHz (range unknown)");
        var details = string.Join(" · ", parts);
        var detailsText = new TextBlock
        {
            Text = details,
            FontSize = 12,
            Foreground = new SolidColorBrush(Colors.Gray),
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(12, 0, 0, 0),
        };
        ToolTipService.SetToolTip(detailsText, details);
        fields.Children.Add(detailsText);
        row.Children.Add(fields);

        AddButton(row, 1, "", "Move up", index > 0, () => Move(index, index - 1));
        AddButton(row, 2, "", "Move down", index < _model.Favorites.Count - 1, () => Move(index, index + 1));
        AddButton(row, 3, "", "Remove from Favorites", true, () =>
        {
            CommitAll();
            _model.RemoveFavorite(favorite.HostPort);
            Rebuild();
        });
        return row;
    }

    private static void AddButton(Grid row, int column, string glyph, string name, bool enabled, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            VerticalAlignment = VerticalAlignment.Center,
            IsEnabled = enabled,
        };
        ToolTipService.SetToolTip(button, name);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        button.Click += (_, _) => action();
        Grid.SetColumn(button, column);
        row.Children.Add(button);
    }

    private void Move(int from, int to)
    {
        CommitAll();
        var ids = _model.Favorites.Select(f => f.Id).ToList();
        var id = ids[from];
        ids.RemoveAt(from);
        ids.Insert(to, id);
        _model.ReorderFavorites(ids);
        Rebuild();
    }
}
