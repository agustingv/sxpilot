namespace SxPilot {

    /* Create or edit a connection. Emits `saved` once the store is updated. */
    public class ConnectionDialog : Adw.Dialog {
        public Connection? connection { get; construct; }

        public signal void saved (Connection connection);

        private Adw.EntryRow name_row;
        private Adw.ComboRow group_row;
        private Adw.EntryRow host_row;
        private Adw.SpinRow port_row;
        private Adw.EntryRow user_row;
        private Adw.ComboRow auth_row;
        private Adw.PasswordEntryRow password_row;
        private Adw.ActionRow key_row;
        private Adw.EntryRow jump_row;
        private Adw.EntryRow dir_row;
        private Adw.EntryRow extra_row;
        private Gtk.Button save_button;
        private Adw.ToastOverlay toasts;

        private string identity_file = "";
        private string[] group_ids = {};

        public ConnectionDialog (Connection? connection, string? preset_group = null) {
            Object (connection: connection);
            if (connection == null && preset_group != null) {
                select_group (preset_group);
            }
        }

        construct {
            title = connection == null ? "New Connection" : "Edit Connection";
            content_width = 480;
            content_height = 680;

            var header = new Adw.HeaderBar ();
            header.show_start_title_buttons = false;
            header.show_end_title_buttons = false;

            var cancel = new Gtk.Button.with_mnemonic ("_Cancel");
            cancel.clicked.connect (() => close ());
            header.pack_start (cancel);

            save_button = new Gtk.Button.with_mnemonic (connection == null ? "_Add" : "_Save");
            save_button.add_css_class ("suggested-action");
            save_button.clicked.connect (on_save);
            header.pack_end (save_button);
            default_widget = save_button;

            var page = new Adw.PreferencesPage ();

            /* Server */
            var server = new Adw.PreferencesGroup ();
            server.title = "Server";

            name_row = new Adw.EntryRow ();
            name_row.title = "Name";
            server.add (name_row);

            host_row = new Adw.EntryRow ();
            host_row.title = "Host";
            host_row.input_purpose = Gtk.InputPurpose.URL;
            host_row.activates_default = true;
            server.add (host_row);

            port_row = new Adw.SpinRow.with_range (1, 65535, 1);
            port_row.title = "Port";
            port_row.value = 22;
            server.add (port_row);

            user_row = new Adw.EntryRow ();
            user_row.title = "Username";
            user_row.activates_default = true;
            server.add (user_row);

            var groups = new Gtk.StringList (null);
            groups.append ("No Group");
            group_ids += "";
            foreach (var g in Store.get_default ().sorted_groups ()) {
                groups.append (g.name);
                group_ids += g.id;
            }
            group_row = new Adw.ComboRow ();
            group_row.title = "Group";
            group_row.model = groups;
            server.add (group_row);

            page.add (server);

            /* Authentication */
            var auth = new Adw.PreferencesGroup ();
            auth.title = "Authentication";

            auth_row = new Adw.ComboRow ();
            auth_row.title = "Method";
            auth_row.model = new Gtk.StringList ({ "SSH Agent / Default Keys", "Password", "Key File" });
            auth.add (auth_row);

            password_row = new Adw.PasswordEntryRow ();
            password_row.title = "Password (stored in keyring, optional)";
            auth.add (password_row);

            key_row = new Adw.ActionRow ();
            key_row.title = "Key File";
            key_row.subtitle = "None selected";
            var choose = new Gtk.Button.from_icon_name ("document-open-symbolic");
            choose.valign = Gtk.Align.CENTER;
            choose.tooltip_text = "Choose Key File";
            choose.add_css_class ("flat");
            choose.clicked.connect (choose_key_file);
            key_row.add_suffix (choose);
            key_row.activatable_widget = choose;
            auth.add (key_row);

            page.add (auth);

            /* Advanced */
            var adv = new Adw.PreferencesGroup ();
            adv.title = "Advanced";

            jump_row = new Adw.EntryRow ();
            jump_row.title = "Jump Host (user@host:port)";
            adv.add (jump_row);

            dir_row = new Adw.EntryRow ();
            dir_row.title = "SFTP Initial Directory";
            adv.add (dir_row);

            extra_row = new Adw.EntryRow ();
            extra_row.title = "Extra SSH Options (e.g. -o ServerAliveInterval=30)";
            adv.add (extra_row);

            page.add (adv);

            toasts = new Adw.ToastOverlay ();
            toasts.child = page;

            var view = new Adw.ToolbarView ();
            view.add_top_bar (header);
            view.content = toasts;
            child = view;

            auth_row.notify["selected"].connect (update_auth_visibility);
            host_row.changed.connect (validate);
            user_row.changed.connect (validate);
            jump_row.changed.connect (validate);
            extra_row.changed.connect (validate);

            if (connection != null) {
                load (connection);
            }
            update_auth_visibility ();
            validate ();
        }

        private void load (Connection c) {
            name_row.text = c.name;
            host_row.text = c.host;
            port_row.value = c.port;
            user_row.text = c.username;
            select_group (c.group_id);
            auth_row.selected = (uint) c.auth_method;
            set_identity_file (c.identity_file);
            jump_row.text = c.jump_host;
            dir_row.text = c.remote_directory;
            extra_row.text = c.extra_options;

            if (c.auth_method == AuthMethod.PASSWORD) {
                Secrets.lookup_password.begin (c.id, (obj, res) => {
                    try {
                        var pw = Secrets.lookup_password.end (res);
                        if (pw != null && password_row.text == "") {
                            password_row.text = pw;
                        }
                    } catch (Error e) {
                        warning ("Keyring lookup failed: %s", e.message);
                    }
                });
            }
        }

        private void select_group (string id) {
            for (int i = 0; i < group_ids.length; i++) {
                if (group_ids[i] == id) {
                    group_row.selected = i;
                    return;
                }
            }
        }

        private void set_identity_file (string path) {
            identity_file = path;
            key_row.subtitle = path != "" ? path : "None selected";
        }

        private void update_auth_visibility () {
            var method = (AuthMethod) auth_row.selected;
            password_row.visible = method == AuthMethod.PASSWORD;
            key_row.visible = method == AuthMethod.KEY_FILE;
        }

        private static void mark (Gtk.Widget w, bool ok) {
            if (ok) {
                w.remove_css_class ("error");
            } else {
                w.add_css_class ("error");
            }
        }

        private void validate () {
            var host = host_row.text.strip ();
            bool host_ok = host == "" || Connection.is_safe_token (host);
            bool user_ok = Connection.is_safe_token (user_row.text.strip ());
            bool jump_ok = Connection.is_safe_token (jump_row.text.strip ());
            bool extra_ok = true;
            if (extra_row.text.strip () != "") {
                try {
                    string[] tmp;
                    Shell.parse_argv (extra_row.text.strip (), out tmp);
                } catch (ShellError e) {
                    extra_ok = false;
                }
            }
            mark (host_row, host_ok);
            mark (user_row, user_ok);
            mark (jump_row, jump_ok);
            mark (extra_row, extra_ok);
            save_button.sensitive = host != "" && host_ok && user_ok && jump_ok && extra_ok;
        }

        private void choose_key_file () {
            var dialog = new Gtk.FileDialog ();
            dialog.title = "Choose Private Key";
            dialog.modal = true;
            var ssh_dir = File.new_for_path (Path.build_filename (Environment.get_home_dir (), ".ssh"));
            if (ssh_dir.query_exists ()) {
                dialog.initial_folder = ssh_dir;
            }
            dialog.open.begin (get_root () as Gtk.Window, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null && file.get_path () != null) {
                        set_identity_file (file.get_path ());
                    }
                } catch (Error e) {
                    /* Dismissed. */
                }
            });
        }

        private void on_save () {
            var store = Store.get_default ();
            var c = connection ?? new Connection ();

            c.name = name_row.text.strip ();
            c.host = host_row.text.strip ();
            c.port = (int) port_row.value;
            c.username = user_row.text.strip ();
            c.group_id = group_ids[group_row.selected];
            c.auth_method = (AuthMethod) auth_row.selected;
            c.identity_file = c.auth_method == AuthMethod.KEY_FILE ? identity_file : "";
            c.jump_host = jump_row.text.strip ();
            c.remote_directory = dir_row.text.strip ();
            c.extra_options = extra_row.text.strip ();

            if (c.auth_method == AuthMethod.KEY_FILE && c.identity_file == "") {
                toasts.add_toast (new Adw.Toast ("Choose a key file or use another method"));
                return;
            }

            if (connection == null) {
                store.add_connection (c);
            } else {
                store.save ();
            }

            var password = password_row.text;
            save_button.sensitive = false;
            update_password.begin (c, c.auth_method == AuthMethod.PASSWORD ? password : "", (obj, res) => {
                update_password.end (res);
                saved (c);
                close ();
            });
        }

        private async void update_password (Connection c, string password) {
            try {
                if (password != "") {
                    yield Secrets.store_password (c.id, c.summary, password);
                } else {
                    yield Secrets.clear_password (c.id);
                }
            } catch (Error e) {
                warning ("Could not update keyring: %s", e.message);
            }
        }
    }
}
