// 傳到電腦 — system tray companion. Starts with Windows (Startup folder), shows a
// notification for every received item, copies received text to the clipboard,
// answers the iPhone's "get PC clipboard" requests, and watches that the boot-time
// receiver service is up. "AirDropReceiver.exe --send <paths>" (Explorer's 傳送到 menu)
// queues files for the iPhone in data\outbox.
// Built by install.ps1 with the .NET Framework csc (C# 5).
using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--send")
        {
            Outbox.SendAndNotify(args.Skip(1).ToArray());
            return;
        }
        bool created;
        using (Mutex mutex = new Mutex(true, "AirDropReceiverTray", out created))
        {
            if (!created) return;
            Application.EnableVisualStyles();
            Application.Run(new TrayContext());
        }
    }
}

// PC -> iPhone queue. One folder per item, data\outbox\<id>\<file>; written as "<id>.tmp"
// and renamed when complete so the server never lists a half-copied file.
static class Outbox
{
    static string Dir { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"data\outbox"); } }

    // Copies each file (folders are zipped) into the outbox; returns the names added.
    public static List<string> Add(IEnumerable<string> paths)
    {
        List<string> added = new List<string>();
        foreach (string p in paths)
        {
            string id = DateTime.Now.ToString("yyyyMMddHHmmssfff") + "-" + Guid.NewGuid().ToString("N").Substring(0, 4);
            string tmp = Path.Combine(Dir, id + ".tmp");
            try
            {
                Directory.CreateDirectory(tmp);
                string name;
                if (Directory.Exists(p))
                {
                    name = new DirectoryInfo(p).Name + ".zip";
                    ZipFile.CreateFromDirectory(p, Path.Combine(tmp, name));
                }
                else
                {
                    name = Path.GetFileName(p);
                    File.Copy(p, Path.Combine(tmp, name));
                }
                Directory.Move(tmp, Path.Combine(Dir, id));
                added.Add(name);
            }
            catch
            {
                try { Directory.Delete(tmp, true); } catch { }
            }
        }
        if (added.Count > 0) Announce(added);
        return added;
    }

    // Lets the server send the ntfy push to the iPhone.
    static void Announce(List<string> names)
    {
        try
        {
            int port = 8765;
            Dictionary<string, object> cfg = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(
                File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json")));
            object v;
            if (cfg.TryGetValue("port", out v)) port = Convert.ToInt32(v);
            using (WebClient wc = new WebClient())
            {
                wc.Proxy = null;
                wc.Encoding = Encoding.UTF8;
                wc.Headers[HttpRequestHeader.ContentType] = "text/plain; charset=utf-8";
                wc.UploadString("http://localhost:" + port + "/api/outbox-added", string.Join("\n", names));
            }
        }
        catch { }
    }

    // --send mode: queue the files, show one notification, exit.
    public static void SendAndNotify(string[] paths)
    {
        List<string> added = Add(paths);
        using (NotifyIcon n = new NotifyIcon())
        {
            n.Icon = TrayContext.LoadIcon();
            n.Visible = true;
            n.ShowBalloonTip(5000,
                added.Count > 0 ? "已傳到 iPhone 收件匣（" + added.Count + " 個）" : "沒有加入任何檔案",
                "iPhone 會收到 ntfy 通知，點一下接收", ToolTipIcon.None);
            System.Windows.Forms.Timer quit = new System.Windows.Forms.Timer();
            quit.Interval = 6000;
            quit.Tick += delegate { Application.ExitThread(); };
            quit.Start();
            Application.Run();
            n.Visible = false;
        }
    }
}

class TrayContext : ApplicationContext
{
    const string TaskName = "AirDropReceiver";
    static readonly string Version = Application.ProductVersion;   // from VERSION, stamped by build-tray.ps1
    readonly string appDir = AppDomain.CurrentDomain.BaseDirectory;
    readonly string logPath;
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly NotifyIcon tray;
    readonly Control ui = new Control();
    readonly System.Windows.Forms.Timer logTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer healthTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer clipTimer = new System.Windows.Forms.Timer();

