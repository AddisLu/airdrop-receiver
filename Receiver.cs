// Helpers compiled into server.ps1 via Add-Type: safe file naming and a
// streaming multipart/form-data reader (large videos never sit in memory).
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public class ReceivedPart
{
    public string Name;      // form field name
    public bool IsFile;
    public string Path;
    public string Text;
    public long Size;
    public string ContentType;
}

public static class Receiver
{
    static readonly Dictionary<string, string> ExtByMime = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        { "image/jpeg", ".jpg" }, { "image/png", ".png" }, { "image/heic", ".heic" }, { "image/heif", ".heif" },
        { "image/gif", ".gif" }, { "image/webp", ".webp" }, { "video/quicktime", ".mov" }, { "video/mp4", ".mp4" },
        { "audio/mpeg", ".mp3" }, { "audio/x-m4a", ".m4a" }, { "audio/mp4", ".m4a" },
        { "application/pdf", ".pdf" }, { "text/plain", ".txt" }, { "application/zip", ".zip" },
        { "application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx" },
        { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xlsx" },
        { "application/vnd.openxmlformats-officedocument.presentationml.presentation", ".pptx" }
    };

    public static string SafeName(string raw, string contentType)
    {
        string name = raw ?? "";
        foreach (char c in System.IO.Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
        name = name.Trim().TrimEnd('.');
        if (name.Length == 0) name = "file-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
        if (Regex.IsMatch(name, @"^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\.|$)", RegexOptions.IgnoreCase)) name = "_" + name;
        if (name.Length > 180) name = name.Substring(0, 180);
        if (System.IO.Path.GetExtension(name).Length == 0 && contentType != null)
        {
            string mime = contentType.Split(';')[0].Trim();
            string ext;
            if (ExtByMime.TryGetValue(mime, out ext)) name += ext;
        }
        return name;
    }

    public static string UniquePath(string dir, string name)
    {
        string baseName = System.IO.Path.GetFileNameWithoutExtension(name);
        string ext = System.IO.Path.GetExtension(name);
        string path = System.IO.Path.Combine(dir, name);
        for (int i = 1; File.Exists(path) || File.Exists(path + ".part"); i++)
            path = System.IO.Path.Combine(dir, string.Format("{0} ({1}){2}", baseName, i, ext));
        return path;
    }

    // Copies the whole stream to a new file in dir; returns the final path.
    public static string SaveStream(Stream input, string dir, string name)
    {
        BufferedInput reader = new BufferedInput(input);
        return SaveUntil(reader, null, dir, name);
    }

    static string SaveUntil(BufferedInput reader, byte[] delimiter, string dir, string name)
    {
        string path = UniquePath(dir, name);
        string tmp = path + ".part";
        try
        {
            using (FileStream fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16))
            {
                if (delimiter == null) reader.CopyToEnd(fs);
                else if (!reader.ReadUntil(delimiter, fs)) throw new IOException("Upload ended early");
            }
            File.Move(tmp, path);
            return path;
        }
        catch
        {
            try { File.Delete(tmp); } catch { }
            throw;
        }
    }

