namespace SxPilot {

    /* A tab running one ssh/sftp process inside a VTE terminal. */
    public class TerminalTab : Gtk.Box {
        public Connection connection { get; construct; }
        public Protocol protocol { get; construct; }
        public string title { get; private set; }
        public bool running { get; private set; default = false; }

        public Vte.Terminal terminal { get; private set; }

        private Adw.Banner banner;
        private GLib.Pid child_pid = 0;
        private Settings settings;

        public signal void attention_requested ();

        private static Gdk.RGBA[]? palette = null;

        public TerminalTab (Connection connection, Protocol protocol) {
            Object (connection: connection,
                    protocol: protocol,
                    orientation: Gtk.Orientation.VERTICAL,
                    spacing: 0);
        }

        construct {
            title = protocol == Protocol.SFTP
                ? "%s (SFTP)".printf (connection.display_name)
                : connection.display_name;

            banner = new Adw.Banner ("");
            banner.button_label = "_Reconnect";
            banner.button_clicked.connect (() => start ());
            append (banner);

            terminal = new Vte.Terminal ();
            terminal.hexpand = true;
            terminal.vexpand = true;
            terminal.scroll_on_keystroke = true;
            terminal.scroll_on_output = false;
            terminal.audible_bell = false;
            terminal.enable_fallback_scrolling = true;
            terminal.child_exited.connect (on_child_exited);
            terminal.bell.connect (() => attention_requested ());

            var scroller = new Gtk.ScrolledWindow ();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.child = terminal;
            append (scroller);

            settings = new Settings (Config.APP_ID);
            settings.changed.connect (apply_settings);
            apply_settings ();

            var style = Adw.StyleManager.get_default ();
            style.notify["dark"].connect (apply_colors);
            apply_colors ();

            setup_actions ();
        }

        private void apply_settings () {
            terminal.font_desc = Pango.FontDescription.from_string (settings.get_string ("terminal-font"));
            terminal.scrollback_lines = settings.get_int ("terminal-scrollback");
        }

        private void apply_colors () {
            if (palette == null) {
                string[] hex = {
                    "#241f31", "#c01c28", "#2ec27e", "#f5c211", "#1e78e4", "#9841bb", "#0ab9dc", "#c0bfbc",
                    "#5e5c64", "#ed333b", "#57e389", "#f8e45c", "#51a1ff", "#c061cb", "#4fd2fd", "#f6f5f4",
                };
                palette = new Gdk.RGBA[hex.length];
                for (int i = 0; i < hex.length; i++) {
                    palette[i].parse (hex[i]);
                }
            }
            var fg = Gdk.RGBA ();
            var bg = Gdk.RGBA ();
            if (Adw.StyleManager.get_default ().dark) {
                fg.parse ("#ffffff");
                bg.parse ("#1e1e1e");
            } else {
                fg.parse ("#1e1e1e");
                bg.parse ("#ffffff");
            }
            terminal.set_colors (fg, bg, palette);
        }

        private void setup_actions () {
            var group = new SimpleActionGroup ();

            var copy = new SimpleAction ("copy", null);
            copy.activate.connect (() => terminal.copy_clipboard_format (Vte.Format.TEXT));
            group.add_action (copy);

            var paste = new SimpleAction ("paste", null);
            paste.activate.connect (() => terminal.paste_clipboard ());
            group.add_action (paste);

            var select_all = new SimpleAction ("select-all", null);
            select_all.activate.connect (() => terminal.select_all ());
            group.add_action (select_all);

            var zoom_in = new SimpleAction ("zoom-in", null);
            zoom_in.activate.connect (() => terminal.font_scale = double.min (terminal.font_scale + 0.1, 3.0));
            group.add_action (zoom_in);

            var zoom_out = new SimpleAction ("zoom-out", null);
            zoom_out.activate.connect (() => terminal.font_scale = double.max (terminal.font_scale - 0.1, 0.5));
            group.add_action (zoom_out);

            var zoom_reset = new SimpleAction ("zoom-reset", null);
            zoom_reset.activate.connect (() => terminal.font_scale = 1.0);
            group.add_action (zoom_reset);

            var reconnect = new SimpleAction ("reconnect", null);
            reconnect.activate.connect (() => start ());
            bind_property ("running", reconnect, "enabled", BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
            group.add_action (reconnect);

            insert_action_group ("term", group);

            var menu = new Menu ();
            var edit = new Menu ();
            edit.append ("_Copy", "term.copy");
            edit.append ("_Paste", "term.paste");
            edit.append ("Select _All", "term.select-all");
            menu.append_section (null, edit);
            var zoom = new Menu ();
            zoom.append ("Zoom _In", "term.zoom-in");
            zoom.append ("Zoom _Out", "term.zoom-out");
            zoom.append ("_Normal Size", "term.zoom-reset");
            menu.append_section (null, zoom);
            var conn = new Menu ();
            conn.append ("_Reconnect", "term.reconnect");
            menu.append_section (null, conn);
            terminal.context_menu_model = menu;

            /* Capture phase so these win over the terminal's own key handling. */
            var shortcuts = new Gtk.ShortcutController ();
            shortcuts.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            bind_shortcut (shortcuts, "<Control><Shift>c", "term.copy");
            bind_shortcut (shortcuts, "<Control><Shift>v", "term.paste");
            bind_shortcut (shortcuts, "<Control><Shift>a", "term.select-all");
            bind_shortcut (shortcuts, "<Control>plus|<Control>equal|<Control>KP_Add", "term.zoom-in");
            bind_shortcut (shortcuts, "<Control>minus|<Control>KP_Subtract", "term.zoom-out");
            bind_shortcut (shortcuts, "<Control>0|<Control>KP_0", "term.zoom-reset");
            terminal.add_controller (shortcuts);
        }

        private static void bind_shortcut (Gtk.ShortcutController controller, string trigger, string action) {
            controller.add_shortcut (new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string (trigger),
                                                       new Gtk.NamedAction (action)));
        }

