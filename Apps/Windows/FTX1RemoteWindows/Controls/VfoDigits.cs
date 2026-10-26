using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

/// Draws a VFO box's frequency in the theme's font. The frequency
/// TextBlock stays where it is — every caller sets its Text, and it's the
/// VFO entry flyout's click target and anchor. In the 7-segment font it
/// turns transparent and two TextBlocks over it (same Grid cell, not
/// hit-testable) draw the unlit segments and the lit digits, following its
/// Text.
public sealed class VfoDigits
{
    private const double FontSize = 32;
    /// DSEG7 is taller than Consolas for its size; this keeps the box's
    /// height about what it was.
    private const double SevenSegmentSize = 27;

    private static readonly FontFamily Consolas = new("Consolas");
    private static readonly FontFamily CascadiaMono = new("Cascadia Mono");
    private static readonly FontFamily SevenSegmentRegular = new("ms-appx:///Assets/Fonts/DSEG7Classic-Regular.ttf#DSEG7 Classic");
    private static readonly FontFamily SevenSegmentBold = new("ms-appx:///Assets/Fonts/DSEG7Classic-Bold.ttf#DSEG7 Classic");

    private readonly TextBlock _source;
    private readonly TextBlock _unlit;
    private readonly TextBlock _lit;
    private bool _sevenSegment;

    /// panel: source's parent (TextBlock.Parent is still null while the
    /// window is being built).
    public VfoDigits(TextBlock source, Panel panel)
    {
        _source = source;
        _unlit = Overlay();
        _lit = Overlay();
        var index = panel.Children.IndexOf(source);
        panel.Children.Insert(index + 1, _unlit);
        panel.Children.Insert(index + 2, _lit);
        source.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => Update());

        TextBlock Overlay()
        {
            var block = new TextBlock
            {
                HorizontalAlignment = source.HorizontalAlignment,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
                Visibility = Visibility.Collapsed,
                TextLineBounds = TextLineBounds.Tight,
            };
            Grid.SetRow(block, Grid.GetRow(source));
            Grid.SetColumn(block, Grid.GetColumn(source));
            return block;
        }
    }

    public void Apply(VfoTheme theme, VfoDigitFont font)
    {
        var digits = new SolidColorBrush(ThemeEngine.ToColor(theme.Digits));
        var weight = theme.DigitsBold ? FontWeights.Bold : FontWeights.Normal;
        _sevenSegment = font == VfoDigitFont.SevenSegment;
        if (_sevenSegment)
        {
            var family = theme.DigitsBold ? SevenSegmentBold : SevenSegmentRegular;
            _source.Foreground = new SolidColorBrush(Colors.Transparent);
            _lit.FontFamily = _unlit.FontFamily = family;
            _lit.FontWeight = _unlit.FontWeight = weight;
            _lit.FontSize = _unlit.FontSize = SevenSegmentSize;
            _lit.Foreground = digits;
            _unlit.Foreground = new SolidColorBrush(theme.UnlitSegments is { } unlit ? ThemeEngine.ToColor(unlit) : Colors.Transparent);
            _unlit.Visibility = theme.UnlitSegments is null ? Visibility.Collapsed : Visibility.Visible;
            _lit.Visibility = Visibility.Visible;
        }
        else
        {
            _source.FontFamily = font == VfoDigitFont.CascadiaMono ? CascadiaMono : Consolas;
            _source.FontWeight = weight;
            _source.FontSize = FontSize;
            _source.Foreground = digits;
            _lit.Visibility = _unlit.Visibility = Visibility.Collapsed;
        }
        Update();
    }

    private void Update()
    {
        if (!_sevenSegment)
        {
            return;
        }
        _lit.Text = SevenSegmentText.Lit(_source.Text);
        _unlit.Text = SevenSegmentText.Unlit(_lit.Text);
    }
}
