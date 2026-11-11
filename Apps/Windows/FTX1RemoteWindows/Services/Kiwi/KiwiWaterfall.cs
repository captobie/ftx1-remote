namespace FTX1RemoteWindows.Services;

/// Where a waterfall row goes relative to the picture already drawn: the pure
/// half of the MyKiwiSDR window's waterfall (the pixels live in the
/// WaterfallBitmap below). Port of KiwiWaterfallPlacement.swift. Every row is
/// placed by its own header — rows in flight after a pan or zoom still carry
/// the old position.
public abstract record KiwiWaterfallPlacement
{
    /// Same position as the picture: just add the row.
    public sealed record Append : KiwiWaterfallPlacement;
    /// Same zoom, moved: shift the existing rows by this many bins first
    /// (positive = the view moved up in frequency, so history moves left),
    /// leaving the exposed edge blank.
    public sealed record Shift(int Bins) : KiwiWaterfallPlacement;
    /// Different zoom: rebuild the history from ColumnMap, or clear it.
    public sealed record Rezoom : KiwiWaterfallPlacement;

    public static KiwiWaterfallPlacement Place((int XBin, int Zoom) row, (int XBin, int Zoom)? anchor,
                                               KiwiWaterfallGeometry geometry)
    {
        if (anchor is not { } from)
        {
            return new Append();
        }
        if (geometry.BinsToShift(from, row) is not { } bins)
        {
            return new Rezoom();
        }
        return bins == 0 ? new Append() : new Shift(bins);
    }

    /// For each column of a row at "to", the column of a row at "from" showing
    /// the same frequency (the one under the new column's centre), or −1 where
    /// "from" didn't cover it. Used to rescale the history on a zoom change.
    public static int[] ColumnMap((int XBin, int Zoom) from, (int XBin, int Zoom) to, KiwiWaterfallGeometry geometry)
    {
        var count = geometry.FftSize;
        double fromUnit = geometry.UnitsPerBin(from.Zoom);
        double toUnit = geometry.UnitsPerBin(to.Zoom);
        var map = new int[count];
        for (var column = 0; column < count; column++)
        {
            var units = to.XBin + (column + 0.5) * toUnit;
            var source = Math.Floor((units - from.XBin) / fromUnit);
            map[column] = source >= 0 && source < count ? (int)source : -1;
        }
        return map;
    }
}

/// The waterfall's colour range from recent rows, modelled on the Kiwi page's
/// autoscale but tightened at the bottom for the palette's short dark end:
/// floor = median − 5 dB, ceiling = 95th percentile + 25 dB and at least 40
/// dB above the floor; masked bins (≤ −190 dBm) are left out. Measured every
/// few rows from a 256-bucket histogram and smoothed, so a burst doesn't
/// flash the picture. Port of KiwiWaterfallAutoRange.
public sealed class KiwiWaterfallAutoRange
{
    public double FloorDbm { get; private set; } = -120;
    public double CeilingDbm { get; private set; } = -80;
    public bool IsSettled { get; private set; }

    private readonly int _rowsPerMeasurement;
    private readonly double _smoothing;
    private int _rowsSinceMeasurement;

    public KiwiWaterfallAutoRange(int rowsPerMeasurement = 5, double smoothing = 0.2)
    {
        _rowsPerMeasurement = Math.Max(1, rowsPerMeasurement);
        _smoothing = smoothing;
    }

    /// Feeds one row; returns true when the range changed by ≥ 0.5 dB (time
    /// to rebuild a colour table).
    public bool Add(byte[] bins, int cal)
    {
        _rowsSinceMeasurement++;
        if (IsSettled && _rowsSinceMeasurement < _rowsPerMeasurement)
        {
            return false;
        }
        _rowsSinceMeasurement = 0;
        if (Measure(bins, cal) is not { } measured)
        {
            return false;
        }
        double oldFloor = FloorDbm, oldCeiling = CeilingDbm;
        if (IsSettled)
        {
            FloorDbm += (measured.Floor - FloorDbm) * _smoothing;
            CeilingDbm += (measured.Ceiling - CeilingDbm) * _smoothing;
        }
        else
        {
            FloorDbm = measured.Floor;
            CeilingDbm = measured.Ceiling;
            IsSettled = true;
            return true;
        }
        return Math.Abs(FloorDbm - oldFloor) >= 0.5 || Math.Abs(CeilingDbm - oldCeiling) >= 0.5;
    }

    public void Reset()
    {
        IsSettled = false;
        _rowsSinceMeasurement = 0;
    }