        private static string? find_askpass () {
            var env = Environment.get_variable ("SXPILOT_ASKPASS");
            if (env != null && FileUtils.test (env, FileTest.IS_EXECUTABLE)) {
                return env;
            }
            if (FileUtils.test (Config.ASKPASS_PATH, FileTest.IS_EXECUTABLE)) {
                return Config.ASKPASS_PATH;
            }
            /* Running from the build directory: the helper sits next to us. */
            try {
                var self = FileUtils.read_link ("/proc/self/exe");
                var candidate = Path.build_filename (Path.get_dirname (self), "sxpilot-askpass");
                if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                    return candidate;
                }
            } catch (FileError e) {
            }
            return null;
        }

        public void start () {
            if (running) {
                return;
            }
            running = true;
            banner.revealed = false;
            start_async.begin ();
        }

        private async void start_async () {
            string[] env = Environ.get ();
            bool password_saved = false;

            if (connection.auth_method == AuthMethod.PASSWORD) {
                string? password = null;
                try {
                    password = yield Secrets.lookup_password (connection.id);
                } catch (Error e) {
                    warning ("Keyring lookup failed: %s", e.message);
                }
                var askpass = find_askpass ();
                if (password != null && askpass != null) {
                    /* ssh asks the helper, which reads the password from the
                     * keyring itself: it never appears in argv or env. */
                    password_saved = true;
                    env = Environ.set_variable (env, "SSH_ASKPASS", askpass, true);
                    env = Environ.set_variable (env, "SSH_ASKPASS_REQUIRE", "force", true);
                    env = Environ.set_variable (env, "SXPILOT_CONNECTION_ID", connection.id, true);
                    env = Environ.set_variable (env, "SXPILOT_CONNECTION_NAME", connection.display_name, true);
                } else if (password != null) {
                    warning ("sxpilot-askpass not found; the password will be asked in the terminal");
                }
            }

            string[] argv;
            try {
                argv = connection.build_argv (protocol, password_saved);
            } catch (ShellError e) {
                show_error ("Invalid extra options: %s".printf (e.message));
                return;
            }

            terminal.feed ("\x1b[2m%s\x1b[0m\r\n".printf (string.joinv (" ", argv)).data);

            terminal.spawn_async (Vte.PtyFlags.DEFAULT,
                                  Environment.get_home_dir (),
                                  argv,
                                  env,
                                  SpawnFlags.SEARCH_PATH,
                                  null,
                                  -1,
                                  null,
                                  (term, pid, error) => {
                if (error != null) {
                    show_error ("Could not start %s: %s".printf (argv[0], error.message));
                    return;
                }
                child_pid = pid;
                terminal.grab_focus ();
            });
        }

        private void show_error (string message) {
            running = false;
            child_pid = 0;
            banner.title = message;
            banner.revealed = true;
        }

        private void on_child_exited (int status) {
            running = false;
            child_pid = 0;
            string message;
            if (Process.if_exited (status)) {
                var code = Process.exit_status (status);
                message = code == 0 ? "Connection closed" : "Connection closed (exit code %d)".printf (code);
            } else {
                message = "Connection terminated";
            }
            terminal.feed ("\r\n\x1b[2m[%s]\x1b[0m\r\n".printf (message).data);
            banner.title = message;
            banner.revealed = true;
            attention_requested ();
        }

        /* Kill the child (if any); used when the tab is closed. */
        public void terminate () {
            if (child_pid > 0) {
                Posix.kill (child_pid, Posix.Signal.HUP);
                child_pid = 0;
            }
            running = false;
        }

        public override bool grab_focus () {
            return terminal.grab_focus ();
        }
    }
}
