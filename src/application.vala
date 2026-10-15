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

            /* Target of alert notifications. */
            var show_monitor = new SimpleAction ("show-monitor", VariantType.STRING);
            show_monitor.activate.connect ((a, param) => {
                var c = Store.get_default ().find_connection (param.get_string ());
                if (c == null) {
                    return;
                }
                var win = (active_window as Window) ?? new Window (this);
                win.open_monitor (c);
                win.present ();
            });
            add_action (show_monitor);

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

        protected override void startup () {
            base.startup ();

            var css = new Gtk.CssProvider ();
            css.load_from_string ("""
                .status-dot {
                    min-width: 8px;
                    min-height: 8px;
                    border-radius: 9999px;
                    margin: -2px;
                    background-color: @window_fg_color;
                    opacity: 0.4;
                    box-shadow: 0 0 0 2px @card_bg_color;
                }
                .status-dot.online { background-color: @success_color; opacity: 1; }
                .status-dot.offline { background-color: @error_color; opacity: 1; }
                .status-dot.error { background-color: @warning_color; opacity: 1; }
                .status-dot.alert { background-color: @warning_color; opacity: 1; }
            """);
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css,
                                                       Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            /* Start background monitors before any window lists them. */
            MonitorManager.get_default ();
        }

        protected override void shutdown () {
            MonitorManager.get_default ().stop_all ();
            base.shutdown ();
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
