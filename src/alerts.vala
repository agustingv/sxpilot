namespace SxPilot {

    public class Alert {
        /* Stable per rule: "cpu", "disk:/home", "ext:nginx:active"… */
        public string id;
        public string title;
        public string detail;
    }

    /* Raises an alert when a condition on a server's metrics lasts for the
     * configured time, and clears it when the condition stops. Rules come
     * from the global settings (CPU, memory, disk, offline) and from the
     * metrics of the server's extensions. */
    public class AlertTracker : Object {
        public unowned ServerMonitor monitor { get; construct; }

        public signal void raised (Alert alert);
        /* `resolved` is false when the alert was dropped because the
         * server or its alerts are no longer monitored. */
        public signal void cleared (Alert alert, bool resolved);
        /* The list of active alerts or their texts changed. */
        public signal void changed ();

        /* When each condition became true, in monotonic seconds. */
        private HashTable<string, double?> pending = new HashTable<string, double?> (str_hash, str_equal);
        private HashTable<string, Alert> active = new HashTable<string, Alert> (str_hash, str_equal);

        public AlertTracker (ServerMonitor monitor) {
            Object (monitor: monitor);
        }

        public uint count {
            get { return active.size (); }
        }

        public GenericArray<Alert> list () {
            var result = new GenericArray<Alert> ();
            foreach (var a in active.get_values ()) {
                result.add (a);
            }
            result.sort ((a, b) => strcmp (a.id, b.id));
            return result;
        }

        /* A condition evaluated now. */
        private class Condition {
            public string id;
            public bool on;
            public string title;
            public string detail;

            public Condition (string id, bool on, string title, string detail) {
                this.id = id;
                this.on = on;
                this.title = title;
                this.detail = detail;
            }
        }

        private static string describe_delay (int minutes) {
            if (minutes <= 0) {
                return "";
            }
            return minutes == 1 ? " for 1 minute" : " for %d minutes".printf (minutes);
        }

        private GenericArray<Condition> conditions (Settings settings) {
            var list = new GenericArray<Condition> ();
            var m = monitor;
            var delay = describe_delay (settings.get_int ("alert-minutes"));

            if (settings.get_boolean ("alert-offline")) {
                list.add (new Condition ("offline", m.state == MonitorState.OFFLINE,
                                         "Server unreachable",
                                         m.message != "" ? m.message : "No response%s".printf (delay)));
            }
            /* Metrics are only meaningful while samples arrive; otherwise
             * their rules keep their current state. */
            if (m.state != MonitorState.ONLINE) {
                return list;
            }

            var cpu = settings.get_int ("alert-cpu");
            if (cpu > 0 && m.cpu_percent >= 0) {
                list.add (new Condition ("cpu", m.cpu_percent >= cpu,
                                         "CPU at %.0f %%".printf (m.cpu_percent),
                                         "Above %d %%%s".printf (cpu, delay)));
            }
            var mem = settings.get_int ("alert-memory");
            if (mem > 0 && m.mem_percent >= 0) {
                list.add (new Condition ("memory", m.mem_percent >= mem,
                                         "Memory at %.0f %%".printf (m.mem_percent),
                                         "Above %d %%%s".printf (mem, delay)));
            }
            var disk = settings.get_int ("alert-disk");
            if (disk > 0) {
                foreach (var d in m.disks) {
                    list.add (new Condition ("disk:" + d.mount, d.percent >= disk,
                                             "Disk %s at %.0f %%".printf (d.mount, d.percent),
                                             "%s free of %s".printf (format_kib (d.size_kb - d.used_kb),
                                                                     format_kib (d.size_kb))));
                }
            }

            foreach (var r in m.extensions) {
                if (r.failed) {
                    continue;
                }
                foreach (var metric in r.extension.metrics) {
                    var v = r.numbers.lookup (metric.key);
                    if (!metric.has_alert || v == null) {
                        continue;
                    }
                    bool on = (!metric.alert_above.is_nan () && v > metric.alert_above)
                           || (!metric.alert_below.is_nan () && v < metric.alert_below);
                    var limit = !metric.alert_above.is_nan ()
                        ? "Above %s".printf (metric.format_value (metric.alert_above))
                        : "Below %s".printf (metric.format_value (metric.alert_below));
                    var title = metric.alert_message != ""
                        ? metric.alert_message
                        : "%s: %s".printf (r.extension.name, metric.label);
                    list.add (new Condition ("ext:%s:%s".printf (r.extension.id, metric.key), on,
                                             "%s (%s)".printf (title, metric.format_value (v)),
                                             limit + delay));
                }
            }
            return list;
        }

        public void evaluate (Settings settings) {
            if (!settings.get_boolean ("alerts-enabled") || !monitor.connection.alerts_enabled
                || monitor.state == MonitorState.STOPPED) {
                reset ();
                return;
            }

            var now = get_monotonic_time () / 1000000.0;
            var delay = settings.get_int ("alert-minutes") * 60.0;
            bool texts_changed = false;
            var seen = new GenericSet<string> (str_hash, str_equal);

            foreach (var c in conditions (settings)) {
                seen.add (c.id);
                var alert = active.lookup (c.id);
                if (!c.on) {
                    pending.remove (c.id);
                    if (alert != null) {
                        active.remove (c.id);
                        cleared (alert, true);
                        changed ();
                    }
                    continue;
                }
                if (alert != null) {
                    if (alert.title != c.title || alert.detail != c.detail) {
                        alert.title = c.title;
                        alert.detail = c.detail;
                        texts_changed = true;
                    }
                    continue;
                }
                var since = pending.lookup (c.id);
                if (since == null) {
                    pending.insert (c.id, now);
                    since = now;
                }
                if (now - since >= delay) {
                    pending.remove (c.id);
                    alert = new Alert ();
                    alert.id = c.id;
                    alert.title = c.title;
                    alert.detail = c.detail;
                    active.insert (c.id, alert);
                    raised (alert);
                    changed ();
                }
            }

            /* While online, rules that no longer exist (a disk unmounted, a
             * threshold set to 0, an extension disabled) are cleared. */
            if (monitor.state == MonitorState.ONLINE) {
                string[] gone = {};
                foreach (var id in active.get_keys ()) {
                    if (!seen.contains (id)) {
                        gone += id;
                    }
                }
                foreach (var id in gone) {
                    var alert = active.lookup (id);
                    active.remove (id);
                    cleared (alert, false);
                    changed ();
                }
                string[] stale = {};
                foreach (var id in pending.get_keys ()) {
                    if (!seen.contains (id)) {
                        stale += id;
                    }
                }
                foreach (var id in stale) {
                    pending.remove (id);
                }
            }

            if (texts_changed) {
                changed ();
            }
        }

        /* Drops every alert, e.g. when monitoring stops. */
        public void reset () {
            pending.remove_all ();
            if (active.size () == 0) {
                return;
            }
            var dropped = list ();
            active.remove_all ();
            foreach (var a in dropped) {
                cleared (a, false);
            }
            changed ();
        }
    }
}