    int port = 8765;
    bool clipPolling;
    bool openLinks = true;   // config.json "openLinks": false turns auto-open off
    string saveDir;
    long logOffset;
    string clickTarget;      // what clicking the last notification opens
    bool clickSelects;       // true: reveal the file in Explorer
    bool? serviceUp;

    public TrayContext()
    {
        logPath = Path.Combine(appDir, @"data\received.log");
        ui.CreateControl();
        LoadConfig();

        ContextMenuStrip menu = new ContextMenuStrip();
        ToolStripItem open = menu.Items.Add("開啟傳到電腦", null, delegate { OpenPage(); });
        open.Font = new Font(open.Font, FontStyle.Bold);
        menu.Items.Add("開啟下載資料夾", null, delegate { Launch(saveDir); });
        menu.Items.Add("傳檔案到 iPhone…", null, delegate { PickFilesForIPhone(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("重新啟動接收服務", null, delegate { RestartService(); });
        menu.Items.Add("結束", null, delegate { ExitThread(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("版本 v" + Version).Enabled = false;

        tray = new NotifyIcon();
        tray.Icon = LoadIcon();
        tray.Text = "傳到電腦 v" + Version;
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.DoubleClick += delegate { OpenPage(); };
        tray.BalloonTipClicked += delegate { OnNotificationClick(); };

        // Only announce items received from now on.
        logOffset = File.Exists(logPath) ? new FileInfo(logPath).Length : 0;
        logTimer.Interval = 1000;
        logTimer.Tick += delegate { ReadNewEvents(); };
        logTimer.Start();

        // Also the heartbeat that tells the server the tray is here to answer clipboard requests.
        clipTimer.Interval = 700;
        clipTimer.Tick += delegate { PollClipboardRequest(); };
        clipTimer.Start();

        healthTimer.Interval = 10000;
        healthTimer.Tick += delegate { CheckHealth(); };
        healthTimer.Start();
        CheckHealth();
    }

    void LoadConfig()
    {
        saveDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        try
        {
            Dictionary<string, object> cfg = json.Deserialize<Dictionary<string, object>>(
                File.ReadAllText(Path.Combine(appDir, "config.json")));
            object v;
            if (cfg.TryGetValue("port", out v)) port = Convert.ToInt32(v);
            if (cfg.TryGetValue("saveDir", out v) && v != null) saveDir = v.ToString();
            if (cfg.TryGetValue("openLinks", out v) && v is bool) openLinks = (bool)v;
        }
        catch { }
    }

    public static Icon LoadIcon()
    {
        string ico = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"assets\app.ico");
        try { return new Icon(ico, SystemInformation.SmallIconSize); }
        catch { return SystemIcons.Application; }
    }

    void PickFilesForIPhone()
    {
        using (OpenFileDialog dlg = new OpenFileDialog())
        {
            dlg.Title = "選擇要傳到 iPhone 的檔案";
            dlg.Multiselect = true;
            if (dlg.ShowDialog() != DialogResult.OK) return;
            List<string> added = Outbox.Add(dlg.FileNames);
            Notify("已傳到 iPhone 收件匣（" + added.Count + " 個）", "iPhone 會收到 ntfy 通知，點一下接收", null, false);
        }
    }

    // --- PC clipboard -> iPhone: only read when the server says an iPhone is waiting ---

    void PollClipboardRequest()
    {
        if (clipPolling) return;
        clipPolling = true;
        string url = "http://localhost:" + port + "/api/clip-wanted?v=" + Uri.EscapeDataString(Version);
        ThreadPool.QueueUserWorkItem(delegate
        {
            string answer = null;
            try { using (WebClient wc = NewClient()) answer = wc.DownloadString(url); } catch { }
            try
            {
                ui.BeginInvoke((MethodInvoker)delegate
                {
                    clipPolling = false;
                    if (answer == "1") ProvideClipboard();
                });
            }
            catch { clipPolling = false; }
        });
    }

    void ProvideClipboard()
    {
        byte[] body = new byte[0];
        string type = "text/plain; charset=utf-8";
        bool image = false;
        try
        {
            if (Clipboard.ContainsImage())
            {
                using (Image img = Clipboard.GetImage())
                using (MemoryStream ms = new MemoryStream())
                {
                    img.Save(ms, ImageFormat.Png);
                    body = ms.ToArray();
                }
                type = "image/png";
                image = true;
            }
            else if (Clipboard.ContainsText())
            {
                body = Encoding.UTF8.GetBytes(Clipboard.GetText());
            }
        }
        catch { }

        string url = "http://localhost:" + port + "/api/clip-provide";
        ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                using (WebClient wc = NewClient())
                {
                    wc.Headers[HttpRequestHeader.ContentType] = type;
                    wc.UploadData(url, "POST", body);
                }
            }
            catch { }
        });
        // Always say so: the clipboard can hold passwords.
        Notify("已把剪貼簿傳給 iPhone", image ? "（圖片）" : Shorten(Encoding.UTF8.GetString(body)), null, false);
    }

    static WebClient NewClient()
    {
        WebClient wc = new WebClient();
        wc.Proxy = null;
        wc.Encoding = Encoding.UTF8;
        return wc;
    }

    // --- iPhone clipboard -> PC ---

    void ApplyIncomingClip(string path)
    {
        try
        {
            if (path.EndsWith(".txt", StringComparison.OrdinalIgnoreCase))
            {
                string text = File.ReadAllText(path, Encoding.UTF8);
                Clipboard.SetText(text);
                Notify("已收到 iPhone 的剪貼簿", Shorten(text) + "\n可以直接貼上", null, false);
                return;
            }
            byte[] bytes = File.ReadAllBytes(path);
            using (MemoryStream ms = new MemoryStream(bytes))
            using (Image img = Image.FromStream(ms))
                Clipboard.SetImage(new Bitmap(img));
            Notify("已收到 iPhone 的剪貼簿（圖片）", "可以直接貼上", null, false);
        }
        catch
        {
            // Formats GDI+ can't read (e.g. HEIC): offer the file itself for pasting.
            try
            {
                StringCollection files = new StringCollection();
                files.Add(path);
                Clipboard.SetFileDropList(files);
                Notify("已收到 iPhone 的剪貼簿（檔案）", Path.GetFileName(path), path, true);
            }
            catch { }
        }
    }

    void OpenPage() { Launch("http://localhost:" + port + "/"); }

    static void Launch(string target)
    {
        try { Process.Start(target); } catch { }
    }

    void OnNotificationClick()
    {
        if (clickTarget == null) return;
        if (clickSelects) Launch("explorer.exe", "/select,\"" + clickTarget + "\"");
        else Launch(clickTarget);
    }

    static void Launch(string exe, string args)
    {
        try { Process.Start(exe, args); } catch { }
    }

    void Notify(string title, string text, string target, bool selects)
    {
        clickTarget = target;
        clickSelects = selects;
        tray.ShowBalloonTip(5000, title, text, ToolTipIcon.None);
    }

    void ReadNewEvents()
    {
        if (!File.Exists(logPath)) return;
        string chunk;
        try
        {
            using (FileStream fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (fs.Length < logOffset) logOffset = 0;   // log was reset
                if (fs.Length == logOffset) return;
                fs.Seek(logOffset, SeekOrigin.Begin);
                byte[] buf = new byte[fs.Length - logOffset];
                int read = fs.Read(buf, 0, buf.Length);
                int lastNewline = Array.LastIndexOf(buf, (byte)'\n', read - 1);
                if (lastNewline < 0) return;               // wait for a complete line
                logOffset += lastNewline + 1;
                chunk = Encoding.UTF8.GetString(buf, 0, lastNewline + 1);
            }
        }
        catch { return; }

        List<Dictionary<string, object>> files = new List<Dictionary<string, object>>();
        List<string> links = new List<string>();
        List<string> sent = new List<string>();
        string clipText = null;
        string clipPath = null;
        foreach (string line in chunk.Split('\n'))
        {
            if (line.Trim().Length == 0) continue;
            Dictionary<string, object> evt;
            try { evt = json.Deserialize<Dictionary<string, object>>(line); } catch { continue; }
            string kind = Get(evt, "kind");
            string text = Get(evt, "text");
            if (kind == "clip") { clipPath = Get(evt, "path"); continue; }
            if (kind == "sent") { sent.Add(Get(evt, "name")); continue; }
            if (text != null) clipText = text;
            if (kind == "file") files.Add(evt);
            else if (text != null && IsLink(text)) links.Add(text.Trim());
        }

        if (sent.Count > 0)
            Notify("iPhone 已接收", sent.Count == 1 ? sent[0] : sent.Count + " 個檔案", null, false);
        if (clipPath != null)
        {
            ApplyIncomingClip(clipPath);
            if (files.Count == 0 && links.Count == 0 && clipText == null) return;
        }

        if (clipText != null)
        {
            try { Clipboard.SetText(clipText); } catch { }
        }

        // Like AirDrop on a Mac: a received link opens straight in the default browser.
        if (openLinks)
        {
            foreach (string link in links) Launch(link);
            if (links.Count > 0 && files.Count == 0)
            {
                Notify("已開啟連結", Shorten(links[links.Count - 1]), links[links.Count - 1], false);
                return;
            }
        }

        if (files.Count == 1)
        {
            Notify("收到檔案", Get(files[0], "name"), Get(files[0], "path"), true);
        }
        else if (files.Count > 1)
        {
            Notify("收到 " + files.Count + " 個檔案", Get(files[files.Count - 1], "name") + " 等", saveDir, false);
        }
        else if (clipText != null)
        {
            string trimmed = clipText.Trim();
            bool isUrl = IsLink(trimmed);
            Notify(isUrl ? "收到連結（已複製）" : "收到文字（已複製）", Shorten(trimmed), isUrl ? trimmed : null, false);
        }
    }

    static bool IsLink(string text)
    {
        return Regex.IsMatch(text.Trim(), @"^https?://\S+$", RegexOptions.IgnoreCase);
    }

    static string Shorten(string text)
    {
        return text.Length > 120 ? text.Substring(0, 120) + "…" : text;
    }

    static string Get(Dictionary<string, object> d, string key)
    {
        object v;
        return d.TryGetValue(key, out v) && v != null ? v.ToString() : null;
    }

    void CheckHealth()
    {
        string url = "http://localhost:" + port + "/api/health";
        ThreadPool.QueueUserWorkItem(delegate
        {
            bool up = false;
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Proxy = null;
                req.Timeout = 3000;
                using (HttpWebResponse res = (HttpWebResponse)req.GetResponse()) up = res.StatusCode == HttpStatusCode.OK;
            }
            catch { }
            try { ui.BeginInvoke((MethodInvoker)delegate { SetServiceState(up); }); } catch { }
        });
    }

    void SetServiceState(bool up)
    {
        tray.Text = "傳到電腦 v" + Version + (up ? " · 接收中" : " · 接收服務未執行");
        if (serviceUp == true && !up)
            Notify("接收服務停止了", "會自動重新啟動；也可以從選單「重新啟動接收服務」。", null, false);
        serviceUp = up;
    }

    void RestartService()
    {
        try
        {
            RunHidden("schtasks.exe", "/End /TN " + TaskName);
            if (RunHidden("schtasks.exe", "/Run /TN " + TaskName) != 0)
                MessageBox.Show("無法啟動排程工作「" + TaskName + "」。請以系統管理員身分重新執行 install.ps1。", "傳到電腦");
        }
        catch (Exception e) { MessageBox.Show(e.Message, "傳到電腦"); }
        CheckHealth();
    }

    static int RunHidden(string exe, string args)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.CreateNoWindow = true;
        psi.UseShellExecute = false;
        using (Process p = Process.Start(psi))
        {
            p.WaitForExit(10000);
            return p.HasExited ? p.ExitCode : -1;
        }
    }

    protected override void ExitThreadCore()
    {
        tray.Visible = false;
        tray.Dispose();
        base.ExitThreadCore();
    }
}
