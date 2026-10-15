namespace SxPilot {

    public class Window : Adw.ApplicationWindow {
        private Adw.OverlaySplitView split_view;
        private Sidebar sidebar;
        private Adw.TabView tab_view;
        private Gtk.Stack content_stack;
        private Adw.WindowTitle window_title;
        private Adw.ToastOverlay toasts;
        private Adw.TabPage? menu_page = null;
        private Settings settings;
        private bool force_close = false;

        public Window (Gtk.Application app) {
            Object (application: app);
        }

        construct {
            title = "SxPilot";
            icon_name = Config.APP_ID;
            width_request = 360;
            height_request = 300;

            settings = new Settings (Config.APP_ID);
            default_width = settings.get_int ("window-width");
            default_height = settings.get_int ("window-height");
            if (settings.get_boolean ("window-maximized")) {
                maximize ();
            }

            setup_actions ();

            /* Sidebar */
            var add_menu = new Menu ();
            add_menu.append (_("New _Connection…"), "win.new-connection");
            add_menu.append (_("New _Group…"), "win.new-group");
            add_menu.append (_("_Quick Connect…"), "win.quick-connect");

            var add_button = new Gtk.MenuButton ();
            add_button.icon_name = "list-add-symbolic";
            add_button.tooltip_text = _("Add");
            add_button.menu_model = add_menu;

            var sidebar_header = new Adw.HeaderBar ();
            sidebar_header.title_widget = new Adw.WindowTitle ("SxPilot", "");
            sidebar_header.pack_start (add_button);

            sidebar = new Sidebar ();

            var sidebar_view = new Adw.ToolbarView ();
            sidebar_view.add_top_bar (sidebar_header);
            sidebar_view.content = sidebar;

            /* Content */
            tab_view = new Adw.TabView ();
            tab_view.vexpand = true;
            tab_view.close_page.connect (on_close_page);
            tab_view.notify["selected-page"].connect (on_selected_page_changed);
            tab_view.notify["n-pages"].connect (update_content_page);
            tab_view.setup_menu.connect ((page) => menu_page = page);
            tab_view.menu_model = build_tab_menu ();

            var tab_bar = new Adw.TabBar ();
            tab_bar.view = tab_view;
            tab_bar.autohide = false;

            var empty = new Adw.StatusPage ();
            empty.icon_name = "utilities-terminal-symbolic";
            empty.title = _("No Open Sessions");
            empty.description = _("Choose a connection in the sidebar to open an SSH session, or the folder button for SFTP");

            content_stack = new Gtk.Stack ();
            content_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            content_stack.add_named (empty, "empty");
            content_stack.add_named (tab_view, "tabs");

            toasts = new Adw.ToastOverlay ();
            toasts.child = content_stack;

            var sidebar_toggle = new Gtk.ToggleButton ();
            sidebar_toggle.icon_name = "sidebar-show-symbolic";
            sidebar_toggle.tooltip_text = _("Toggle Sidebar");

            var main_menu = new Menu ();
            var section = new Menu ();
            section.append (_("_Preferences"), "app.preferences");
            section.append (_("_About SxPilot"), "app.about");
            main_menu.append_section (null, section);

            var menu_button = new Gtk.MenuButton ();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.tooltip_text = _("Main Menu");
            menu_button.primary = true;
            menu_button.menu_model = main_menu;

            window_title = new Adw.WindowTitle ("SxPilot", "");

            var content_header = new Adw.HeaderBar ();
            content_header.title_widget = window_title;
            content_header.pack_start (sidebar_toggle);
            content_header.pack_end (menu_button);

            var content_view = new Adw.ToolbarView ();
            content_view.add_top_bar (content_header);
            content_view.add_top_bar (tab_bar);
            content_view.content = toasts;

            split_view = new Adw.OverlaySplitView ();
            split_view.sidebar = sidebar_view;
            split_view.content = content_view;
            split_view.min_sidebar_width = 260;
            split_view.max_sidebar_width = 360;
            split_view.bind_property ("show-sidebar", sidebar_toggle, "active",
                                      BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
            content = split_view;

            var breakpoint = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 640sp"));
            breakpoint.add_setter (split_view, "collapsed", true);
            add_breakpoint (breakpoint);

            close_request.connect (on_close_request);
            update_content_page ();
        }

        /* ---------- actions ---------- */

        private void add_string_action (string name, owned ActionFunc func) {
            var action = new SimpleAction (name, VariantType.STRING);
            action.activate.connect ((a, param) => func (param.get_string ()));
            add_action (action);
        }

        private delegate void ActionFunc (string id);

        private void add_plain_action (string name, owned SimpleFunc func) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => func ());
            add_action (action);
        }

        private delegate void SimpleFunc ();

        private void setup_actions () {
            add_plain_action ("new-connection", () => show_connection_dialog (null, null));
            add_plain_action ("new-group", () => show_group_dialog (null));
            add_plain_action ("quick-connect", show_quick_connect);
            add_plain_action ("toggle-sidebar", () => split_view.show_sidebar = !split_view.show_sidebar);
            add_plain_action ("search", () => {
                split_view.show_sidebar = true;
                sidebar.search_entry.grab_focus ();
            });
            add_plain_action ("close-tab", () => {
                if (tab_view.selected_page != null) {
                    tab_view.close_page (tab_view.selected_page);
                }
            });
            add_plain_action ("duplicate-tab", () => duplicate_tab (tab_view.selected_page));
            add_plain_action ("open-sftp-here", () => {
                var c = page_connection (tab_view.selected_page);
                if (c != null) {
                    open_session (c, Protocol.SFTP);
                }
            });

            add_string_action ("connect-ssh", (id) => open_by_id (id, Protocol.SSH));
            add_string_action ("connect-sftp", (id) => open_by_id (id, Protocol.SFTP));
            add_string_action ("show-monitor", (id) => {
                var c = Store.get_default ().find_connection (id);
                if (c != null) {
                    open_monitor (c);
                }
            });
            add_string_action ("edit-connection", (id) => {
                var c = Store.get_default ().find_connection (id);
                if (c != null) {
                    show_connection_dialog (c, null);
                }
            });
            add_string_action ("duplicate-connection", duplicate_connection);
            add_string_action ("delete-connection", delete_connection);
            add_string_action ("copy-command", copy_command);
            add_string_action ("new-connection-in-group", (id) => show_connection_dialog (null, id));
            add_string_action ("rename-group", (id) => {
                var g = Store.get_default ().find_group (id);
                if (g != null) {
                    show_group_dialog (g);
                }
            });
            add_string_action ("delete-group", delete_group);

            /* Tab context menu actions act on the page the menu was opened for. */
            var tab_actions = new SimpleActionGroup ();
            var dup = new SimpleAction ("duplicate", null);
            dup.activate.connect (() => duplicate_tab (menu_page));
            tab_actions.add_action (dup);
            var sftp = new SimpleAction ("sftp", null);
            sftp.activate.connect (() => {
                var c = page_connection (menu_page);
                if (c != null) {
                    open_session (c, Protocol.SFTP);
                }
            });
            tab_actions.add_action (sftp);
            var reconnect = new SimpleAction ("reconnect", null);
            reconnect.activate.connect (() => {
                if (menu_page == null) {
                    return;
                }
                if (menu_page.child is TerminalTab) {
                    ((TerminalTab) menu_page.child).start ();
                } else if (menu_page.child is MonitorTab) {
                    ((MonitorTab) menu_page.child).monitor.restart ();
                }
            });
            tab_actions.add_action (reconnect);
            var edit = new SimpleAction ("edit", null);
            edit.activate.connect (() => {
                var c = page_connection (menu_page);
                if (c != null && Store.get_default ().find_connection (c.id) != null) {
                    show_connection_dialog (c, null);
                }
            });
            tab_actions.add_action (edit);
            var close = new SimpleAction ("close", null);
            close.activate.connect (() => {
                if (menu_page != null) {
                    tab_view.close_page (menu_page);
                }
            });
            tab_actions.add_action (close);
            insert_action_group ("tab", tab_actions);
        }

        private MenuModel build_tab_menu () {
            var menu = new Menu ();
            var s1 = new Menu ();
            s1.append (_("_Duplicate Tab"), "tab.duplicate");
            s1.append (_("Open S_FTP Session"), "tab.sftp");
            s1.append (_("_Reconnect"), "tab.reconnect");
            s1.append (_("_Edit Connection…"), "tab.edit");
            menu.append_section (null, s1);
            var s2 = new Menu ();
            s2.append (_("_Close"), "tab.close");
            menu.append_section (null, s2);
            return menu;
        }

        /* ---------- sessions ---------- */

        private TerminalTab? selected_tab () {
            return tab_view.selected_page != null ? tab_view.selected_page.child as TerminalTab : null;
        }

        private static Connection? page_connection (Adw.TabPage? page) {
            if (page == null) {
                return null;
            }
            if (page.child is TerminalTab) {
                return ((TerminalTab) page.child).connection;
            }
            if (page.child is MonitorTab) {
                return ((MonitorTab) page.child).connection;
            }
            return null;
        }

        private void open_by_id (string id, Protocol protocol) {
            var c = Store.get_default ().find_connection (id);
            if (c != null) {
                open_session (c, protocol);
            }
        }

        public void open_session (Connection connection, Protocol protocol) {
            var tab = new TerminalTab (connection, protocol);
            var page = tab_view.append (tab);
            tab.bind_property ("title", page, "title", BindingFlags.SYNC_CREATE);
            page.tooltip = "%s — %s".printf (connection.summary, protocol.to_label ());
            page.icon = new ThemedIcon (protocol == Protocol.SFTP ? "folder-remote-symbolic" : "utilities-terminal-symbolic");
            page.live_thumbnail = false;

            tab.notify["running"].connect (() => update_page_state (page, tab));
            tab.attention_requested.connect (() => {
                if (tab_view.selected_page != page || !is_active) {
                    page.needs_attention = true;
                }
            });

            tab_view.selected_page = page;
            tab.start ();
            update_page_state (page, tab);

            if (split_view.collapsed) {
                split_view.show_sidebar = false;
            }
        }

        /* One monitor tab per connection: focus it if already open. */
        public void open_monitor (Connection connection) {
            for (int i = 0; i < tab_view.n_pages; i++) {
                var page = tab_view.get_nth_page (i);
                var existing = page.child as MonitorTab;
                if (existing != null && existing.connection == connection) {
                    tab_view.selected_page = page;
                    return;
                }
            }

            var tab = new MonitorTab (connection);
            var page = tab_view.append (tab);
            tab.bind_property ("title", page, "title", BindingFlags.SYNC_CREATE);
            page.tooltip = _("%s — Monitor").printf (connection.summary);
            page.icon = new ThemedIcon ("power-profile-performance-symbolic");
            page.live_thumbnail = false;
            /* Through the tab: the monitor may outlive it. */
            tab.status_changed.connect (() => update_monitor_page_state (page, tab));
            tab.alert_raised.connect (() => {
                if (tab_view.selected_page != page || !is_active) {
                    page.needs_attention = true;
                }
            });
            tab.notify["title"].connect (() => {
                if (page == tab_view.selected_page) {
                    update_title ();
                }
            });
            tab_view.selected_page = page;
            update_monitor_page_state (page, tab);

            if (split_view.collapsed) {
                split_view.show_sidebar = false;
            }
        }

        private void update_monitor_page_state (Adw.TabPage page, MonitorTab tab) {
            var state = tab.monitor.state;
            bool problem = state == MonitorState.OFFLINE || state == MonitorState.ERROR;
            var alerts = tab.monitor.alerts.count;
            if (problem) {
                page.indicator_icon = new ThemedIcon ("network-offline-symbolic");
                page.indicator_tooltip = tab.monitor.message;
            } else if (alerts > 0) {
                page.indicator_icon = new ThemedIcon ("dialog-warning-symbolic");
                page.indicator_tooltip = ngettext ("%u active alert", "%u active alerts", alerts).printf (alerts);
            } else {
                page.indicator_icon = null;
                page.indicator_tooltip = "";
            }
            page.loading = state == MonitorState.CONNECTING;
            if (page == tab_view.selected_page) {
                update_title ();
            }
        }

        private void update_page_state (Adw.TabPage page, TerminalTab tab) {
            page.indicator_icon = tab.running ? null : new ThemedIcon ("network-offline-symbolic");
            page.indicator_tooltip = tab.running ? "" : _("Disconnected");
            if (page == tab_view.selected_page) {
                update_title ();
            }
        }

        private void duplicate_tab (Adw.TabPage? page) {
            var tab = page != null ? page.child as TerminalTab : null;
            if (tab != null) {
                open_session (tab.connection, tab.protocol);
            }
        }

        private void on_selected_page_changed () {
            var page = tab_view.selected_page;
            if (page != null) {
                page.needs_attention = false;
                page.child.grab_focus ();
            }
            update_title ();
        }

        private void update_title () {
            var monitor_tab = tab_view.selected_page != null ? tab_view.selected_page.child as MonitorTab : null;
            if (monitor_tab != null) {
                window_title.title = monitor_tab.title;
                window_title.subtitle = "%s · %s".printf (monitor_tab.monitor.state.to_label (),
                                                          monitor_tab.connection.summary);
                title = "%s — SxPilot".printf (monitor_tab.title);
                return;
            }
            var tab = selected_tab ();
            if (tab == null) {
                window_title.title = "SxPilot";
                window_title.subtitle = "";
                title = "SxPilot";
                return;
            }
            window_title.title = tab.title;
            window_title.subtitle = tab.running
                ? "%s · %s".printf (tab.protocol.to_label (), tab.connection.summary)
                : _("Disconnected · %s").printf (tab.connection.summary);
            title = "%s — SxPilot".printf (tab.title);
        }

        private void update_content_page () {
            content_stack.visible_child_name = tab_view.n_pages > 0 ? "tabs" : "empty";
            if (tab_view.n_pages == 0) {
                update_title ();
            }
        }

        private bool on_close_page (Adw.TabPage page) {
            if (page.child is MonitorTab) {
                ((MonitorTab) page.child).release ();
                tab_view.close_page_finish (page, true);
                return Gdk.EVENT_STOP;
            }
            var tab = page.child as TerminalTab;
            if (tab == null || !tab.running) {
                if (tab != null) {
                    tab.terminate ();
                }
                tab_view.close_page_finish (page, true);
                return Gdk.EVENT_STOP;
            }

            var dialog = new Adw.AlertDialog (_("Close Session?"),
                _("The connection to “%s” is still active and will be terminated.").printf (tab.connection.summary));
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("close", _("C_lose"));
            dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "close";
            dialog.close_response = "cancel";
            dialog.choose.begin (this, null, (obj, res) => {
                bool confirmed = dialog.choose.end (res) == "close";
                if (confirmed) {
                    tab.terminate ();
                }
                tab_view.close_page_finish (page, confirmed);
            });
            return Gdk.EVENT_STOP;
        }

        private int running_sessions () {
            int n = 0;
            for (int i = 0; i < tab_view.n_pages; i++) {
                var tab = tab_view.get_nth_page (i).child as TerminalTab;
                if (tab != null && tab.running) {
                    n++;
                }
            }
            return n;
        }

        private bool on_close_request () {
            save_window_state ();
            var n = running_sessions ();
            if (force_close || n == 0) {
                terminate_all ();
                return false;
            }
            var dialog = new Adw.AlertDialog (_("Quit SxPilot?"),
                ngettext ("There is %d active session that will be terminated.",
                          "There are %d active sessions that will be terminated.", n).printf (n));
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("quit", _("_Quit"));
            dialog.set_response_appearance ("quit", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.close_response = "cancel";
            dialog.choose.begin (this, null, (obj, res) => {
                if (dialog.choose.end (res) == "quit") {
                    force_close = true;
                    close ();
                }
            });
            return true;
        }

        private void terminate_all () {
            for (int i = 0; i < tab_view.n_pages; i++) {
                var child = tab_view.get_nth_page (i).child;
                if (child is TerminalTab) {
                    ((TerminalTab) child).terminate ();
                } else if (child is MonitorTab) {
                    ((MonitorTab) child).release ();
                }
            }
        }

        private void save_window_state () {
            settings.set_boolean ("window-maximized", maximized);
            if (!maximized) {
                settings.set_int ("window-width", get_width ());
                settings.set_int ("window-height", get_height ());
            }
        }

        /* ---------- connection / group management ---------- */

        private void show_connection_dialog (Connection? connection, string? group_id) {
            var dialog = new ConnectionDialog (connection, group_id);
            dialog.saved.connect ((c) => {
                toasts.add_toast (new Adw.Toast (_("“%s” saved").printf (c.display_name)));
                /* Open tabs keep the same object; refresh their headers. */
                update_title ();
            });
            dialog.present (this);
        }

        private void duplicate_connection (string id) {
            var store = Store.get_default ();
            var c = store.find_connection (id);
            if (c == null) {
                return;
            }
            var copy = c.duplicate ();
            store.add_connection (copy);
            /* Copy the password first so the editor shows it. */
            copy_password.begin (c, copy, (obj, res) => {
                copy_password.end (res);
                show_connection_dialog (copy, null);
            });
        }

        private async void copy_password (Connection from, Connection to) {
            if (from.auth_method != AuthMethod.PASSWORD) {
                return;
            }
            try {
                var pw = yield Secrets.lookup_password (from.id);
                if (pw != null) {
                    yield Secrets.store_password (to.id, to.summary, pw);
                }
            } catch (Error e) {
                warning ("Could not copy password: %s", e.message);
            }
        }

        private void delete_connection (string id) {
            var store = Store.get_default ();
            var c = store.find_connection (id);
            if (c == null) {
                return;
            }
            var dialog = new Adw.AlertDialog (_("Delete Connection?"),
                _("“%s” and its saved password will be permanently deleted.").printf (c.display_name));
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("delete", _("_Delete"));
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.close_response = "cancel";
            dialog.choose.begin (this, null, (obj, res) => {
                if (dialog.choose.end (res) == "delete") {
                    store.remove_connection (c);
                }
            });
        }

        private void copy_command (string id) {
            var c = Store.get_default ().find_connection (id);
            if (c == null) {
                return;
            }
            try {
                string[] quoted = {};
                foreach (var a in c.build_argv (Protocol.SSH, false)) {
                    quoted += Shell.quote (a);
                }
                get_clipboard ().set_text (string.joinv (" ", quoted));
                toasts.add_toast (new Adw.Toast (_("Command copied")));
            } catch (ShellError e) {
                toasts.add_toast (new Adw.Toast (_("Invalid extra options")));
            }
        }

        private void show_group_dialog (Group? group) {
            var dialog = new Adw.AlertDialog (group == null ? _("New Group") : _("Rename Group"), null);
            var entry = new Gtk.Entry ();
            entry.placeholder_text = _("Group name");
            entry.activates_default = true;
            entry.text = group != null ? group.name : "";
            dialog.extra_child = entry;
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("ok", group == null ? _("_Create") : _("_Rename"));
            dialog.set_response_appearance ("ok", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "ok";
            dialog.close_response = "cancel";
            dialog.set_response_enabled ("ok", entry.text.strip () != "");
            entry.changed.connect (() => dialog.set_response_enabled ("ok", entry.text.strip () != ""));
            dialog.choose.begin (this, null, (obj, res) => {
                if (dialog.choose.end (res) != "ok") {
                    return;
                }
                var name = entry.text.strip ();
                if (group == null) {
                    Store.get_default ().add_group (new Group (name));
                } else {
                    group.name = name;
                    Store.get_default ().save ();
                }
            });
            entry.grab_focus ();
        }

        private void delete_group (string id) {
            var store = Store.get_default ();
            var g = store.find_group (id);
            if (g == null) {
                return;
            }
            var dialog = new Adw.AlertDialog (_("Delete Group?"),
                _("The group “%s” will be deleted. Its connections will be kept as ungrouped.").printf (g.name));
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("delete", _("_Delete"));
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.close_response = "cancel";
            dialog.choose.begin (this, null, (obj, res) => {
                if (dialog.choose.end (res) == "delete") {
                    store.remove_group (g);
                }
            });
        }

        /* Parses "[user@]host[:port]" into an unsaved connection. */
        private static Connection? parse_quick (string text) {
            var s = text.strip ();
            if (s == "") {
                return null;
            }
            var c = new Connection ();
            var at = s.last_index_of_char ('@');
            if (at >= 0) {
                c.username = s.substring (0, at);
                s = s.substring (at + 1);
            }
            var colon = s.last_index_of_char (':');
            if (colon > 0 && s.index_of_char (':') == colon) {
                int port;
                if (!int.try_parse (s.substring (colon + 1), out port)) {
                    return null;
                }
                c.port = port;
                s = s.substring (0, colon);
            }
            c.host = s;
            return c.is_valid () ? c : null;
        }

        private void show_quick_connect () {
            var dialog = new Adw.AlertDialog (_("Quick Connect"), _("Connect without saving. Use [user@]host[:port]."));
            var entry = new Gtk.Entry ();
            entry.placeholder_text = "user@example.com:22";
            entry.activates_default = true;
            dialog.extra_child = entry;
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("sftp", _("S_FTP"));
            dialog.add_response ("ssh", _("_SSH"));
            dialog.set_response_appearance ("ssh", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "ssh";
            dialog.close_response = "cancel";
            dialog.set_response_enabled ("ssh", false);
            dialog.set_response_enabled ("sftp", false);
            entry.changed.connect (() => {
                bool ok = parse_quick (entry.text) != null;
                dialog.set_response_enabled ("ssh", ok);
                dialog.set_response_enabled ("sftp", ok);
            });
            dialog.choose.begin (this, null, (obj, res) => {
                var response = dialog.choose.end (res);
                var c = parse_quick (entry.text);
                if (c == null || response == "cancel") {
                    return;
                }
                open_session (c, response == "sftp" ? Protocol.SFTP : Protocol.SSH);
            });
            entry.grab_focus ();
        }
    }
}
