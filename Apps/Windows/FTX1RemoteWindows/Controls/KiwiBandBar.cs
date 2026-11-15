using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace FTX1RemoteWindows.Controls;

/// The band bar over the MyKiwiSDR waterfall — the Mac's LocalSDRBandBar: the
/// bands in view by name ("40m Amateur", "MW Broadcast") on the top line and,
/// once an amateur band fills at least a third of the view
/// (BandHints.ShowsPlan), its US band plan on the second (CW/data, phone,
/// all-mode and CW-only sub-bands in their own colours, each labelled with the
/// lowest class allowed there — Technician only when that's the license picked
/// in Settings, else General — Extra-only parts hatched), and on the third the
/// ARRL's voluntary plan inside them plus the usual FT8/FT4/JS8/WSPR/PSK31 dial
/// frequencies (pink). A maritime band, zoomed in the same way, gets its GMDSS
/// frequencies on that line instead. Labels sit in the visible part of their
/// band, shortened or left out when they don't fit. Redrawn only when the
/// view (start, zoom, width) or the license choice changes.
public sealed class KiwiBandBar : UserControl
{
    private const double RowHeight = 15;
    public const double BarHeight = RowHeight * 3 + 2;

    private readonly Canvas _canvas = new() { Background = new SolidColorBrush(Colors.Black), Height = BarHeight };
    private readonly Dictionary<(string Text, double Size, bool Bold), double> _widths = [];
    private (KiwiWaterfallGeometry Geometry, int Start, int Zoom, double Width, bool Technician)? _drawn;

    public KiwiBandBar()
    {
        Height = BarHeight;
        Content = _canvas;
        _canvas.SizeChanged += (_, e) => _canvas.Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        ToolTipService.SetToolTip(this, Loc.S("localSdr.bandBar.help"));
    }

    public void Clear()
    {
        _canvas.Children.Clear();
        _drawn = null;
    }

    /// Whether Settings → License is a Technician (or Novice, the same HF
    /// privileges): only then are Technician-class labels shown.
    public static bool ShowsTechnician => AppSettings.LicensePrivileges is "us.technician" or "us.novice";

    public void Update(KiwiWaterfallGeometry geometry, int start, int zoom, double width, bool showsTechnician)
    {
        if (width <= 0)
        {
            Clear();
            return;
        }
        var key = (geometry, start, zoom, width, showsTechnician);
        if (_drawn == key)
        {
            return;
        }
        _drawn = key;
        _canvas.Children.Clear();
        _canvas.Width = width;

        var span = geometry.SpanHz(zoom);
        var lowHz = geometry.HzAtColumn(0, start, zoom);
        var highHz = lowHz + span;
        double X(long hz) => (hz - lowHz) / span * width;

        var planRowY = RowHeight + 1;
        var markerRowY = planRowY + RowHeight + 1;
        foreach (var hint in BandHints.Hints(lowHz, highHz))
        {
            var rect = Clamp(X(hint.LowerHz), X(hint.UpperHz), 0, RowHeight, width);
            DrawBand(hint, rect, width);
            if (!BandHints.ShowsPlan(hint, lowHz, highHz))
            {
                continue;
            }
            if (hint.Band is not { } band)
            {
                // A maritime band: its GMDSS frequencies on the marker line.
                DrawMarkers(GmdssFrequencies.MarkersIn(hint), markerRowY, X, width);
                continue;
            }
            foreach (var segment in AmateurBandPlan.Segments(band, showsTechnician))
            {
                DrawSegment(segment, Clamp(X(segment.LowerHz), X(segment.UpperHz), planRowY, RowHeight, width), width);
            }
            DrawMarkers(ArrlBandPlan.MarkersFor(band), markerRowY, X, width);
        }
    }

    /// A rect on a row whose far edges are pulled in to just outside the bar
    /// (a band much wider than the view would give shapes millions of pixels
    /// wide); the border there is clipped away, as in the Mac's.
    private static Rect Clamp(double x0, double x1, double y, double height, double width)
    {
        var left = Math.Clamp(x0, -3, width + 3);
        var right = Math.Clamp(x1, -3, width + 3);
        return new Rect(left, y, Math.Max(right - left, 0), height);
    }

