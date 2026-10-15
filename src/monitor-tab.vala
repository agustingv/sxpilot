namespace SxPilot {

    /* The group showing one extension's metrics. */
    private class ExtensionView {
        public Adw.PreferencesGroup group;
        public HashTable<string, Gtk.Label> labels = new HashTable<string, Gtk.Label> (str_hash, str_equal);
        public HashTable<string, Sparkline> charts = new HashTable<string, Sparkline> (str_hash, str_equal);
        private GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();

        public ExtensionView (ExtensionResult result) {
            var ext = result.extension;
            group = new Adw.PreferencesGroup ();
            group.title = Markup.escape_text (ext.name);
            foreach (var m in ext.metrics) {
                var row = new Adw.ActionRow ();
                row.title = Markup.escape_text (m.label);
                if (m.chart) {
                    var chart = new Sparkline ();
                    chart.auto_scale = m.format != MetricFormat.PERCENT;
                    chart.height_request = 28;
                    chart.width_request = 120;
                    chart.hexpand = false;
                    chart.valign = Gtk.Align.CENTER;
                    row.add_suffix (chart);
                    charts.insert (m.key, chart);
                }
                var label = new Gtk.Label ("—");
                label.xalign = 1;
                label.width_chars = 12;
                label.selectable = true;
                label.add_css_class ("numeric");
                row.add_suffix (label);
                labels.insert (m.key, label);
                group.add (row);
                rows.add (row);
            }
        }

        public void update (ExtensionResult result) {
            if (result.failed) {
                var text = result.message;
                if (result.extension.hint != "") {
                    text += "\n" + result.extension.hint;
                }
                group.description = Markup.escape_text (text);
            } else {
                group.description = null;
            }
            /* Until it has worked once, only the error is worth showing. */
            foreach (var row in rows) {
                row.visible = result.has_data;
            }
            foreach (var key in labels.get_keys ()) {
                labels.lookup (key).label = result.values.lookup (key) ?? "—";
            }
            foreach (var key in charts.get_keys ()) {
                var history = result.histories.lookup (key);
                if (history != null) {
                    charts.lookup (key).set_values (history.values);
                }
            }
        }
    }

    /* Tab with live CPU, memory, load and disk usage of one server. Keeps
     * the server's monitor running while it is open. */
    public class MonitorTab : Gtk.Box {
        public Connection connection { get; construct; }
        public ServerMonitor monitor { get; private set; }
        public string title { get; private set; }

        private Gtk.Stack stack;
        private Adw.StatusPage status_page;
        private Gtk.Button retry_button;
        private Adw.Banner banner;

        private Gtk.Label host_label;
        private Gtk.Label info_label;
        private Gtk.Label cpu_value;
        private Gtk.Label cpu_detail;
        private Sparkline cpu_chart;
        private Gtk.Label mem_value;
        private Gtk.Label mem_detail;
        private Sparkline mem_chart;
        private Adw.PreferencesGroup disk_group;
        private HashTable<string, Adw.ActionRow> disk_rows = new HashTable<string, Adw.ActionRow> (str_hash, str_equal);
        private Gtk.Box extensions_box;
        private Adw.PreferencesGroup alerts_group;
        private GenericArray<Gtk.Widget> alert_rows = new GenericArray<Gtk.Widget> ();
        private Adw.PreferencesGroup detected_group;
        private GenericArray<Gtk.Widget> detected_rows = new GenericArray<Gtk.Widget> ();
        /* What the rows currently show, to rebuild them only on change. */
        private string shown_alerts = "";
        private string shown_detected = "";
        private GenericArray<ExtensionResult>? shown_extensions = null;
        private GenericArray<ExtensionView> extension_views = new GenericArray<ExtensionView> ();

        private ulong state_handler = 0;
        private ulong update_handler = 0;
        private ulong alerts_handler = 0;
        private ulong raised_handler = 0;
        private bool released = false;

        /* The monitor's state, data or alerts changed. */
        public signal void status_changed ();
        public signal void alert_raised ();

        public MonitorTab (Connection connection) {
            Object (connection: connection,
                    orientation: Gtk.Orientation.VERTICAL,
                    spacing: 0);
        }

        construct {
            title = "%s (Monitor)".printf (connection.display_name);
            connection.notify["name"].connect (() => {
                title = "%s (Monitor)".printf (connection.display_name);
            });

            banner = new Adw.Banner ("");
            banner.button_label = "_Retry";
            banner.button_clicked.connect (() => monitor.restart ());
            append (banner);

            /* Shown until the first sample arrives. */
            status_page = new Adw.StatusPage ();
            status_page.icon_name = "power-profile-performance-symbolic";
            retry_button = new Gtk.Button.with_mnemonic ("_Retry");
            retry_button.halign = Gtk.Align.CENTER;
            retry_button.add_css_class ("pill");
            retry_button.clicked.connect (() => monitor.restart ());
            status_page.child = retry_button;

            stack = new Gtk.Stack ();
            stack.vexpand = true;
            stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            stack.add_named (status_page, "status");
            stack.add_named (build_dashboard (), "dashboard");
            append (stack);

            monitor = MonitorManager.get_default ().acquire (connection);
            state_handler = monitor.notify["state"].connect (refresh);
            update_handler = monitor.updated.connect (refresh);
            alerts_handler = monitor.alerts.changed.connect (refresh);
            raised_handler = monitor.alerts.raised.connect (() => alert_raised ());
            refresh ();
        }

        private Gtk.Widget build_card (string heading, out Gtk.Label value, out Gtk.Label detail, out Sparkline chart) {
            var title = new Gtk.Label (heading);
            title.xalign = 0;
            title.add_css_class ("heading");

            value = new Gtk.Label ("—");
            value.xalign = 0;
            value.add_css_class ("title-1");
            value.add_css_class ("numeric");

            detail = new Gtk.Label ("");
            detail.xalign = 0;
            detail.wrap = true;
            detail.add_css_class ("dim-label");
            detail.add_css_class ("numeric");

            chart = new Sparkline ();
            chart.margin_top = 6;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            box.margin_top = box.margin_bottom = box.margin_start = box.margin_end = 18;
            box.append (title);
            box.append (value);
            box.append (detail);
            box.append (chart);

            var card = new Adw.Bin ();
            card.add_css_class ("card");
            card.hexpand = true;
            card.child = box;
            return card;
        }

        private Gtk.Widget build_dashboard () {
            host_label = new Gtk.Label ("");
            host_label.xalign = 0;
            host_label.selectable = true;
            host_label.add_css_class ("title-2");

            info_label = new Gtk.Label ("");
            info_label.xalign = 0;
            info_label.wrap = true;
            info_label.add_css_class ("dim-label");

            var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            header.append (host_label);
            header.append (info_label);

            alerts_group = new Adw.PreferencesGroup ();
            alerts_group.title = "Active Alerts";
            alerts_group.visible = false;

            detected_group = new Adw.PreferencesGroup ();
            detected_group.title = "Services Detected";
            detected_group.description = "Enable an extension to monitor these services too";
            detected_group.visible = false;

            var cards = new Gtk.FlowBox ();
            cards.selection_mode = Gtk.SelectionMode.NONE;
            cards.homogeneous = true;
            cards.min_children_per_line = 1;
            cards.max_children_per_line = 2;
            cards.column_spacing = 12;
            cards.row_spacing = 12;
            cards.append (build_card ("CPU", out cpu_value, out cpu_detail, out cpu_chart));
            cards.append (build_card ("Memory", out mem_value, out mem_detail, out mem_chart));
            for (var child = cards.get_first_child (); child != null; child = child.get_next_sibling ()) {
                ((Gtk.FlowBoxChild) child).focusable = false;
            }

            disk_group = new Adw.PreferencesGroup ();
            disk_group.title = "Disks";

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 24);
            box.margin_top = box.margin_bottom = 24;
            box.margin_start = box.margin_end = 12;
            box.append (header);
            box.append (alerts_group);
            box.append (detected_group);
            box.append (cards);
            box.append (disk_group);

            extensions_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 24);
            box.append (extensions_box);

            var clamp = new Adw.Clamp ();
            clamp.maximum_size = 960;
            clamp.child = box;

            var scroller = new Gtk.ScrolledWindow ();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.child = clamp;
            return scroller;
        }

        private void refresh () {
            status_changed ();
            var state = monitor.state;
            bool problem = state == MonitorState.OFFLINE || state == MonitorState.ERROR;

            if (!monitor.has_data) {
                stack.visible_child_name = "status";
                banner.revealed = false;
                retry_button.visible = problem;
                switch (state) {
                    case MonitorState.OFFLINE:
                        status_page.icon_name = "network-offline-symbolic";
                        status_page.title = "Server Unreachable";
                        status_page.description = Markup.escape_text (monitor.message);
                        break;
                    case MonitorState.ERROR:
                        status_page.icon_name = "dialog-warning-symbolic";
                        status_page.title = "Cannot Monitor Server";
                        status_page.description = Markup.escape_text (monitor.message);
                        break;
                    default:
                        status_page.icon_name = "power-profile-performance-symbolic";
                        status_page.title = "Connecting…";
                        status_page.description = Markup.escape_text (connection.summary);
                        break;
                }
                return;
            }

            stack.visible_child_name = "dashboard";
            /* Keep showing the last data, marked as stale. */
            banner.revealed = problem;
            if (problem) {
                banner.title = "%s: %s".printf (state.to_label (), monitor.message);
            }
            update_dashboard ();
        }

        private void update_dashboard () {
            var m = monitor;
            host_label.label = m.hostname != "" ? m.hostname : connection.display_name;
            string[] info = {};
            if (m.os != "") {
                info += m.os;
            }
            if (m.cores > 0) {
                info += m.cores == 1 ? "1 core" : "%d cores".printf (m.cores);
            }
            if (m.uptime_seconds >= 0) {
                info += "up %s".printf (format_uptime (m.uptime_seconds));
            }
            if (m.last_update != null) {
                info += "updated %s".printf (m.last_update.format ("%X"));
            }
            info_label.label = string.joinv (" · ", info);

            cpu_value.label = m.cpu_percent >= 0 ? "%.0f %%".printf (m.cpu_percent) : "—";
            cpu_detail.label = m.load1 >= 0
                ? "Load average %.2f · %.2f · %.2f".printf (m.load1, m.load5, m.load15)
                : "";
            cpu_chart.set_values (m.cpu_history.values);

            if (m.mem_percent >= 0) {
                mem_value.label = "%.0f %%".printf (m.mem_percent);
                var detail = "%s of %s".printf (format_kib (m.mem_total_kb - m.mem_available_kb),
                                                format_kib (m.mem_total_kb));
                if (m.swap_total_kb > 0) {
                    detail += " · Swap %s of %s".printf (format_kib (m.swap_total_kb - m.swap_free_kb),
                                                          format_kib (m.swap_total_kb));
                }
                mem_detail.label = detail;
            } else {
                mem_value.label = "—";
                mem_detail.label = "";
            }
            mem_chart.set_values (m.mem_history.values);

            update_disks ();
            update_extensions ();
            update_alerts ();
            update_detected ();
        }

        private static void clear_rows (Adw.PreferencesGroup group, GenericArray<Gtk.Widget> rows) {
            foreach (var row in rows) {
                group.remove (row);
            }
            rows.remove_range (0, rows.length);
        }

        private void update_alerts () {
            var alerts = monitor.alerts.list ();
            var key = new StringBuilder ();
            foreach (var a in alerts) {
                key.append_printf ("%s\x1f%s\x1f%s\x1e", a.id, a.title, a.detail);
            }
            if (key.str == shown_alerts) {
                return;
            }
            shown_alerts = key.str;
            clear_rows (alerts_group, alert_rows);
            foreach (var a in alerts) {
                var row = new Adw.ActionRow ();
                row.title = Markup.escape_text (a.title);
                row.subtitle = Markup.escape_text (a.detail);
                row.add_css_class ("warning");
                row.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
                alerts_group.add (row);
                alert_rows.add (row);
            }
            alerts_group.visible = alert_rows.length > 0;
        }

        private void update_detected () {
            var key = new StringBuilder ();
            foreach (var ext in monitor.detected) {
                key.append (ext.id).append_c (' ');
            }
            if (key.str == shown_detected) {
                return;
            }
            shown_detected = key.str;
            clear_rows (detected_group, detected_rows);
            foreach (var ext in monitor.detected) {
                var row = new Adw.ActionRow ();
                row.title = Markup.escape_text (ext.name);
                row.subtitle = Markup.escape_text (ext.description);

                var dismiss = new Gtk.Button.from_icon_name ("window-close-symbolic");
                dismiss.valign = Gtk.Align.CENTER;
                dismiss.tooltip_text = "Don’t Suggest Again";
                dismiss.add_css_class ("flat");
                dismiss.clicked.connect (() => dismiss_extension (ext));

                var enable = new Gtk.Button.with_mnemonic ("_Enable…");
                enable.valign = Gtk.Align.CENTER;
                enable.add_css_class ("suggested-action");
                enable.clicked.connect (() => confirm_enable (ext));

                row.add_suffix (enable);
                row.add_suffix (dismiss);
                detected_group.add (row);
                detected_rows.add (row);
            }
            detected_group.visible = detected_rows.length > 0;
        }

        private void dismiss_extension (Extension ext) {
            connection.get_extension_config (ext.id).dismissed = true;
            Store.get_default ().save ();
            monitor.forget_detected (ext.id);
        }

        /* Show the exact command before it starts running on the server. */
        private void confirm_enable (Extension ext) {
            var body = "This command will run on “%s” on every sample:".printf (connection.display_name);
            var dialog = new Adw.AlertDialog ("Enable %s?".printf (ext.name), body);

            /* The command as it will run, with this connection's params. */
            string text;
            var current = connection.extensions.lookup (ext.id);
            try {
                text = ext.build_command (current != null ? current.params : null);
            } catch (Error e) {
                text = ext.command;
            }
            var command = new Gtk.Label (text);
            command.wrap = true;
            command.wrap_mode = Pango.WrapMode.CHAR;
            /* A hyphen added at a line break would change the command. */
            var attrs = new Pango.AttrList ();
            attrs.insert (Pango.attr_insert_hyphens_new (false));
            command.attributes = attrs;
            command.selectable = true;
            command.xalign = 0;
            command.add_css_class ("monospace");
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.append (command);
            if (ext.params.length > 0) {
                var note = new Gtk.Label ("Change the parameters in the connection settings.");
                note.wrap = true;
                note.xalign = 0;
                note.add_css_class ("dim-label");
                box.append (note);
            }
            if (ext.hint != "") {
                var hint = new Gtk.Label (ext.hint);
                hint.wrap = true;
                hint.xalign = 0;
                hint.add_css_class ("dim-label");
                box.append (hint);
            }
            dialog.extra_child = box;
            dialog.add_response ("cancel", "_Cancel");
            dialog.add_response ("enable", "_Enable");
            dialog.set_response_appearance ("enable", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "enable";
            dialog.close_response = "cancel";
            dialog.choose.begin (this, null, (obj, res) => {
                if (dialog.choose.end (res) != "enable") {
                    return;
                }
                var cfg = connection.get_extension_config (ext.id);
                cfg.enabled = true;
                cfg.dismissed = false;
                /* The monitor restarts with the extension. */
                Store.get_default ().save ();
            });
        }

        private void update_extensions () {
            /* A new session builds a new list. */
            if (shown_extensions != monitor.extensions) {
                shown_extensions = monitor.extensions;
                for (var child = extensions_box.get_first_child (); child != null; ) {
                    var next = child.get_next_sibling ();
                    extensions_box.remove (child);
                    child = next;
                }
                extension_views = new GenericArray<ExtensionView> ();
                foreach (var r in monitor.extensions) {
                    var view = new ExtensionView (r);
                    extensions_box.append (view.group);
                    extension_views.add (view);
                }
            }
            for (int i = 0; i < extension_views.length; i++) {
                extension_views[i].update (monitor.extensions[i]);
            }
            extensions_box.visible = extension_views.length > 0;
        }

        private void update_disks () {
            var seen = new GenericSet<string> (str_hash, str_equal);
            foreach (var d in monitor.disks) {
                seen.add (d.mount);
                var row = disk_rows.lookup (d.mount);
                if (row == null) {
                    row = new Adw.ActionRow ();
                    row.title = Markup.escape_text (d.mount);
                    row.add_prefix (new Gtk.Image.from_icon_name ("drive-harddisk-symbolic"));
                    var bar = new Gtk.LevelBar ();
                    bar.valign = Gtk.Align.CENTER;
                    bar.width_request = 160;
                    bar.min_value = 0;
                    bar.max_value = 100;
                    /* Default offsets are fractions of 1; ours are percentages. */
                    bar.remove_offset_value (Gtk.LEVEL_BAR_OFFSET_LOW);
                    bar.remove_offset_value (Gtk.LEVEL_BAR_OFFSET_HIGH);
                    bar.remove_offset_value (Gtk.LEVEL_BAR_OFFSET_FULL);
                    bar.add_offset_value (Gtk.LEVEL_BAR_OFFSET_LOW, 80);
                    bar.add_offset_value (Gtk.LEVEL_BAR_OFFSET_HIGH, 90);
                    bar.add_offset_value (Gtk.LEVEL_BAR_OFFSET_FULL, 100);
                    row.add_suffix (bar);
                    row.set_data<Gtk.LevelBar> ("bar", bar);
                    disk_rows.insert (d.mount, row);
                    disk_group.add (row);
                }
                row.subtitle = "%.0f %% · %s of %s · %s".printf (d.percent, format_kib (d.used_kb),
                                                                   format_kib (d.size_kb),
                                                                   Markup.escape_text (d.device));
                row.get_data<Gtk.LevelBar> ("bar").value = d.percent;
            }

            string[] gone = {};
            foreach (var mount in disk_rows.get_keys ()) {
                if (!seen.contains (mount)) {
                    gone += mount;
                }
            }
            foreach (var mount in gone) {
                disk_group.remove (disk_rows.lookup (mount));
                disk_rows.remove (mount);
            }
            disk_group.visible = disk_rows.size () > 0;
        }

        /* Called when the tab is closed. */
        public void release () {
            if (released) {
                return;
            }
            released = true;
            monitor.disconnect (state_handler);
            monitor.disconnect (update_handler);
            monitor.alerts.disconnect (alerts_handler);
            monitor.alerts.disconnect (raised_handler);
            MonitorManager.get_default ().release (monitor);
        }
    }
}
