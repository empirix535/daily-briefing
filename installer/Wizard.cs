// Otis setup: the wizard window and its pages. C# 5.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace OtisSetup
{
    static class Theme
    {
        public static readonly Color Ink = Color.FromArgb(27, 42, 65);
        public static readonly Color Muted = Color.FromArgb(96, 108, 125);
        public static readonly Color Accent = Color.FromArgb(46, 108, 176);
        public static readonly Color Good = Color.FromArgb(30, 132, 73);
        public static readonly Color Bad = Color.FromArgb(192, 57, 43);
        public static readonly Color Line = Color.FromArgb(222, 226, 232);
        public static readonly Color Band = Color.FromArgb(246, 248, 251);
        public static Font Body = new Font("Segoe UI", 9F);
        public static Font Small = new Font("Segoe UI", 8.25F);
        public static Font Title = new Font("Segoe UI Semibold", 15F);
        public static Font Bold = new Font("Segoe UI Semibold", 9F);
    }

    static class UI
    {
        public static Label Text(Control parent, string text, int x, int y, int w, int h, Font f, Color c)
        {
            Label l = new Label();
            l.Text = text; l.Left = x; l.Top = y; l.Width = w; l.Height = h;
            l.Font = f ?? Theme.Body; l.ForeColor = c; l.BackColor = Color.Transparent;
            parent.Controls.Add(l);
            return l;
        }
        public static Label Text(Control parent, string text, int x, int y, int w, int h) { return Text(parent, text, x, y, w, h, null, Theme.Ink); }
        public static Label Hint(Control parent, string text, int x, int y, int w, int h) { return Text(parent, text, x, y, w, h, Theme.Small, Theme.Muted); }

        public static TextBox Box(Control parent, int x, int y, int w)
        {
            TextBox t = new TextBox(); t.Left = x; t.Top = y; t.Width = w; t.Font = Theme.Body;
            parent.Controls.Add(t);
            return t;
        }
        public static Button Btn(Control parent, string text, int x, int y, int w)
        {
            Button b = new Button(); b.Text = text; b.Left = x; b.Top = y; b.Width = w; b.Height = 26;
            b.Font = Theme.Body; b.FlatStyle = FlatStyle.System;
            parent.Controls.Add(b);
            return b;
        }
        public static CheckBox Check(Control parent, string text, int x, int y, int w, bool on)
        {
            CheckBox c = new CheckBox(); c.Text = text; c.Left = x; c.Top = y; c.Width = w; c.Height = 22;
            c.Font = Theme.Body; c.Checked = on; c.ForeColor = Theme.Ink; c.BackColor = Color.Transparent;
            parent.Controls.Add(c);
            return c;
        }
        public static RadioButton Radio(Control parent, string text, int x, int y, int w, bool on)
        {
            RadioButton r = new RadioButton(); r.Text = text; r.Left = x; r.Top = y; r.Width = w; r.Height = 22;
            r.Font = Theme.Body; r.Checked = on; r.ForeColor = Theme.Ink; r.BackColor = Color.Transparent;
            parent.Controls.Add(r);
            return r;
        }
        public static string PickFolder(string current, string description)
        {
            using (FolderBrowserDialog d = new FolderBrowserDialog())
            {
                d.Description = description;
                d.ShowNewFolderButton = true;
                if (!string.IsNullOrEmpty(current) && Directory.Exists(current)) d.SelectedPath = current;
                return d.ShowDialog() == DialogResult.OK ? d.SelectedPath : null;
            }
        }
    }

    abstract class Page : Panel
    {
        public string Heading = "", Sub = "";
        protected Opts O;
        protected Page(Opts o)
        {
            O = o; Dock = DockStyle.Fill; BackColor = Color.White; Visible = false;
        }
        public virtual void OnShow() { }
        public virtual string Validate() { return null; }
        public virtual bool Skip { get { return false; } }
    }

    // ---------------------------------------------------------------- welcome
    class WelcomePage : Page
    {
        public Button UninstallBtn;
        public WelcomePage(Opts o) : base(o)
        {
            Heading = "Welcome to Otis";
            Sub = "Setup takes about two minutes.";
            UI.Text(this, o.Upgrade
                ? "Otis is already installed on this PC. Setup will update it and keep your notes, to-dos, and settings."
                : "Otis is your admin assistant. It lives in your Teams notes-to-self chat, watches your inbox and calendar, and keeps a To-do, Notes, and Streams dashboard.",
                24, 20, 590, 54);
            UI.Text(this, "Setup will check what Otis needs, ask a few questions about you, and put everything in one folder you choose. Nothing is installed outside that folder except shortcuts and the Teams sign-in profile.",
                24, 84, 590, 54);
            UI.Hint(this, "Otis reads your mail and calendar through your own Claude account. It never sends email, never changes your calendar, and never messages anyone but you.", 24, 150, 590, 40);
            if (o.Upgrade)
            {
                UninstallBtn = UI.Btn(this, "Uninstall Otis...", 24, 214, 130);
            }
        }
    }

    // ---------------------------------------------------------------- location
    class LocationPage : Page
    {
        public TextBox Dir;
        Label warn;
        public LocationPage(Opts o) : base(o)
        {
            Heading = "Install location";
            Sub = "Otis keeps its program, your data, and your settings in one folder.";
            UI.Text(this, "Install Otis in:", 24, 18, 300, 20);
            Dir = UI.Box(this, 24, 42, 480);
            Button b = UI.Btn(this, "Browse...", 514, 40, 90);
            b.Click += delegate { string p = UI.PickFolder(Dir.Text, "Choose the folder to install Otis in"); if (p != null) Dir.Text = p; };
            Dir.TextChanged += delegate { Refresh2(); };
            UI.Hint(this, "To keep your data in sync across PCs, choose a folder inside OneDrive. Otis needs about 5 MB plus your notes and logs.", 24, 78, 590, 34);
            warn = UI.Text(this, "", 24, 120, 590, 70, Theme.Small, Theme.Muted);
        }
        public override void OnShow()
        {
            if (string.IsNullOrEmpty(Dir.Text)) Dir.Text = O.InstallDir;
            Refresh2();
        }
        void Refresh2()
        {
            string p = Dir.Text.Trim();
            string msg = "";
            try
            {
                if (p.Length > 3 && Path.IsPathRooted(p))
                {
                    string od = Engine.OneDriveRoot();
                    if (od != null && Engine.IsInside(p, od))
                        msg += "This folder is inside OneDrive. If you see online-only files there later, right-click the folder and choose Always keep on this device, so Otis starts quickly.\r\n";
                    if (Directory.Exists(p) && File.Exists(Path.Combine(p, "Otis.exe")))
                        msg += "Otis is already in this folder. Setup will update it and keep your data.\r\n";
                }
            }
            catch { }
            warn.Text = msg;
        }
        public override string Validate()
        {
            string p = Dir.Text.Trim();
            if (p.Length < 4 || !Path.IsPathRooted(p)) return "Enter a full folder path, for example C:\\Otis.";
            try
            {
                Directory.CreateDirectory(p);
                string probe = Path.Combine(p, ".otis-write-test");
                File.WriteAllText(probe, "x"); File.Delete(probe);
            }
            catch (Exception ex) { return "Setup cannot write to that folder: " + ex.Message; }
            if (Directory.GetFileSystemEntries(p).Length > 0 && !File.Exists(Path.Combine(p, "Otis.exe")))
            {
                if (MessageBox.Show("That folder is not empty and does not look like an Otis install. Install into it anyway?", "Otis Setup",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return "";
            }
            O.InstallDir = Path.GetFullPath(p);
            return null;
        }
    }

    // ---------------------------------------------------------------- requirements
    class RequirementsPage : Page
    {
        Label browser, claude, signin;
        Button installClaude, signIn, check, recheck;
        string claudePath, browserPath;
        bool signedIn;
        public RequirementsPage(Opts o) : base(o)
        {
            Heading = "What Otis needs";
            Sub = "Otis uses your browser, Claude Code, and your Claude account.";
            UI.Text(this, "Browser (Chrome or Edge)", 24, 18, 220, 20, Theme.Bold, Theme.Ink);
            browser = UI.Text(this, "", 250, 18, 360, 20);
            UI.Text(this, "Claude Code", 24, 52, 220, 20, Theme.Bold, Theme.Ink);
            claude = UI.Text(this, "", 250, 52, 360, 20);
            installClaude = UI.Btn(this, "Install Claude Code", 24, 76, 150);
            installClaude.Click += delegate
            {
                try { Process.Start("powershell.exe", "-NoExit -ExecutionPolicy Bypass -Command \"irm https://claude.ai/install.ps1 | iex\""); } catch (Exception ex) { MessageBox.Show(ex.Message); }
            };
            recheck = UI.Btn(this, "Check again", 184, 76, 110);
            recheck.Click += delegate { Detect(); };

            UI.Text(this, "Claude sign-in", 24, 124, 220, 20, Theme.Bold, Theme.Ink);
            signin = UI.Text(this, "Not checked yet", 250, 124, 360, 20, Theme.Body, Theme.Muted);
            signIn = UI.Btn(this, "Sign in to Claude...", 24, 148, 150);
            signIn.Click += delegate { OpenSignIn(); };
            check = UI.Btn(this, "Test sign-in", 184, 148, 110);
            check.Click += delegate { TestSignIn(); };
            UI.Hint(this, "Sign in opens a console window. Type /login, finish in your browser (use the account with your Claude plan), then type /exit. Then press Test sign-in.", 24, 180, 590, 34);

            UI.Text(this, "Microsoft 365 connector", 24, 232, 220, 20, Theme.Bold, Theme.Ink);
            UI.Text(this, "Turn it on in your Claude account (read access is enough). Otis reads mail and calendar through it.", 24, 254, 590, 20);
            LinkLabel ll = new LinkLabel();
            ll.Text = "Open Claude connector settings"; ll.Left = 24; ll.Top = 278; ll.Width = 300; ll.Height = 20; ll.Font = Theme.Body;
            ll.LinkClicked += delegate { try { Process.Start("https://claude.ai/settings/connectors"); } catch { } };
            Controls.Add(ll);
        }
        public override void OnShow() { Detect(); }
        void Detect()
        {
            browserPath = Engine.FindBrowser();
            claudePath = Engine.FindClaude();
            Set(browser, browserPath != null, browserPath != null ? "Found" : "Not found. Install Chrome or Edge.");
            Set(claude, claudePath != null, claudePath != null ? "Found" : "Not found. Press Install Claude Code.");
            installClaude.Enabled = claudePath == null;
            check.Enabled = claudePath != null;
            signIn.Enabled = claudePath != null;
            O.ClaudePath = claudePath ?? "";
        }
        static void Set(Label l, bool ok, string text) { l.Text = text; l.ForeColor = ok ? Theme.Good : Theme.Bad; }
        void OpenSignIn()
        {
            try
            {
                string exe = claudePath ?? Engine.FindClaude();
                if (exe == null) return;
                ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/k \"\"" + exe + "\"\"");
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Otis Setup"); }
        }
        void TestSignIn()
        {
            string exe = claudePath ?? Engine.FindClaude();
            if (exe == null) return;
            check.Enabled = false;
            signin.Text = "Testing... this can take up to a minute"; signin.ForeColor = Theme.Muted;
            Thread t = new Thread(delegate()
            {
                bool ok = false; string detail = "";
                try
                {
                    string file = exe, args = "-p \"Reply with the single word OK\" --model haiku";
                    if (exe.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)) { file = "cmd.exe"; args = "/c \"\"" + exe + "\" " + args + "\""; }
                    ProcessStartInfo psi = new ProcessStartInfo(file, args);
                    psi.UseShellExecute = false; psi.CreateNoWindow = true;
                    psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                    psi.EnvironmentVariables.Remove("ANTHROPIC_API_KEY");
                    using (Process p = Process.Start(psi))
                    {
                        string so = "", se = "";
                        Thread rd = new Thread(delegate() { se = p.StandardError.ReadToEnd(); });
                        rd.Start();
                        so = p.StandardOutput.ReadToEnd();
                        if (!p.WaitForExit(90000)) { try { p.Kill(); } catch { } detail = "No answer within 90 seconds."; }
                        else
                        {
                            rd.Join(2000);
                            ok = p.ExitCode == 0 && so.Trim().Length > 0;
                            if (!ok) detail = (se.Trim().Length > 0 ? se.Trim() : so.Trim());
                        }
                    }
                }
                catch (Exception ex) { detail = ex.Message; }
                try
                {
                    BeginInvoke(new MethodInvoker(delegate
                    {
                        signedIn = ok;
                        check.Enabled = true;
                        if (ok) Set(signin, true, "Signed in");
                        else Set(signin, false, "Not signed in" + (detail.Length > 0 ? ": " + Trim(detail) : ""));
                    }));
                }
                catch { }
            });
            t.IsBackground = true; t.Start();
        }
        static string Trim(string s) { s = s.Replace("\r", " ").Replace("\n", " "); return s.Length > 70 ? s.Substring(0, 70) + "..." : s; }
        public override string Validate()
        {
            Detect();
            if (browserPath == null) return "Otis needs Chrome or Edge. Install one, then press Check again.";
            if (claudePath == null) return "Otis needs Claude Code. Press Install Claude Code, then Check again.";
            if (!signedIn)
            {
                DialogResult r = MessageBox.Show("Your Claude sign-in has not been confirmed. Otis will not work until you are signed in.\r\n\r\nContinue anyway?",
                    "Otis Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return "";
            }
            return null;
        }
    }

    // ---------------------------------------------------------------- data
    class DataPage : Page
    {
        RadioButton rFresh, rKeep, rImport, rRestore;
        TextBox tImport, tRestore;
        Button bImport, bRestore;
        string backupFound;
        public DataPage(Opts o) : base(o)
        {
            Heading = "Your data";
            Sub = "Bring your notes, to-dos, and settings with you, or start clean.";
            rKeep = UI.Radio(this, "Keep the data already in the install folder", 24, 16, 580, false);
            rImport = UI.Radio(this, "Import from another Otis folder (an earlier install or a copy)", 24, 54, 580, false);
            tImport = UI.Box(this, 46, 80, 458);
            bImport = UI.Btn(this, "Browse...", 514, 78, 90);
            bImport.Click += delegate { string p = UI.PickFolder(tImport.Text, "Choose the earlier Otis folder (it contains settings.json and data)"); if (p != null) { tImport.Text = p; rImport.Checked = true; } };
            rRestore = UI.Radio(this, "Restore from a backup folder", 24, 120, 580, false);
            tRestore = UI.Box(this, 46, 146, 458);
            bRestore = UI.Btn(this, "Browse...", 514, 144, 90);
            bRestore.Click += delegate { string p = UI.PickFolder(tRestore.Text, "Choose the Otis backup folder"); if (p != null) { tRestore.Text = p; rRestore.Checked = true; } };
            rFresh = UI.Radio(this, "Start fresh", 24, 186, 580, true);
            UI.Hint(this, "Import copies the data folder and settings.json and leaves the original untouched.", 46, 100, 560, 18);
            UI.Hint(this, "Backups are made by Otis once a day. Pick the folder named Otis backup.", 46, 166, 560, 18);
            rImport.CheckedChanged += delegate { Enable(); };
            rRestore.CheckedChanged += delegate { Enable(); };
        }
        void Enable()
        {
            tImport.Enabled = bImport.Enabled = rImport.Checked;
            tRestore.Enabled = bRestore.Enabled = rRestore.Checked;
        }
        public override void OnShow()
        {
            string dir = O.InstallDir;
            bool existing = Directory.Exists(dir) && (File.Exists(Path.Combine(dir, "settings.json")) || Directory.Exists(Path.Combine(dir, "data")));
            rKeep.Visible = existing;
            string od = Engine.OneDriveRoot();
            backupFound = null;
            if (od != null)
                foreach (string nm in new string[] { "Otis backup", "Daily Briefing backup" })
                {
                    string c = Path.Combine(od, nm);
                    if (backupFound == null && Directory.Exists(Path.Combine(c, "latest"))) backupFound = c;
                }
            if (tRestore.Text.Length == 0 && backupFound != null) tRestore.Text = backupFound;
            if (existing && !rImport.Checked && !rRestore.Checked) rKeep.Checked = true;
            Enable();
        }
        public override string Validate()
        {
            if (rImport.Checked)
            {
                string p = tImport.Text.Trim();
                if (!Directory.Exists(p) || (!File.Exists(Path.Combine(p, "settings.json")) && !Directory.Exists(Path.Combine(p, "data"))))
                    return "That folder has no settings.json or data folder. Choose the earlier Otis folder.";
                if (Engine.IsInside(O.InstallDir, p) || Engine.IsInside(p, O.InstallDir)) return "Choose a folder other than the install folder.";
                O.DataMode = "import"; O.DataSource = p;
            }
            else if (rRestore.Checked)
            {
                string p = tRestore.Text.Trim();
                string latest = Path.Combine(p, "latest");
                if (!Directory.Exists(p) || (!Directory.Exists(latest) && !File.Exists(Path.Combine(p, "settings.json"))))
                    return "That folder does not look like an Otis backup. Choose the folder named Otis backup.";
                O.DataMode = "restore"; O.DataSource = p;
            }
            else if (rKeep.Checked && rKeep.Visible) { O.DataMode = "keep"; O.DataSource = ""; }
            else { O.DataMode = "fresh"; O.DataSource = ""; }
            return null;
        }
    }

    // ---------------------------------------------------------------- about you
    class ProfilePage : Page
    {
        TextBox name, desc, mail, domain;
        public ProfilePage(Opts o) : base(o)
        {
            Heading = "About you";
            Sub = "Otis uses this to write in your voice and recognize colleagues.";
            UI.Text(this, "Your first name", 24, 16, 300, 20);
            name = UI.Box(this, 24, 38, 300);
            UI.Hint(this, "How you sign emails and how Otis addresses you.", 336, 41, 280, 18);
            UI.Text(this, "One line about you", 24, 72, 300, 20);
            desc = UI.Box(this, 24, 94, 580);
            UI.Hint(this, "For example: a program officer at Example Org", 24, 120, 580, 18);
            UI.Text(this, "Work email address", 24, 150, 300, 20);
            mail = UI.Box(this, 24, 172, 300);
            UI.Hint(this, "Used for links and invites to yourself.", 336, 175, 280, 18);
            UI.Text(this, "Your organization's email domain", 24, 208, 300, 20);
            domain = UI.Box(this, 24, 230, 300);
            UI.Hint(this, "For example: example.org. Otis treats this domain as internal. Optional.", 24, 256, 580, 18);
        }
        public override void OnShow()
        {
            // Pre-fill from the settings that will be used: an import, a backup, or the existing install
            if (name.Text.Length > 0) return;
            string src = null;
            if (O.DataMode == "import") src = Path.Combine(O.DataSource, "settings.json");
            else if (O.DataMode == "restore")
            {
                string latest = Path.Combine(O.DataSource, "latest");
                src = Path.Combine(Directory.Exists(latest) ? latest : O.DataSource, "settings.json");
            }
            else if (O.DataMode == "keep") src = Path.Combine(O.InstallDir, "settings.json");
            if (src != null && File.Exists(src))
            {
                try
                {
                    Dictionary<string, object> s = Engine.ReadSettings(src);
                    name.Text = Engine.StringOf(s, "UserName"); desc.Text = Engine.StringOf(s, "UserDescription");
                    mail.Text = Engine.StringOf(s, "UserEmail"); domain.Text = Engine.FirstDomain(s);
                }
                catch { }
            }
        }
        public override string Validate()
        {
            if (name.Text.Trim().Length == 0) return "Enter your first name.";
            string m = mail.Text.Trim();
            if (m.Length > 0 && (m.IndexOf('@') < 1 || m.IndexOf('.') < 0)) return "That email address does not look right.";
            O.UserName = name.Text.Trim(); O.Description = desc.Text.Trim(); O.Email = m; O.Domain = domain.Text.Trim();
            return null;
        }
    }

    // ---------------------------------------------------------------- options
    class OptionsPage : Page
    {
        TextBox streams, backup;
        Button bStreams, bBackup;
        CheckBox cBackup, cStart, cDesk;
        Label bhint;
        public OptionsPage(Opts o) : base(o)
        {
            Heading = "Options";
            Sub = "You can change all of these later in settings.json.";
            UI.Text(this, "Streams file (the Streams tab reads and edits it)", 24, 14, 580, 20);
            streams = UI.Box(this, 24, 36, 480);
            bStreams = UI.Btn(this, "Browse...", 514, 34, 90);
            bStreams.Click += delegate
            {
                using (OpenFileDialog d = new OpenFileDialog())
                {
                    d.Title = "Choose streams.json"; d.Filter = "streams.json|*.json|All files|*.*"; d.CheckFileExists = false;
                    if (d.ShowDialog() == DialogResult.OK) streams.Text = d.FileName;
                }
            };
            UI.Hint(this, "Leave the suggestion to start with an empty one inside the install folder.", 24, 62, 580, 18);

            cBackup = UI.Check(this, "Back up my data every day to:", 24, 96, 580, false);
            backup = UI.Box(this, 46, 122, 458);
            bBackup = UI.Btn(this, "Browse...", 514, 120, 90);
            bBackup.Click += delegate { string p = UI.PickFolder(backup.Text, "Choose the backup folder"); if (p != null) { backup.Text = p; cBackup.Checked = true; } };
            bhint = UI.Hint(this, "", 46, 148, 560, 32);
            cBackup.CheckedChanged += delegate { backup.Enabled = bBackup.Enabled = cBackup.Checked; };

            cStart = UI.Check(this, "Start Otis when I sign in to Windows", 24, 196, 580, true);
            cDesk = UI.Check(this, "Add a desktop shortcut", 24, 224, 580, true);
            UI.Hint(this, "A Start menu shortcut is always added. To pin Otis to the taskbar, right-click it in Start.", 24, 256, 580, 18);
        }
        public override void OnShow()
        {
            string data = Path.Combine(O.InstallDir, "data");
            if (streams.Text.Length == 0)
            {
                string preset = null;
                string src = null;
                if (O.DataMode == "import") src = Path.Combine(O.DataSource, "settings.json");
                else if (O.DataMode == "keep") src = Path.Combine(O.InstallDir, "settings.json");
                else if (O.DataMode == "restore")
                {
                    string latest = Path.Combine(O.DataSource, "latest");
                    src = Path.Combine(Directory.Exists(latest) ? latest : O.DataSource, "settings.json");
                }
                Dictionary<string, object> s = null;
                try { if (src != null && File.Exists(src)) s = Engine.ReadSettings(src); } catch { }
                preset = Engine.StringOf(s, "StreamsPath");
                if (preset.Length == 0 && O.DataMode != "fresh") preset = Engine.LegacyStreamsPath();
                streams.Text = !string.IsNullOrEmpty(preset) ? preset : Path.Combine(data, "streams.json");

                string bp = Engine.StringOf(s, "BackupPath");
                if (bp.Length > 0) { backup.Text = bp; cBackup.Checked = true; }
            }
            string od = Engine.OneDriveRoot();
            bool inOd = od != null && Engine.IsInside(O.InstallDir, od);
            if (backup.Text.Length == 0)
            {
                if (od != null) backup.Text = Path.Combine(od, "Otis backup");
                cBackup.Checked = od != null && !inOd;
            }
            bhint.Text = inOd ? "Your install folder is inside OneDrive, so your data already syncs. A separate backup adds dated copies for two weeks."
                              : "Keeps the latest copy and two weeks of dated copies. A OneDrive folder also carries your data to a new PC.";
            backup.Enabled = bBackup.Enabled = cBackup.Checked;
        }
        public override string Validate()
        {
            string sp = streams.Text.Trim();
            if (sp.Length > 0 && !Path.IsPathRooted(sp)) return "Enter the full path to the streams file.";
            O.StreamsPath = sp;
            if (cBackup.Checked)
            {
                string bp = backup.Text.Trim();
                if (bp.Length < 4 || !Path.IsPathRooted(bp)) return "Enter the full path of the backup folder, or untick the backup.";
                O.BackupPath = bp;
            }
            else O.BackupPath = "";
            O.StartWithWindows = cStart.Checked; O.DesktopShortcut = cDesk.Checked;
            return null;
        }
    }

    // ---------------------------------------------------------------- summary
    class SummaryPage : Page
    {
        public SummaryPage(Opts o) : base(o)
        {
            Heading = "Ready to install";
            Sub = "Review your choices. Press Install to continue.";
        }
        void Row(int i, string k, string v)
        {
            UI.Text(this, k, 24, 20 + i * 30, 130, 22, Theme.Bold, Theme.Ink);
            UI.Text(this, v, 160, 20 + i * 30, 460, 22);
        }
        public override void OnShow()
        {
            for (int i = Controls.Count - 1; i >= 0; i--) Controls[i].Dispose();
            Controls.Clear();
            string dm = O.DataMode == "import" ? "Import from " + O.DataSource : O.DataMode == "restore" ? "Restore from " + O.DataSource :
                O.DataMode == "keep" ? "Keep what is already there" : "Start fresh";
            Row(0, "Install folder", O.InstallDir);
            Row(1, "Data", dm);
            Row(2, "You", O.UserName + (O.Email.Length > 0 ? " (" + O.Email + ")" : ""));
            Row(3, "Streams file", O.StreamsPath.Length > 0 ? O.StreamsPath : "data\\streams.json in the install folder");
            Row(4, "Daily backup", O.BackupPath.Length > 0 ? O.BackupPath : "Off");
            Row(5, "Shortcuts", "Start menu" + (O.DesktopShortcut ? ", Desktop" : "") + (O.StartWithWindows ? ", start with Windows" : ""));
            UI.Hint(this, "If Otis is running now, Setup closes it first.", 24, 20 + 6 * 30 + 12, 590, 20);
        }
    }

    // ---------------------------------------------------------------- progress and finish
    class ProgressPage : Page
    {
        public ProgressBar Bar; public Label Status; public TextBox Log;
        public ProgressPage(Opts o) : base(o)
        {
            Heading = "Installing";
            Sub = "This takes a few seconds.";
            Status = UI.Text(this, "Starting", 24, 20, 590, 20);
            Bar = new ProgressBar(); Bar.Left = 24; Bar.Top = 46; Bar.Width = 590; Bar.Height = 18; Bar.Maximum = 100;
            Controls.Add(Bar);
            Log = UI.Box(this, 24, 80, 590); Log.Multiline = true; Log.ReadOnly = true; Log.Height = 190; Log.ScrollBars = ScrollBars.Vertical;
            Log.BackColor = Color.White;
        }
    }

    class FinishPage : Page
    {
        public CheckBox Launch; public Label Message;
        public FinishPage(Opts o) : base(o)
        {
            Heading = "Otis is installed";
            Sub = "One more step: sign in to Teams.";
            Message = UI.Text(this, "", 24, 16, 590, 120);
            Launch = UI.Check(this, "Open Otis now", 24, 150, 300, true);
        }
    }
}
