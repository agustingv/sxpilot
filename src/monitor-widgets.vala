namespace SxPilot {

    /* Server icon for the sidebar with a coloured dot showing the
     * monitoring state; no dot when the connection is not monitored. */
    public class ServerIcon : Adw.Bin {
        public string connection_id { get; construct; }

        private Gtk.Widget dot;
        private ServerMonitor? monitor = null;
        private ulong state_handler = 0;
        private ulong update_handler = 0;
        private ulong alerts_handler = 0;
        private ulong manager_handler = 0;

        public ServerIcon (string connection_id) {
            Object (connection_id: connection_id);
        }

        construct {
            dot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            dot.add_css_class ("status-dot");
            dot.halign = Gtk.Align.END;
            dot.valign = Gtk.Align.END;
            dot.can_target = false;

            var overlay = new Gtk.Overlay ();
            overlay.halign = Gtk.Align.CENTER;
            overlay.valign = Gtk.Align.CENTER;
            overlay.child = new Gtk.Image.from_icon_name ("network-server-symbolic");
            overlay.add_overlay (dot);
            child = overlay;

            manager_handler = MonitorManager.get_default ().changed.connect (rebind);
            bind (MonitorManager.get_default ().lookup (connection_id));
        }

        private void bind (ServerMonitor? m) {
            monitor = m;
            if (monitor != null) {
                state_handler = monitor.notify["state"].connect (refresh);
                update_handler = monitor.updated.connect (refresh);
                alerts_handler = monitor.alerts.changed.connect (refresh);
            }
            refresh ();
        }

        private void unbind () {
            if (monitor != null) {
                monitor.disconnect (state_handler);
                monitor.disconnect (update_handler);
                monitor.alerts.disconnect (alerts_handler);
                monitor = null;
            }
        }

        private void rebind () {
            var m = MonitorManager.get_default ().lookup (connection_id);
            if (m == monitor) {
                return;
            }
            unbind ();
            bind (m);
        }

        private void refresh () {
            foreach (var c in new string[] { "online", "offline", "error", "alert" }) {
                dot.remove_css_class (c);
            }
            dot.visible = monitor != null && monitor.state != MonitorState.STOPPED;
            if (!dot.visible) {
                tooltip_text = null;
                return;
            }
            var tooltip = monitor.describe ();
            foreach (var a in monitor.alerts.list ()) {
                tooltip += "\n⚠ " + a.title;
            }
            tooltip_text = tooltip;
            if (monitor.alerts.count > 0 && monitor.state == MonitorState.ONLINE) {
                dot.add_css_class ("alert");
                return;
            }
            switch (monitor.state) {
                case MonitorState.ONLINE: dot.add_css_class ("online"); break;
                case MonitorState.OFFLINE: dot.add_css_class ("offline"); break;
                case MonitorState.ERROR: dot.add_css_class ("error"); break;
                default: break;
            }
        }

        public override void dispose () {
            unbind ();
            if (manager_handler != 0) {
                MonitorManager.get_default ().disconnect (manager_handler);
                manager_handler = 0;
            }
            base.dispose ();
        }
    }

    /* Area chart of a history, newest value on the right. Values are
     * percentages unless `auto_scale` is set, then the top of the chart
     * follows the largest value. */
    public class Sparkline : Gtk.Widget {
        public bool auto_scale { get; set; default = false; }
        private double[] values = {};

        static construct {
            set_css_name ("sparkline");
        }

        construct {
            height_request = 72;
            hexpand = true;
            add_css_class ("accent");
        }

        public void set_values (double[] v) {
            values = v;
            queue_draw ();
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            float w = get_width ();
            float h = get_height ();
            var color = get_color ();

            var grid = color;
            grid.alpha = 0.12f;
            for (int i = 1; i < 4; i++) {
                float y = (int) (h * i / 4);
                snapshot.append_color (grid, Graphene.Rect ().init (0, y, w, 1));
            }

            if (values.length < 2) {
                return;
            }
            double max = 100;
            if (auto_scale) {
                max = 0;
                foreach (var v in values) {
                    max = double.max (max, v);
                }
                max = max > 0 ? max * 1.15 : 1;
            }
            float step = w / (History.SIZE - 1);
            float x0 = w - step * (values.length - 1);

            var line = new Gsk.PathBuilder ();
            var area = new Gsk.PathBuilder ();
            area.move_to (x0, h);
            for (int i = 0; i < values.length; i++) {
                float x = x0 + step * i;
                float y = h - (float) (double.max (0, double.min (values[i], max)) / max) * (h - 2) - 1;
                if (i == 0) {
                    line.move_to (x, y);
                } else {
                    line.line_to (x, y);
                }
                area.line_to (x, y);
            }
            area.line_to (w, h);
            area.close ();

            var fill = color;
            fill.alpha = 0.18f;
            snapshot.append_fill (area.to_path (), Gsk.FillRule.WINDING, fill);
            var stroke = new Gsk.Stroke (2);
            stroke.set_line_join (Gsk.LineJoin.ROUND);
            snapshot.append_stroke (line.to_path (), stroke, color);
        }
    }

    public string format_kib (uint64 kib) {
        return format_size (kib * 1024, FormatSizeFlags.IEC_UNITS);
    }

    public string format_uptime (double seconds) {
        var s = (int64) seconds;
        var days = s / 86400;
        var hours = (s % 86400) / 3600;
        var minutes = (s % 3600) / 60;
        if (days > 0) {
            return "%lldd %lldh".printf (days, hours);
        }
        if (hours > 0) {
            return "%lldh %lldm".printf (hours, minutes);
        }
        return "%lldm".printf (minutes);
    }
}