    /// One row's floor and ceiling, null if every bin is masked.
    public static (double Floor, double Ceiling)? Measure(byte[] bins, int cal)
    {
        var histogram = new int[256];
        var total = 0;
        // dBm = byte − 255 + cal ≤ −190 ⇔ byte ≤ 65 − cal.
        var masked = 65 - cal;
        foreach (var value in bins)
        {
            if (value > masked)
            {
                histogram[value]++;
                total++;
            }
        }
        if (total == 0)
        {
            return null;
        }
        int Percentile(double fraction)
        {
            var target = (int)(fraction * total);
            var seen = 0;
            for (var value = 0; value < histogram.Length; value++)
            {
                seen += histogram[value];
                if (seen > target)
                {
                    return value;
                }
            }
            return 255;
        }
        double noise = KiwiWaterfallFrame.Dbm((byte)Percentile(0.5), cal);
        double signal = KiwiWaterfallFrame.Dbm((byte)Percentile(0.95), cal);
        var floor = noise - 5;
        var ceiling = Math.Max(signal + 25, floor + 40);
        return (floor, ceiling);
    }

    /// For each wire byte, the 0…255 palette step: the floor maps to 0, the
    /// ceiling to 255, clamped.
    public byte[] PaletteSteps(int cal)
    {
        var range = Math.Max(CeilingDbm - FloorDbm, 1);
        var steps = new byte[256];
        for (var value = 0; value < 256; value++)
        {
            double dbm = KiwiWaterfallFrame.Dbm((byte)value, cal);
            var t = (dbm - FloorDbm) / range;
            steps[value] = (byte)Math.Max(0, Math.Min(255, Math.Round(t * 255, MidpointRounding.AwayFromZero)));
        }
        return steps;
    }
}

/// A width×height picture of packed BGRA pixels, newest row at the top, that
/// can also move sideways (the Mac's PannableWaterfallBitmap). Per row: one
/// block copy down plus one 256-entry table lookup per pixel; a pan is one
/// short copy per row.
public sealed class KiwiWaterfallBitmap
{
    public int Width { get; }
    public int Height { get; }
    /// BGRA bytes, row-major, newest row first.
    public byte[] Pixels { get; }

    private readonly uint _blank;
    private readonly uint[] _scratch;

    public KiwiWaterfallBitmap(int width, int height, uint blank)
    {
        Width = width;
        Height = height;
        _blank = blank;
        Pixels = new byte[width * height * 4];
        _scratch = new uint[width];
        Clear();
    }

    /// Adds "bins" (one byte each, Width of them) as the newest row, each
    /// colored through "colors" (wire byte → packed 0xAARRGGBB).
    public void Append(byte[] bins, uint[] colors)
    {
        var rowBytes = Width * 4;
        Buffer.BlockCopy(Pixels, 0, Pixels, rowBytes, Pixels.Length - rowBytes);
        for (var column = 0; column < Width; column++)
        {
            Set(column, colors[bins[column]]);
        }
    }

    /// Moves every row "bins" columns left (positive: the view moved up in
    /// frequency) or right, blanking what comes into view.
    public void Shift(int bins)
    {
        if (bins == 0)
        {
            return;
        }
        var distance = Math.Min(Math.Abs(bins), Width);
        var kept = Width - distance;
        for (var row = 0; row < Height; row++)
        {
            var line = row * Width * 4;
            if (kept > 0)
            {
                if (bins > 0)
                {
                    Buffer.BlockCopy(Pixels, line + distance * 4, Pixels, line, kept * 4);
                }
                else
                {
                    Buffer.BlockCopy(Pixels, line, Pixels, line + distance * 4, kept * 4);
                }
            }
            var exposed = bins > 0 ? kept : 0;
            for (var column = 0; column < distance; column++)
            {
                SetAt(row, exposed + column, _blank);
            }
        }
    }

    /// Rebuilds every row through "map" (new column → old column, −1 = blank),
    /// for a zoom change.
    public void Remap(int[] map)
    {
        if (map.Length != Width)
        {
            Clear();
            return;
        }
        for (var row = 0; row < Height; row++)
        {
            for (var column = 0; column < Width; column++)
            {
                var from = map[column];
                _scratch[column] = from >= 0 ? GetAt(row, from) : _blank;
            }
            for (var column = 0; column < Width; column++)
            {
                SetAt(row, column, _scratch[column]);
            }
        }
    }

    public void Clear()
    {
        for (var row = 0; row < Height; row++)
        {
            for (var column = 0; column < Width; column++)
            {
                SetAt(row, column, _blank);
            }
        }
    }

    private void Set(int column, uint color) => SetAt(0, column, color);

    private void SetAt(int row, int column, uint color)
    {
        var o = (row * Width + column) * 4;
        Pixels[o] = (byte)color;
        Pixels[o + 1] = (byte)(color >> 8);
        Pixels[o + 2] = (byte)(color >> 16);
        Pixels[o + 3] = 255;
    }

    private uint GetAt(int row, int column)
    {
        var o = (row * Width + column) * 4;
        return (uint)(Pixels[o] | Pixels[o + 1] << 8 | Pixels[o + 2] << 16 | 0xFF000000);
    }
}
