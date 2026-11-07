// The game's save tree (GAME chunk, unpacked; the tree starts at byte 8 after two u32s: 6, 3): key = u32 length (with
// the NUL) + chars + NUL, then a type byte and its value. Used by save-dump.ps1 (-Tree). Types are added as they turn
// up; an unknown one stops the walk with its place (Stop).
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class SaveTree
{
    public static string Stop = "";
    public static Dictionary<int, int> TypeCounts = new Dictionary<int, int>();

    static int U32(byte[] b, ref int p) { int v = BitConverter.ToInt32(b, p); p += 4; return v; }
    static string Str(byte[] b, ref int p)
    {
        int n = U32(b, ref p);
        if (n < -(1 << 20) || n > 1 << 20) throw new Exception("bad string length " + n + " at " + (p - 4));
        string s;
        if (n < 0) { s = Encoding.Unicode.GetString(b, p, -n * 2).TrimEnd('\0'); p += -n * 2; }
        else { s = Encoding.ASCII.GetString(b, p, n).TrimEnd('\0'); p += n; }
        return s;
    }

    public static void Walk(byte[] b, int start, TextWriter w, int maxLines)
    {
        int p = start, lines = 0;
        Stop = "";
        try { Value(b, ref p, b[p++], "", w, ref lines, maxLines); Stop = "done at " + p + " of " + b.Length; }
        catch (Exception e) { Stop = e.Message; }
    }

    // The root map's keys and the byte range of each one's value (its type byte included): "key" -> {start, end}.
    // save-splice.ps1 moves a value (the zone: "Map") from one save into another by these ranges.
    public static Dictionary<string, int[]> RootRanges(byte[] b, int start)
    {
        var r = new Dictionary<string, int[]>();
        int p = start;
        int t = b[p++];
        if (t != 0x15 && t != 0x16) throw new Exception("root is not a map: 0x" + t.ToString("x2"));
        int n = U32(b, ref p), lines = 0;
        for (int i = 0; i < n; i++)
        {
            string k = Str(b, ref p);
            int s = p;
            Value(b, ref p, b[p++], "/" + k, TextWriter.Null, ref lines, 0);
            r[k] = new[] { s, p };
        }
        r["(root)"] = new[] { start, p };
        return r;
    }

    static void Line(TextWriter w, ref int lines, int maxLines, string s) { if (lines++ < maxLines) w.WriteLine(s); }

    // a value of type t (its type byte already read)
    // an FFormatArgumentValue / an FText (flags, a history byte, that history) - as save.cpp's Walker
    static void Arg(byte[] b, ref int p)
    {
        int k = b[p++];
        if (k == 0 || k == 1 || k == 3) p += 8; else if (k == 2) p += 4; else if (k == 4) Text(b, ref p); else if (k == 5) p += 1;
        else throw new Exception("format argument type " + k + " at " + p);
    }
    static void Text(byte[] b, ref int p)
    {
        p += 4;
        int h = b[p++];
        if (h == 0xff) { if (U32(b, ref p) != 0) Str(b, ref p); }
        else if (h == 0x00) { Str(b, ref p); Str(b, ref p); Str(b, ref p); }
        else if (h >= 1 && h <= 3) { Text(b, ref p); int n = U32(b, ref p); for (int i = 0; i < n; i++) { if (h != 2) Str(b, ref p); Arg(b, ref p); } }
        else if (h >= 4 && h <= 6) { if (h == 6) Str(b, ref p); Arg(b, ref p); if (U32(b, ref p) != 0) p += 4 + 4 + 1 + 16; Str(b, ref p); }
        else if (h == 0x0b) { Str(b, ref p); Str(b, ref p); }
        else throw new Exception("text history " + h + " at " + p);
    }
    static void Value(byte[] b, ref int p, int t, string path, TextWriter w, ref int lines, int maxLines)
    {
        int c; TypeCounts.TryGetValue(t, out c); TypeCounts[t] = c + 1;
        int at = p;
        switch (t)
        {
            case 0x15: case 0x16: // a map: count, then key + type + value
            {
                int n = U32(b, ref p);
                Line(w, ref lines, maxLines, path + "\t{" + n + "}");
                for (int i = 0; i < n; i++)
                {
                    string k = Str(b, ref p);
                    Value(b, ref p, b[p++], path + "/" + k, w, ref lines, maxLines);
                }
                return;
            }
            case 0x14: // a TMap: key type, value type, count (twice), all the keys, then all the values (no type bytes)
            {
                int kt = b[p++], vt = b[p++];
                U32(b, ref p);
                int n = U32(b, ref p);
                Line(w, ref lines, maxLines, path + "\tmap[" + n + " " + kt.ToString("x2") + "->" + vt.ToString("x2") + "]");
                for (int i = 0; i < n; i++) Value(b, ref p, kt, path + "<k" + i + ">", w, ref lines, maxLines);
                for (int i = 0; i < n; i++) Value(b, ref p, vt, path + "<v" + i + ">", w, ref lines, maxLines);
                return;
            }
            case 0x13: // an array: element type, count, the elements (no type bytes)
            {
                int et = b[p++];
                int n = U32(b, ref p);
                Line(w, ref lines, maxLines, path + "\t[" + n + " x " + et.ToString("x2") + "]");
                for (int i = 0; i < n; i++) Value(b, ref p, et, path + "[" + i + "]", w, ref lines, maxLines);
                return;
            }
            case 0x10: // a struct: field count, then key + type + value
            {
                int n = U32(b, ref p);
                Line(w, ref lines, maxLines, path + "\tstruct{" + n + "}");
                for (int i = 0; i < n; i++)
                {
                    string k = Str(b, ref p);
                    Value(b, ref p, b[p++], path + "." + k, w, ref lines, maxLines);
                }
                return;
            }
            case 0x06: { Text(b, ref p); Line(w, ref lines, maxLines, path + "\ttext"); return; } // (an FText: save.cpp)
            case 0x17: { int n = U32(b, ref p); p += n; Line(w, ref lines, maxLines, path + "\tbytes[" + n + "]"); return; } // (a photo's JPEG)
            case 0x18: { long v = BitConverter.ToInt64(b, p); p += 8; Line(w, ref lines, maxLines, path + "\ti64\t" + v); return; }
            case 0x02: { int v = U32(b, ref p); Line(w, ref lines, maxLines, path + "\ti32\t" + v); return; }
            case 0x01: { int v = U32(b, ref p); Line(w, ref lines, maxLines, path + "\tbool\t" + (v != 0)); return; } // (4 bytes)
            case 0x03: { float v = BitConverter.ToSingle(b, p); p += 4; Line(w, ref lines, maxLines, path + "	f32	" + v); return; }
            case 0x0f: { long v = BitConverter.ToInt64(b, p); p += 8; Line(w, ref lines, maxLines, path + "	i64	" + v); return; } // (a timestamp: ticks)
            case 0x07: case 0x08: { float x = BitConverter.ToSingle(b, p), y = BitConverter.ToSingle(b, p + 4), z = BitConverter.ToSingle(b, p + 8); p += 12; Line(w, ref lines, maxLines, path + "	" + (t == 7 ? "vec" : "rot") + "	" + string.Format("{0:F1},{1:F1},{2:F1}", x, y, z)); return; } // (vector / rotator: 3 floats)
            case 0x0c: { p += 16; Line(w, ref lines, maxLines, path + "	color"); return; } // (linear color: 4 floats)
            case 0x0d: { var g = new byte[16]; Array.Copy(b, p, g, 0, 16); p += 16; Line(w, ref lines, maxLines, path + "	guid	" + new Guid(g).ToString("N")); return; }
            case 0x04: case 0x05: case 0x0e: case 0x11: case 0x19: case 0x1a: { string s = Str(b, ref p); Line(w, ref lines, maxLines, path + "\t" + t.ToString("x2") + "\t" + s); return; }
            case 0x12: // an object reference: a kind byte (0 none, 2 class + name, 3 class + asset path), its strings
            {
                int kind = b[p++];
                var parts = new List<string> { "k" + kind };
                int n = kind == 0 ? 0 : kind == 1 ? 1 : 2;
                for (int i = 0; i < n; i++) parts.Add(Str(b, ref p));
                if (kind == 1) { var g = new byte[16]; Array.Copy(b, p, g, 0, 16); parts.Add(new Guid(g).ToString("N")); p += 16; } // (a saved object: class + guid)
                Line(w, ref lines, maxLines, path + "\tref\t" + string.Join(" | ", parts));
                return;
            }
            case 0x0a: // a transform: rotation quat, translation, scale (10 floats)
            {
                var f = new float[10];
                for (int i = 0; i < 10; i++) { f[i] = BitConverter.ToSingle(b, p); p += 4; }
                Line(w, ref lines, maxLines, path + "\txform\t" + string.Format("{0:F0},{1:F0},{2:F0}", f[4], f[5], f[6]));
                return;
            }
            default:
                p = at;
                throw new Exception("unknown type 0x" + t.ToString("x2") + " at " + (at - 1) + " under " + path);
        }
    }
}
