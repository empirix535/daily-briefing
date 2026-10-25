// Otis setup: the wizard frame, uninstall window, and entry point. C# 5.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace OtisSetup
{
    class WizardForm : Form
    {
        readonly Opts o;
        readonly List<Page> pages = new List<Page>();
        int index;
        Panel header, footer, body;
        Label title, subtitle;
        Button back, next, cancel;
        WelcomePage welcome; ProgressPage progress; FinishPage finish;
        bool working, done;

        public WizardForm(Opts opts)
        {
            o = opts;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Text = "Otis Setup";
            Font = Theme.Body;
            ClientSize = new Size(660, 470);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = true;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            header = new Panel(); header.Dock = DockStyle.Top; header.Height = 72; header.BackColor = Color.White;
            footer = new Panel(); footer.Dock = DockStyle.Bottom; footer.Height = 54; footer.BackColor = Theme.Band;
            body = new Panel(); body.Dock = DockStyle.Fill; body.BackColor = Color.White;
            Controls.Add(body); Controls.Add(footer); Controls.Add(header);

            Panel rule = new Panel(); rule.Dock = DockStyle.Bottom; rule.Height = 1; rule.BackColor = Theme.Line; header.Controls.Add(rule);
            Panel rule2 = new Panel(); rule2.Dock = DockStyle.Top; rule2.Height = 1; rule2.BackColor = Theme.Line; footer.Controls.Add(rule2);
            try
            {
                PictureBox pb = new PictureBox(); pb.Image = Image.FromStream(Engine.Res("logo.png")); pb.SizeMode = PictureBoxSizeMode.Zoom;
                pb.Left = 592; pb.Top = 12; pb.Width = 48; pb.Height = 48; header.Controls.Add(pb);
            }
            catch { }
            title = UI.Text(header, "", 24, 10, 550, 30, Theme.Title, Theme.Ink);
            subtitle = UI.Text(header, "", 26, 42, 550, 20, Theme.Body, Theme.Muted);

            back = UI.Btn(footer, "< Back", 330, 14, 90);
            next = UI.Btn(footer, "Next >", 426, 14, 100);
            cancel = UI.Btn(footer, "Cancel", 542, 14, 92);
            back.Click += delegate { Go(-1); };
            next.Click += delegate { OnNext(); };
            cancel.Click += delegate { Close(); };
            AcceptButton = next;

            welcome = new WelcomePage(o);
            pages.Add(welcome);
            pages.Add(new LocationPage(o));
            pages.Add(new RequirementsPage(o));
            pages.Add(new DataPage(o));
            pages.Add(new ProfilePage(o));
            pages.Add(new OptionsPage(o));
            pages.Add(new SummaryPage(o));
            progress = new ProgressPage(o); pages.Add(progress);
            finish = new FinishPage(o); pages.Add(finish);
            foreach (Page p in pages) body.Controls.Add(p);

            if (welcome.UninstallBtn != null)
                welcome.UninstallBtn.Click += delegate
                {
                    string dir = Engine.ExistingInstallDir();
                    if (dir == null) return;
                    string un = Path.Combine(dir, "Uninstall.exe");
                    try { Process.Start(un, "--uninstall"); Close(); }
                    catch (Exception ex) { MessageBox.Show("Could not start the uninstaller: " + ex.Message, "Otis Setup"); }
                };

            Show2(0);
        }

        void Show2(int i)
        {
            index = i;
            for (int k = 0; k < pages.Count; k++) pages[k].Visible = k == i;
            Page p = pages[i];
            title.Text = p.Heading; subtitle.Text = p.Sub;
            p.OnShow();
            back.Visible = i > 0 && i < pages.Count - 2;
            cancel.Visible = i < pages.Count - 2;
            next.Visible = true; next.Enabled = true;
            next.Text = i == pages.Count - 3 ? "Install" : (i == pages.Count - 1 ? "Finish" : "Next >");
            if (p == progress) { back.Visible = false; cancel.Visible = false; next.Visible = false; }
        }

        void Go(int d) { Show2(Math.Max(0, Math.Min(pages.Count - 1, index + d))); }

        void OnNext()
        {
            Page p = pages[index];
            if (p == finish)
            {
                if (finish.Launch.Checked)
                    try { Process.Start(Path.Combine(o.InstallDir, "Otis.exe")); } catch { }
                Close(); return;
            }
            string err = p.Validate();
            if (err != null) { if (err.Length > 0) MessageBox.Show(err, "Otis Setup", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
            if (pages[index + 1] == progress) { Show2(index + 1); RunInstall(); return; }
            Go(1);
        }

        void RunInstall()
        {
            working = true;
            BackgroundWorker w = new BackgroundWorker(); w.WorkerReportsProgress = true;
            string failure = null;
            w.DoWork += delegate
            {
                try { Engine.Install(o, delegate(int pct, string msg) { w.ReportProgress(pct, msg); }); }
                catch (Exception ex) { failure = ex.Message; }
            };
            w.ProgressChanged += delegate(object s, ProgressChangedEventArgs e)
            {
                progress.Bar.Value = Math.Max(0, Math.Min(100, e.ProgressPercentage));
                string m = Convert.ToString(e.UserState);
                progress.Status.Text = m + (e.ProgressPercentage < 100 ? "..." : "");
                progress.Log.AppendText(m + "\r\n");
            };
            w.RunWorkerCompleted += delegate
            {
                working = false;
                if (failure != null)
                {
                    progress.Heading = "Setup could not finish"; title.Text = progress.Heading;
                    subtitle.Text = "Nothing else was changed after the step below.";
                    progress.Status.Text = "Failed"; progress.Status.ForeColor = Theme.Bad;
                    progress.Log.AppendText("\r\nERROR: " + failure + "\r\n\r\nClose any open Otis windows and run Setup again.");
                    cancel.Text = "Close"; cancel.Visible = true;
                    done = true;
                    return;
                }
                done = true;
                string startMsg = "Otis is in " + o.InstallDir + ".\r\n\r\n" +
                    "The first time Otis starts, a Teams window opens. Sign in there once. It hides again and Otis begins watching your self-chat.\r\n\r\n" +
                    "Open Otis from the Start menu" + (o.DesktopShortcut ? " or the desktop" : "") + ". To uninstall, use Apps in Windows Settings.";
                finish.Message.Text = startMsg;
                Show2(pages.IndexOf(finish));
            };
            w.RunWorkerAsync();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (working) { e.Cancel = true; return; }
            if (!done && e.CloseReason == CloseReason.UserClosing && index > 0)
            {
                if (MessageBox.Show("Cancel Otis setup?", "Otis Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) e.Cancel = true;
            }
            base.OnFormClosing(e);
        }
    }

    // ------------------------------------------------------------------ uninstall window
    class UninstallForm : Form
    {
        readonly string dir;
        CheckBox cData; Label status; ProgressBar bar; Button go, close; Label msg;
        string selfExe;
        bool removed;
        public UninstallForm(string installDir, string self)
        {
            dir = installDir; selfExe = self;
            AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
            Text = "Uninstall Otis"; Font = Theme.Body; ClientSize = new Size(480, 250);
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen; BackColor = Color.White;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            UI.Text(this, "Remove Otis from this PC?", 20, 16, 440, 28, Theme.Title, Theme.Ink);
            msg = UI.Text(this, "This removes the program, its shortcuts, and the Teams sign-in profile.\r\nFolder: " + dir, 20, 56, 440, 44);
            cData = UI.Check(this, "Also delete my data (notes, to-dos, reminders, and settings)", 20, 108, 440, false);
            UI.Hint(this, "Leave this unticked to keep your data in the install folder for a later reinstall. A daily backup folder, if you set one, is never touched.", 22, 134, 440, 34);
            status = UI.Text(this, "", 20, 176, 440, 20, Theme.Body, Theme.Muted);
            bar = new ProgressBar(); bar.Left = 20; bar.Top = 198; bar.Width = 440; bar.Height = 8; bar.Visible = false; Controls.Add(bar);
            go = UI.Btn(this, "Uninstall", 270, 212, 90); close = UI.Btn(this, "Cancel", 370, 212, 90);
            close.Click += delegate { Close(); };
            go.Click += delegate { Run(); };
            AcceptButton = go;
        }

        void Run()
        {
            go.Enabled = false; close.Enabled = false; cData.Enabled = false; bar.Visible = true;
            bool delData = cData.Checked;
            string failure = null;
            BackgroundWorker w = new BackgroundWorker(); w.WorkerReportsProgress = true;
            w.DoWork += delegate
            {
                try { Engine.Uninstall(dir, delData, delegate(int p, string m) { w.ReportProgress(p, m); }); }
                catch (Exception ex) { failure = ex.Message; }
            };
            w.ProgressChanged += delegate(object s, ProgressChangedEventArgs e) { bar.Value = Math.Min(100, e.ProgressPercentage); status.Text = Convert.ToString(e.UserState) + "..."; };
            w.RunWorkerCompleted += delegate
            {
                close.Enabled = true; close.Text = "Close"; go.Visible = false;
                if (failure != null) { status.Text = "Could not finish: " + failure; status.ForeColor = Theme.Bad; return; }
                status.Text = "Otis was removed."; status.ForeColor = Theme.Good;
                removed = true;
            };
            w.RunWorkerAsync();
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            base.OnFormClosed(e);
            if (removed) { try { Engine.ScheduleSelfDelete(selfExe, dir); } catch { } }
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string self = Application.ExecutablePath;
            bool uninstall = false; string runDir = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--uninstall") uninstall = true;
                if (args[i] == "--uninstall-run" && i + 1 < args.Length) { uninstall = true; runDir = args[i + 1]; }
            }
            if (uninstall)
            {
                string dir = runDir ?? Engine.ExistingInstallDir() ?? Path.GetDirectoryName(self);
                // Run from a temporary copy so the install folder, including this file, can be deleted
                if (runDir == null && Engine.IsInside(self, dir))
                {
                    string tmp = Path.Combine(Path.GetTempPath(), "otis-uninstall-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".exe");
                    File.Copy(self, tmp, true);
                    Process.Start(tmp, "--uninstall-run \"" + dir + "\"");
                    return 0;
                }
                Application.Run(new UninstallForm(dir, self));
                return 0;
            }

            Opts o = new Opts();
            string existing = Engine.ExistingInstallDir();
            o.Upgrade = existing != null;
            o.InstallDir = existing ?? Engine.DefaultInstallDir();
            Application.Run(new WizardForm(o));
            return 0;
        }
    }
}
