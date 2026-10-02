namespace SxPilot {

    public class Application : Adw.Application {
        public Application () {
            Object (application_id: Config.APP_ID,
                    flags: ApplicationFlags.DEFAULT_FLAGS);
        }

        construct {
            ActionEntry[] entries = {
                { "about", on_about },
                { "preferences", on_preferences },
                { "quit", on_quit },
                { "new-window", on_new_window },
            };
            add_action_entries (entries, this);

            set_accels_for_action ("app.quit", { "<Control><Shift>q" });
            set_accels_for_action ("app.new-window", { "<Control><Shift>n" });
            set_accels_for_action ("app.preferences", { "<Control>comma" });
            /* Plain Ctrl+<key> belongs to the remote shell, so window
             * shortcuts use Ctrl+Shift. */
            set_accels_for_action ("win.new-connection", { "<Control><Shift>o" });
            set_accels_for_action ("win.new-group", { "<Control><Shift>g" });
            set_accels_for_action ("win.quick-connect", { "<Control><Shift>k" });
            set_accels_for_action ("win.search", { "<Control><Shift>f" });
            set_accels_for_action ("win.close-tab", { "<Control><Shift>w" });
            set_accels_for_action ("win.duplicate-tab", { "<Control><Shift>t" });
            set_accels_for_action ("win.open-sftp-here", { "<Control><Shift>s" });
            set_accels_for_action ("win.toggle-sidebar", { "F9" });
        }

        protected override void activate () {
            var win = active_window ?? new Window (this);
            win.present ();
        }

        private void on_new_window () {
            new Window (this).present ();
        }

        private void on_quit () {
            /* Close windows one by one so each can confirm open sessions. */
            foreach (var w in get_windows ().copy ()) {
                w.close ();
            }
        }

        private void on_preferences () {
            new PreferencesDialog ().present (active_window);
        }

        private void on_about () {
            var about = new Adw.AboutDialog ();
            about.application_name = "SxPilot";
            about.application_icon = Config.APP_ID;
            about.version = Config.VERSION;
            about.developer_name = "Agustín García";
            about.developers = { "Agustín García" };
            about.comments = "Manage groups of SSH and SFTP connections and keep them open in tabs.";
            about.license_type = Gtk.License.GPL_3_0;
            about.present (active_window);
        }
    }
}