    private static Color C(double r, double g, double b, double a = 1) =>
        Color.FromArgb((byte)Math.Round(a * 255), (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

    private static Color ColorFor(BandHintKind kind) => kind switch
    {
        BandHintKind.Amateur => C(0.25, 0.65, 0.35),
        BandHintKind.Broadcast => C(0.35, 0.5, 0.75),
        BandHintKind.Aeronautical => C(0.75, 0.55, 0.3),
        BandHintKind.Maritime => C(0.2, 0.6, 0.6),
        _ => C(0.5, 0.5, 0.5),
    };

    private static Color ColorFor(AmateurBandUsage usage) => usage switch
    {
        AmateurBandUsage.CwData or AmateurBandUsage.CwOnly => C(0.3, 0.55, 0.95),
        AmateurBandUsage.Phone => C(0.95, 0.6, 0.2),
        AmateurBandUsage.AllModes => C(0.7, 0.45, 0.9),
        _ => C(0.25, 0.75, 0.75),
    };

    private static Color ColorFor(BandPlanMarkerKind kind) => kind switch
    {
        BandPlanMarkerKind.Data or BandPlanMarkerKind.DataDX or BandPlanMarkerKind.Packet => C(0.45, 0.75, 1),
        BandPlanMarkerKind.DxWindow or BandPlanMarkerKind.QrpCW => C(0.4, 0.9, 0.85),
        BandPlanMarkerKind.QrpSSB or BandPlanMarkerKind.Sstv or BandPlanMarkerKind.AmCalling or BandPlanMarkerKind.Am => C(1, 0.75, 0.4),
        BandPlanMarkerKind.Beacons or BandPlanMarkerKind.NcdxfBeacons or BandPlanMarkerKind.Experimental => C(0.95, 0.9, 0.4),
        BandPlanMarkerKind.Satellite or BandPlanMarkerKind.RepeaterInputs or BandPlanMarkerKind.RepeaterOutputs
            or BandPlanMarkerKind.FmSimplex => C(0.55, 0.9, 0.5),
        BandPlanMarkerKind.Ft8 or BandPlanMarkerKind.Ft4 or BandPlanMarkerKind.Js8 or BandPlanMarkerKind.Wspr
            or BandPlanMarkerKind.Psk31 => C(1, 0.5, 0.85),
        BandPlanMarkerKind.DscDistress or BandPlanMarkerKind.VoiceDistress or BandPlanMarkerKind.NbdpDistress => C(1, 0.35, 0.3),
        _ => C(0.95, 0.9, 0.4),
    };

    private static string LabelFor(BandPlanMarkerKind kind) => kind switch
    {
        BandPlanMarkerKind.Data => "RTTY/Data",
        BandPlanMarkerKind.DataDX => "RTTY/Data DX",
        BandPlanMarkerKind.Packet => Loc.S("localSdr.bandBar.arrl.packet"),
        BandPlanMarkerKind.DxWindow => Loc.S("localSdr.bandBar.arrl.dxWindow"),
        BandPlanMarkerKind.QrpCW => "QRP CW",
        BandPlanMarkerKind.QrpSSB => "QRP SSB",
        BandPlanMarkerKind.Sstv => "SSTV",
        BandPlanMarkerKind.AmCalling => Loc.S("localSdr.bandBar.arrl.amCalling"),
        BandPlanMarkerKind.Am => "AM",
        BandPlanMarkerKind.Beacons => Loc.S("localSdr.bandBar.arrl.beacons"),
        BandPlanMarkerKind.NcdxfBeacons => "NCDXF",
        BandPlanMarkerKind.Experimental => Loc.S("localSdr.bandBar.arrl.experimental"),
        BandPlanMarkerKind.Satellite => Loc.S("localSdr.bandBar.arrl.satellite"),
        BandPlanMarkerKind.RepeaterInputs => Loc.S("localSdr.bandBar.arrl.repeaterIn"),
        BandPlanMarkerKind.RepeaterOutputs => Loc.S("localSdr.bandBar.arrl.repeaterOut"),
        BandPlanMarkerKind.FmSimplex => Loc.S("localSdr.bandBar.arrl.fmSimplex"),
        BandPlanMarkerKind.Ft8 => "FT8",
        BandPlanMarkerKind.Ft4 => "FT4",
        BandPlanMarkerKind.Js8 => "JS8",
        BandPlanMarkerKind.Wspr => "WSPR",
        BandPlanMarkerKind.Psk31 => "PSK31",
        BandPlanMarkerKind.DscDistress => "DSC",
        BandPlanMarkerKind.VoiceDistress => Loc.S("localSdr.bandBar.gmdss.voice"),
        BandPlanMarkerKind.NbdpDistress => "NBDP",
        BandPlanMarkerKind.Navtex => "NAVTEX",
        _ => "MSI",
    };

    // MARK: Drawing

    private void DrawBand(BandHint hint, Rect rect, double width)
    {
        var color = ColorFor(hint.Kind);
        AddBox(new Rect(rect.X + 0.5, rect.Y + 1, Math.Max(rect.Width - 1, 0), Math.Max(rect.Height - 2, 0)),
            Color.FromArgb(89, color.R, color.G, color.B), Color.FromArgb(230, color.R, color.G, color.B));
        string[] candidates = hint.Kind switch
        {
            BandHintKind.Amateur => [Loc.F("localSdr.bandBar.amateur", hint.Label), hint.Label],
            BandHintKind.Broadcast => [Loc.F("localSdr.bandBar.broadcast", hint.Label), hint.Label],
            BandHintKind.Aeronautical => [Loc.F("localSdr.bandBar.aeronautical", hint.Label), Loc.S("localSdr.bandBar.aero"), hint.Label],
            BandHintKind.Maritime => [Loc.F("localSdr.bandBar.maritime", hint.Label), Loc.S("localSdr.bandBar.marine"), hint.Label],
            _ => [hint.Label],
        };
        DrawLabel(candidates, rect, width);
    }

    private void DrawSegment(AmateurBandPlanSegment segment, Rect rect, double width)
    {
        var color = ColorFor(segment.Usage);
        var shown = new Rect(rect.X + 0.5, rect.Y + 0.5, Math.Max(rect.Width - 1, 0), Math.Max(rect.Height - 1, 0));
        AddBox(shown, Color.FromArgb(102, color.R, color.G, color.B), color);
        if (segment.LowestClass == USLicenseClass.Extra)
        {
            // Extra only: hatched.
            var hatch = new Canvas
            {
                Width = shown.Width,
                Height = shown.Height,
                Clip = new RectangleGeometry { Rect = new Rect(0, 0, shown.Width, shown.Height) },
                IsHitTestVisible = false,
            };
            var brush = new SolidColorBrush(Color.FromArgb(204, color.R, color.G, color.B));
            for (var lineX = Math.Floor(shown.X / 6) * 6 - shown.Height; lineX < shown.X + shown.Width; lineX += 6)
            {
                hatch.Children.Add(new Line
                {
                    X1 = lineX - shown.X,
                    Y1 = shown.Height,
                    X2 = lineX - shown.X + shown.Height,
                    Y2 = 0,
                    Stroke = brush,
                    StrokeThickness = 1,
                });
            }
            Canvas.SetLeft(hatch, shown.X);
            Canvas.SetTop(hatch, shown.Y);
            _canvas.Children.Add(hatch);
        }
        var usage = segment.Usage switch
        {
            AmateurBandUsage.CwData => Loc.S("localSdr.bandBar.cwData"),
            AmateurBandUsage.Phone => Loc.S("localSdr.bandBar.phone"),
            AmateurBandUsage.AllModes => Loc.S("localSdr.bandBar.allModes"),
            AmateurBandUsage.CwOnly => "CW",
            _ => Loc.S("localSdr.bandBar.channel"),
        };
        // US class names, English in every language (as in Settings → License).
        var licence = segment.LowestClass.ToString();
        var both = Loc.F("localSdr.bandBar.segment", usage, licence);
        DrawLabel(segment.LowestClass == USLicenseClass.Extra ? [both, licence, usage] : [both, usage], rect, width);
    }

    /// The ARRL line: ranges as outlined boxes labelled inside, single
    /// frequencies as a tick with its label in a dark tab beside it. Labels
    /// never overlap: each goes where it fits among those already placed
    /// (ranges first, then spots by label priority), else the mark is drawn
    /// unlabelled.
    private void DrawMarkers(List<BandPlanMarker> markers, double rowY, Func<long, double> x, double width)
    {
        var placed = new List<Rect>();
        // Ticks of spots already labelled: no other label may cover them, or
        // a label would sit beside the wrong tick.
        var labelledTicks = new List<double>();
        const double fontSize = 9.5;

        bool Place(string text, Color color, Func<double, Rect?>[] candidates, bool background)
        {
            var labelWidth = Measure(text, fontSize, true) + 6;
            foreach (var candidate in candidates)
            {
                if (candidate(labelWidth) is not { } rect || rect.X < 0 || rect.X + rect.Width > width
                    || placed.Any(p => Intersects(p, rect))
                    || labelledTicks.Any(t => t >= rect.X - 1 && t <= rect.X + rect.Width + 1))
                {
                    continue;
                }
                if (background)
                {
                    var tab = new Rectangle
                    {
                        Width = rect.Width,
                        Height = rect.Height,
                        RadiusX = 2,
                        RadiusY = 2,
                        Fill = new SolidColorBrush(Color.FromArgb(217, 0, 0, 0)),
                    };
                    Canvas.SetLeft(tab, rect.X);
                    Canvas.SetTop(tab, rect.Y);
                    _canvas.Children.Add(tab);
                }
                AddCentredText(text, background ? color : Colors.White, fontSize, rect.X + rect.Width / 2, rect.Y + rect.Height / 2);
                placed.Add(rect);
                return true;
            }
            return false;
        }

        foreach (var marker in markers.Where(m => !m.IsSpot))
        {
            var color = ColorFor(marker.Kind);
            var box = Clamp(x(marker.LowerHz), x(marker.UpperHz), rowY, RowHeight, width);
            var inset = new Rect(box.X + 0.5, box.Y + 0.5, Math.Max(box.Width - 1, 0), Math.Max(box.Height - 1, 0));
            AddBox(inset, Color.FromArgb(64, color.R, color.G, color.B), Color.FromArgb(230, color.R, color.G, color.B));
            var visibleLeft = Math.Max(inset.X, 0);
            var visibleRight = Math.Min(inset.X + inset.Width, width);
            if (visibleRight <= visibleLeft)
            {
                continue;
            }
            Place(LabelFor(marker.Kind), color,
            [
                w => w <= visibleRight - visibleLeft
                    ? new Rect((visibleLeft + visibleRight) / 2 - w / 2, rowY, w, RowHeight)
                    : null,
            ], background: false);
        }

        // Every tick first, so a label's dark tab covers its neighbours'
        // ticks instead of being crossed by them (FT8/FT4/JS8 sit 2–5 kHz
        // apart).
        var spots = markers.Where(m => m.IsSpot && x(m.LowerHz) >= 0 && x(m.LowerHz) <= width).ToList();
        foreach (var marker in spots)
        {
            var tick = x(marker.LowerHz);
            var line = new Rectangle { Width = 1.5, Height = RowHeight, Fill = new SolidColorBrush(ColorFor(marker.Kind)) };
            Canvas.SetLeft(line, tick - 0.75);
            Canvas.SetTop(line, rowY);
            _canvas.Children.Add(line);
        }
        foreach (var marker in spots)
        {
            var color = ColorFor(marker.Kind);
            var tick = x(marker.LowerHz);
            double top = rowY + 1, height = RowHeight - 2;
            if (Place(LabelFor(marker.Kind), color,
                [
                    w => new Rect(tick + 2, top, w, height),
                    w => new Rect(tick - 2 - w, top, w, height),
                ], background: true))
            {
                labelledTicks.Add(tick);
            }
        }
    }

    private static bool Intersects(Rect a, Rect b) =>
        a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;

    /// The first of candidates that fits the visible part of rect, centred
    /// there; nothing if none does.
    private void DrawLabel(string[] candidates, Rect rect, double width)
    {
        var left = Math.Max(rect.X, 0);
        var right = Math.Min(rect.X + rect.Width, width);
        if (right - left <= 12)
        {
            return;
        }
        foreach (var candidate in candidates)
        {
            if (Measure(candidate, 10, true) + 6 <= right - left)
            {
                AddCentredText(candidate, Colors.White, 10, (left + right) / 2, rect.Y + rect.Height / 2);
                return;
            }
        }
    }

    private void AddBox(Rect rect, Color fill, Color stroke)
    {
        var box = new Rectangle
        {
            Width = rect.Width,
            Height = rect.Height,
            Fill = new SolidColorBrush(fill),
            Stroke = new SolidColorBrush(stroke),
            StrokeThickness = 1,
            IsHitTestVisible = false,
        };
        Canvas.SetLeft(box, rect.X);
        Canvas.SetTop(box, rect.Y);
        _canvas.Children.Add(box);
    }

    private void AddCentredText(string text, Color color, double size, double centreX, double centreY)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = FontWeights.Medium,
            Foreground = new SolidColorBrush(color),
            IsHitTestVisible = false,
        };
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(block, centreX - block.DesiredSize.Width / 2);
        Canvas.SetTop(block, centreY - block.DesiredSize.Height / 2);
        _canvas.Children.Add(block);
    }

    private double Measure(string text, double size, bool bold)
    {
        if (_widths.TryGetValue((text, size, bold), out var cached))
        {
            return cached;
        }
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = FontWeights.Medium };
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return _widths[(text, size, bold)] = block.DesiredSize.Width;
    }
}
