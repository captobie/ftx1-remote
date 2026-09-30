using System.Runtime.InteropServices.WindowsRuntime;
using FTX1RemoteWindows.Services;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace FTX1RemoteWindows.Controls;

/// Port of the Mac's ScopeDisplayView plus the drawing half of
/// AudioCaptureEngine (WaterfallBitmap, WaterfallPalette,
/// OscilloscopeRenderer): a black rounded box showing either a scrolling
/// waterfall (newest row at the top, BinCount × HistoryRows pixels
/// stretched to the box) or a green oscilloscope trace. Frames come from
/// ScopeProcessor via MainWindow. Both are updated on every frame so
/// switching modes is instant, as on the Mac. Dims while disconnected.
public sealed class ScopeDisplay : UserControl
{
    private const int HistoryRows = 150;
    private const int Columns = ScopeProcessor.BinCount;

    /// BGRA8 pixels, persistent: each row scrolls the lot down by one
    /// (one block copy) and colors only the new row through the palette
    /// table — the Mac's WaterfallBitmap, for the same reason (per-pixel
    /// recoloring every frame was measurably expensive there).
    private readonly byte[] _pixels = new byte[Columns * HistoryRows * 4];
    private readonly WriteableBitmap _bitmap = new(Columns, HistoryRows);
    private readonly Image _waterfall;
    private readonly Canvas _traceCanvas = new();
    private readonly Polyline _trace = new()
    {
        Stroke = new SolidColorBrush(Color.FromArgb(255, 51, 255, 102)),
        StrokeThickness = 1.5,
    };
    private float[]? _lastTrace;
    private ScopeDisplayMode _mode = ScopeDisplayMode.Waterfall;

    public ScopeDisplay()
    {
        ClearPixels();
        _waterfall = new Image { Source = _bitmap, Stretch = Stretch.Fill };
        _traceCanvas.Children.Add(_trace);
        _traceCanvas.SizeChanged += (_, _) => DrawTrace();

        var content = new Grid();
        content.Children.Add(_waterfall);
        content.Children.Add(_traceCanvas);
        var border = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Colors.Black),
            BorderBrush = new SolidColorBrush(Color.FromArgb(102, 128, 128, 128)),
            BorderThickness = new Thickness(1.5),
            Padding = new Thickness(1.5),
            Child = content,
        };
        // Keep the square bitmap corners inside the rounded border.
        content.SizeChanged += (_, e) => content.Clip = new RectangleGeometry
        {
            Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height),
        };
        Content = border;
        AutomationProperties.SetName(this, "Waterfall and oscilloscope display");
        ApplyMode();
        SetActive(false);
    }

    public ScopeDisplayMode Mode
    {
        get => _mode;
        set
        {
            _mode = value;
            ApplyMode();
        }
    }

    public void SetActive(bool active) => Opacity = active ? 1 : 0.4;

    /// Adds one waterfall row and replaces the trace.
    public void Show(ScopeFrame frame)
    {
        AppendRow(frame.WaterfallRow);
        _lastTrace = frame.Oscilloscope;
        if (_mode == ScopeDisplayMode.Oscilloscope)
        {
            DrawTrace();
        }
    }

    /// Blank: audio stopped, disconnected, or the display turned Off.
    public void Clear()
    {
        ClearPixels();
        _lastTrace = null;
        DrawTrace();
    }

    private void ApplyMode()
    {
        _waterfall.Visibility = _mode == ScopeDisplayMode.Waterfall ? Visibility.Visible : Visibility.Collapsed;
        _traceCanvas.Visibility = _mode == ScopeDisplayMode.Oscilloscope ? Visibility.Visible : Visibility.Collapsed;
        DrawTrace();
    }

    private void AppendRow(float[] row)
    {
        const int rowBytes = Columns * 4;
        Buffer.BlockCopy(_pixels, 0, _pixels, rowBytes, _pixels.Length - rowBytes);
        for (var x = 0; x < Columns && x < row.Length; x++)
        {
            var color = WaterfallPalette.Lut[WaterfallPalette.Index(row[x])];
            var o = x * 4;
            _pixels[o] = color.B;
            _pixels[o + 1] = color.G;
            _pixels[o + 2] = color.R;
            _pixels[o + 3] = 255;
        }
        Flush();
    }

    private void ClearPixels()
    {
        var black = WaterfallPalette.Lut[0];
        for (var o = 0; o < _pixels.Length; o += 4)
        {
            _pixels[o] = black.B;
            _pixels[o + 1] = black.G;
            _pixels[o + 2] = black.R;
            _pixels[o + 3] = 255;
        }
        Flush();
    }

    private void Flush()
    {
        using (var stream = _bitmap.PixelBuffer.AsStream())
        {
            stream.Write(_pixels, 0, _pixels.Length);
        }
        _bitmap.Invalidate();
    }

    /// The trace in the canvas's own pixels (not a stretched Viewbox), so
    /// the line stays 1.5 px whatever the box's aspect.
    private void DrawTrace()
    {
        var points = new PointCollection();
        var w = _traceCanvas.ActualWidth;
        var h = _traceCanvas.ActualHeight;
        if (_lastTrace is { Length: > 1 } trace && w > 0 && h > 0 && _mode == ScopeDisplayMode.Oscilloscope)
        {
            var mid = h / 2;
            var step = w / (trace.Length - 1);
            for (var x = 0; x < trace.Length; x++)
            {
                points.Add(new Point(x * step, mid - trace[x] * mid));
            }
        }
        _trace.Points = points;
    }
}

/// Intensity → color: black (no signal) through blue, cyan, green, yellow
/// to red — the Mac's WaterfallPalette stops, quantized to a 256-entry
/// table built once.
internal static class WaterfallPalette
{
    private static readonly (float Threshold, byte R, byte G, byte B)[] Stops =
    [
        (0.00f, 0, 0, 0),
        (0.25f, 0, 0, 180),
        (0.50f, 0, 180, 180),
        (0.75f, 0, 220, 0),
        (0.90f, 255, 220, 0),
        (1.00f, 255, 40, 0),
    ];

    public static readonly Color[] Lut = Enumerable.Range(0, 256).Select(i => ColorFor(i / 255f)).ToArray();

    /// Clamps (so NaN or out-of-range can't index out of bounds) and rounds
    /// to the nearest of the table's steps.
    public static int Index(float value)
    {
        var clamped = float.IsNaN(value) ? 0 : Math.Clamp(value, 0, 1);
        return (int)(clamped * 255 + 0.5f);
    }

    private static Color ColorFor(float value)
    {
        var lower = Stops[0];
        var upper = Stops[^1];
        for (var i = 0; i < Stops.Length - 1; i++)
        {
            if (value <= Stops[i + 1].Threshold)
            {
                lower = Stops[i];
                upper = Stops[i + 1];
                break;
            }
        }
        var span = upper.Threshold - lower.Threshold;
        var t = span > 0 ? (value - lower.Threshold) / span : 0;
        byte Lerp(byte a, byte b) => (byte)(a + (b - a) * t);
        return Color.FromArgb(255, Lerp(lower.R, upper.R), Lerp(lower.G, upper.G), Lerp(lower.B, upper.B));
    }
}