    public static List<ReceivedPart> SaveMultipart(Stream input, string contentType, string dir)
    {
        Match m = Regex.Match(contentType ?? "", "boundary=\"?([^\";]+)\"?", RegexOptions.IgnoreCase);
        if (!m.Success) throw new InvalidDataException("Missing multipart boundary");
        string boundary = m.Groups[1].Value;

        BufferedInput reader = new BufferedInput(input);
        byte[] first = Encoding.ASCII.GetBytes("--" + boundary);
        byte[] delimiter = Encoding.ASCII.GetBytes("\r\n--" + boundary);
        byte[] headerEnd = Encoding.ASCII.GetBytes("\r\n\r\n");
        List<ReceivedPart> parts = new List<ReceivedPart>();

        if (!reader.ReadUntil(first, null)) throw new InvalidDataException("Boundary not found");
        while (true)
        {
            byte[] next = reader.ReadBytes(2);
            if (next == null || (next[0] == '-' && next[1] == '-')) break;   // closing "--boundary--"

            MemoryStream headerBytes = new MemoryStream();
            if (!reader.ReadUntil(headerEnd, headerBytes)) break;
            string headers = Encoding.UTF8.GetString(headerBytes.ToArray());

            string disposition = HeaderValue(headers, "Content-Disposition");
            string partType = HeaderValue(headers, "Content-Type");
            string fileName = DispositionParam(disposition, "filename");

            ReceivedPart part = new ReceivedPart();
            part.Name = DispositionParam(disposition, "name");
            part.ContentType = partType;
            if (fileName != null || (partType != null && !partType.StartsWith("text/", StringComparison.OrdinalIgnoreCase)))
            {
                part.IsFile = true;
                part.Path = SaveUntil(reader, delimiter, dir, SafeName(fileName, partType));
                part.Size = new FileInfo(part.Path).Length;
            }
            else
            {
                MemoryStream value = new MemoryStream();
                if (!reader.ReadUntil(delimiter, value)) throw new IOException("Upload ended early");
                part.Text = Encoding.UTF8.GetString(value.ToArray());
                part.Size = value.Length;
            }
            parts.Add(part);
        }
        return parts;
    }

    static string HeaderValue(string headers, string name)
    {
        foreach (string line in headers.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            int colon = line.IndexOf(':');
            if (colon > 0 && line.Substring(0, colon).Trim().Equals(name, StringComparison.OrdinalIgnoreCase))
                return line.Substring(colon + 1).Trim();
        }
        return null;
    }

    static string DispositionParam(string disposition, string param)
    {
        if (disposition == null) return null;
        Match star = Regex.Match(disposition, param + @"\*\s*=\s*([^']*)'[^']*'([^;]+)", RegexOptions.IgnoreCase);
        if (star.Success)
        {
            try { return Uri.UnescapeDataString(star.Groups[2].Value.Trim()); } catch { }
        }
        Match plain = Regex.Match(disposition, @"(?:^|;)\s*" + param + "\\s*=\\s*(\"(?<v>[^\"]*)\"|(?<v>[^;]*))", RegexOptions.IgnoreCase);
        return plain.Success ? plain.Groups["v"].Value.Trim() : null;
    }
}

class BufferedInput
{
    readonly Stream stream;
    readonly byte[] buf = new byte[1 << 16];
    int start, end;

    public BufferedInput(Stream s) { stream = s; }

    bool Fill()
    {
        if (start > 0)
        {
            Buffer.BlockCopy(buf, start, buf, 0, end - start);
            end -= start;
            start = 0;
        }
        int n = stream.Read(buf, end, buf.Length - end);
        if (n <= 0) return false;
        end += n;
        return true;
    }

    public byte[] ReadBytes(int count)
    {
        while (end - start < count) if (!Fill()) return null;
        byte[] result = new byte[count];
        Buffer.BlockCopy(buf, start, result, 0, count);
        start += count;
        return result;
    }

    public void CopyToEnd(Stream sink)
    {
        do { sink.Write(buf, start, end - start); start = end; } while (Fill());
    }

    // Copies bytes to sink (if any) until delim, consuming delim. False on EOF first.
    public bool ReadUntil(byte[] delim, Stream sink)
    {
        while (true)
        {
            int idx = IndexOf(delim);
            if (idx >= 0)
            {
                if (sink != null) sink.Write(buf, start, idx - start);
                start = idx + delim.Length;
                return true;
            }
            int safe = end - start - (delim.Length - 1);
            if (safe > 0)
            {
                if (sink != null) sink.Write(buf, start, safe);
                start += safe;
            }
            if (!Fill()) return false;
        }
    }

    int IndexOf(byte[] delim)
    {
        int last = end - delim.Length;
        for (int i = start; i <= last; i++)
        {
            i = Array.IndexOf(buf, delim[0], i, last - i + 1);
            if (i < 0) return -1;
            int j = 1;
            while (j < delim.Length && buf[i + j] == delim[j]) j++;
            if (j == delim.Length) return i;
        }
        return -1;
    }
}
