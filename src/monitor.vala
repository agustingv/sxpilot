namespace SxPilot {

    public enum MonitorState {
        STOPPED,
        CONNECTING,
        ONLINE,
        OFFLINE,
        ERROR;

        public string to_label () {
            switch (this) {
                case CONNECTING: return "Connecting";
                case ONLINE: return "Online";
                case OFFLINE: return "Offline";
                case ERROR: return "Error";
                default: return "Not monitored";
            }
        }
    }

    public class DiskUsage {
        public string device;
        public string mount;
        public uint64 size_kb;
        public uint64 used_kb;

        public double percent {
            get { return size_kb > 0 ? 100.0 * used_kb / size_kb : 0; }
        }
    }

    /* Fixed-size history of percentages, oldest first. */
    public class History {
        public const int SIZE = 120;
        private double[] _values = {};

        public double[] values {
            get { return _values; }
        }

        public void push (double v) {
            if (_values.length >= SIZE) {
                _values = _values[_values.length - SIZE + 1:_values.length];
            }
            _values += v;
        }

        public void clear () {
            _values = {};
        }
    }

    /* Latest values of one monitoring extension on one server. */
    public class ExtensionResult {
        public Extension extension;
        /* The command after parameter substitution; null if that failed. */
        public string? command;
        public bool has_data = false;
        public bool failed = false;
        public string message = "";
        /* Formatted value per metric key. */
        public HashTable<string, string> values = new HashTable<string, string> (str_hash, str_equal);
        public HashTable<string, History> histories = new HashTable<string, History> (str_hash, str_equal);
        /* Numeric value per metric key (after rate conversion), for alerts. */
        public HashTable<string, double?> numbers = new HashTable<string, double?> (str_hash, str_equal);

        private StringBuilder output = new StringBuilder ();
        private HashTable<string, double?> prev_counters = new HashTable<string, double?> (str_hash, str_equal);
        private double prev_time = -1;

        public ExtensionResult (Extension extension, string? command, string error = "") {
            this.extension = extension;
            this.command = command;
            if (command == null) {
                failed = true;
                message = error;
            }
            foreach (var m in extension.metrics) {
                if (m.chart) {
                    histories.insert (m.key, new History ());
                }
            }
        }

        public void append_output (string line) {
            /* Bounded by the remote script too; this is a safety net. */
            if (output.len < 256 * 1024) {
                output.append (line).append_c ('\n');
            }
        }

        /* `rc` is the command's exit status; `now` a monotonic clock in
         * seconds (the server's uptime) used to compute rates. */
        public void finish (int rc, double now) {
            var text = output.str;
            output.truncate (0);

            if (rc != 0) {
                failed = true;
                var lines = text.strip ().split ("\n");
                var last = lines.length > 0 ? lines[lines.length - 1].strip () : "";
                if (rc == 124) {
                    message = "The command timed out";
                } else if (last != "") {
                    message = last;
                } else {
                    message = "The command failed (exit code %d)".printf (rc);
                }
                return;
            }

            HashTable<string, string> raw;
            try {
                raw = extension.parse (text);
            } catch (Error e) {
                failed = true;
                message = "Could not read the output: %s".printf (e.message);
                return;
            }

            numbers.remove_all ();
            int found = 0;
            double elapsed = prev_time >= 0 && now > prev_time ? now - prev_time : -1;
            foreach (var m in extension.metrics) {
                var r = raw.lookup (m.key);
                if (r == null) {
                    values.insert (m.key, "—");
                    continue;
                }
                found++;
                if (m.format == MetricFormat.TEXT) {
                    values.insert (m.key, r);
                    continue;
                }
                double v;
                if (!double.try_parse (r, out v)) {
                    values.insert (m.key, r);
                    continue;
                }
                double? shown = v;
                if (m.rate) {
                    var prev = prev_counters.lookup (m.key);
                    prev_counters.insert (m.key, v);
                    /* No rate on the first sample or when a counter resets. */
                    if (prev != null && elapsed > 0 && v >= prev) {
                        shown = (v - prev) / elapsed;
                    } else {
                        shown = null;
                    }
                }
                values.insert (m.key, shown != null ? m.format_value (shown) : "—");
                if (shown != null) {
                    numbers.insert (m.key, shown);
                }
                var history = histories.lookup (m.key);
                if (history != null && shown != null) {
                    history.push (shown);
                }
            }
            prev_time = now;

            if (found == 0) {
                failed = true;
                message = "None of the expected values were found in the output";
                return;
            }
            failed = false;
            message = "";
            has_data = true;
        }
    }

    /* Collects metrics from one server through a single long-lived ssh
     * process. Nothing is installed remotely: a small sh loop reads /proc
     * and prints one keyword-prefixed line per value every `interval`
     * seconds, closing each sample with "end". */
    public class ServerMonitor : Object {
        public Connection connection { get; construct; }
        public MonitorState state { get; private set; default = MonitorState.STOPPED; }
        /* Why the monitor is offline or failing; empty otherwise. */
        public string message { get; private set; default = ""; }

        /* Static information, read once per session. */
        public string os { get; private set; default = ""; }
        public string hostname { get; private set; default = ""; }
        public int cores { get; private set; default = 0; }

        /* Latest sample; negative when unknown. */
        public double cpu_percent = -1;
        public double load1 = -1;
        public double load5 = -1;
        public double load15 = -1;
        public uint64 mem_total_kb = 0;
        public uint64 mem_available_kb = 0;
        public uint64 swap_total_kb = 0;
        public uint64 swap_free_kb = 0;
        public double uptime_seconds = -1;
        public GenericArray<DiskUsage> disks = new GenericArray<DiskUsage> ();
        public DateTime? last_update = null;

        public GenericArray<ExtensionResult> extensions = new GenericArray<ExtensionResult> ();
        /* Extensions whose service was found on the server and that are
         * neither enabled nor dismissed for this connection. */
        public GenericArray<Extension> detected = new GenericArray<Extension> ();
        public AlertTracker alerts { get; private set; }

        public History cpu_history = new History ();
        public History mem_history = new History ();

        /* Number of views (monitor tabs) that need this monitor running. */
        public int users = 0;
        /* Settings the running session was started with; see MonitorManager. */
        public string signature = "";

        public signal void updated ();

        private Subprocess? process = null;
        private Cancellable? cancellable = null;
        private uint retry_source = 0;
        private int failures = 0;
        private bool stopped = true;

        /* Previous /proc/stat counters, to turn them into a percentage. */
        private uint64 prev_cpu_total = 0;
        private uint64 prev_cpu_idle = 0;
        private GenericArray<DiskUsage> pending_disks = new GenericArray<DiskUsage> ();

        public ServerMonitor (Connection connection) {
            Object (connection: connection);
        }

        construct {
            alerts = new AlertTracker (this);
        }

        /* Extensions worth detecting: not enabled and not dismissed. */
        private static GenericArray<Extension> detectable_extensions (Connection c) {
            var list = new GenericArray<Extension> ();
            foreach (var ext in ExtensionRegistry.get_default ().extensions) {
                var cfg = c.extensions.lookup (ext.id);
                if (ext.detect != "" && (cfg == null || (!cfg.enabled && !cfg.dismissed))) {
                    list.add (ext);
                }
            }
            return list;
        }

        /* Forgets a suggestion once it was enabled or dismissed. */
        public void forget_detected (string id) {
            for (uint i = 0; i < detected.length; i++) {
                if (detected[i].id == id) {
                    detected.remove_index (i);
                    updated ();
                    return;
                }
            }
        }

        public double mem_percent {
            get {
                return mem_total_kb > 0 ? 100.0 * (mem_total_kb - mem_available_kb) / mem_total_kb : -1;
            }
        }

        public bool has_data {
            get { return last_update != null; }
        }

        public bool running {
            get { return !stopped; }
        }

        /* Enabled extensions known to the registry, by id. */
        private static GenericArray<Extension> enabled_extensions (Connection c) {
            var list = new GenericArray<Extension> ();
            var registry = ExtensionRegistry.get_default ();
            foreach (var id in c.extensions.get_keys ()) {
                var ext = registry.lookup (id);
                if (ext != null && c.extensions.lookup (id).enabled) {
                    list.add (ext);
                }
            }
            list.sort ((a, b) => strcmp (a.id, b.id));
            return list;
        }

        /* Changes whenever the enabled extensions, their parameters or
         * their files change. */
        public static string extensions_signature (Connection c) {
            var sb = new StringBuilder ();
            foreach (var ext in enabled_extensions (c)) {
                sb.append_printf ("%s:%s", ext.id, ext.digest);
                var cfg = c.extensions.lookup (ext.id);
                foreach (var p in ext.params) {
                    sb.append_printf (":%s", cfg.params.lookup (p.key) ?? "");
                }
                sb.append_c ('\x1e');
            }
            return sb.str;
        }

        private void setup_extensions () {
            var list = new GenericArray<ExtensionResult> ();
            foreach (var ext in enabled_extensions (connection)) {
                try {
                    list.add (new ExtensionResult (ext, ext.build_command (connection.extensions.lookup (ext.id).params)));
                } catch (Error e) {
                    list.add (new ExtensionResult (ext, null, e.message));
                }
            }
            extensions = list;
        }

        private ExtensionResult? find_extension (string id) {
            foreach (var r in extensions) {
                if (r.extension.id == id) {
                    return r;
                }
            }
            return null;
        }

        /* Each extension runs under `timeout` when the server has it; its
         * output is prefixed with "x <id> " so it never mixes with ours. */
        private string build_script (int interval) {
            var probes = new StringBuilder ();
            foreach (var r in extensions) {
                if (r.command == null) {
                    continue;
                }
                probes.append_printf ("  o=$($T sh -c %s 2>&1 </dev/null); r=$?\n", Shell.quote (r.command));
                probes.append_printf ("  printf '%%s\\n' \"$o\" | head -n 2000 | sed 's/^/x %s /'\n", r.extension.id);
                probes.append_printf ("  echo \"xrc %s $r\"\n", r.extension.id);
            }
            var detect = new StringBuilder ();
            foreach (var ext in detectable_extensions (connection)) {
                detect.append_printf ("$T sh -c %s >/dev/null 2>&1 </dev/null && echo \"detected %s\"\n",
                                      Shell.quote (ext.detect), ext.id);
            }
            return script (interval)
                .replace ("while :; do\n", detect.str + "while :; do\n")
                .replace ("  echo end\n", probes.str + "  echo end\n");
        }

        private static string script (int interval) {
            return """
[ "$(uname -s)" = Linux ] || { echo "unsupported $(uname -s)"; exit 3; }
echo "os $(uname -sr)"
echo "host $(cat /proc/sys/kernel/hostname)"
echo "cores $(grep -c ^processor /proc/cpuinfo)"
T=
command -v timeout >/dev/null 2>&1 && T="timeout 10"
while :; do
  head -n1 /proc/stat
  echo "load $(cat /proc/loadavg)"
  grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
  echo "uptime $(cat /proc/uptime)"
  df -kP 2>/dev/null | awk 'NR > 1 && $1 ~ /^\// { print "disk", $1, $2, $3, $6 }'
  echo end
  sleep %d
done
""".printf (interval);
        }

        public void start () {
            if (!stopped) {
                return;
            }
            stopped = false;
            failures = 0;
            connect_session.begin ();
        }

        public void stop () {
            stopped = true;
            cancel_retry ();
            kill_process ();
            state = MonitorState.STOPPED;
            message = "";
        }

        /* Reconnect now, e.g. after the settings changed. */
        public void restart () {
            stop ();
            start ();
        }

        private void cancel_retry () {
            if (retry_source != 0) {
                Source.remove (retry_source);
                retry_source = 0;
            }
        }

        private void kill_process () {
            if (cancellable != null) {
                cancellable.cancel ();
                cancellable = null;
            }
            if (process != null) {
                process.send_signal (Posix.Signal.TERM);
                process = null;
            }
        }

        private void reset_session_data () {
            prev_cpu_total = 0;
            prev_cpu_idle = 0;
            pending_disks = new GenericArray<DiskUsage> ();
            setup_extensions ();
            detected = new GenericArray<Extension> ();
        }

        private async void connect_session () {
            cancel_retry ();
            state = MonitorState.CONNECTING;
            reset_session_data ();

            var session = new Cancellable ();
            cancellable = session;

            if (connection.auth_method == AuthMethod.PASSWORD) {
                bool saved = false;
                try {
                    saved = (yield Secrets.lookup_password (connection.id)) != null;
                } catch (Error e) {
                }
                if (session.is_cancelled ()) {
                    return;
                }
                if (!saved) {
                    fail (MonitorState.ERROR, "Save the password in the connection to monitor this server", false);
                    return;
                }
            }

            bool password_saved;
            var env = yield SshEnv.prepare (connection, true, out password_saved);
            if (session.is_cancelled ()) {
                return;
            }

            string[] argv;
            try {
                argv = connection.build_batch_argv (password_saved, "sh -s");
            } catch (ShellError e) {
                fail (MonitorState.ERROR, "Invalid extra options: %s".printf (e.message), false);
                return;
            }

            Subprocess proc;
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE
                                                       | SubprocessFlags.STDOUT_PIPE
                                                       | SubprocessFlags.STDERR_PIPE);
                launcher.set_environ (env);
                launcher.set_cwd (Environment.get_home_dir ());
                proc = launcher.spawnv (argv);
            } catch (Error e) {
                fail (MonitorState.ERROR, "Could not start ssh: %s".printf (e.message), false);
                return;
            }
            process = proc;

            var settings = new Settings (Config.APP_ID);
            try {
                var stdin = proc.get_stdin_pipe ();
                yield stdin.write_all_async (build_script (settings.get_int ("monitor-interval")).data,
                                             Priority.DEFAULT, session, null);
                yield stdin.close_async (Priority.DEFAULT, session);
            } catch (Error e) {
                /* ssh exited early; its stderr explains why. */
            }

            /* stderr is drained in parallel so ssh never blocks on it, and
             * fully read before its messages are used to explain an exit. */
            var errors = new StringBuilder ();
            bool errors_done = false;
            bool waiting_errors = false;
            SourceFunc resume = connect_session.callback;
            read_errors.begin (proc, errors, session, (obj, res) => {
                read_errors.end (res);
                errors_done = true;
                if (waiting_errors) {
                    resume ();
                }
            });

            var stdout = new DataInputStream (proc.get_stdout_pipe ());
            try {
                string? line;
                while ((line = yield stdout.read_line_async (Priority.DEFAULT, session)) != null) {
                    handle_line (line);
                }
            } catch (Error e) {
            }

            try {
                yield proc.wait_async (session);
            } catch (Error e) {
            }
            if (!errors_done) {
                waiting_errors = true;
                yield;
            }
            if (session.is_cancelled () || process != proc) {
                return;
            }
            process = null;
            on_session_ended (proc, errors.str.strip ());
        }

        private async void read_errors (Subprocess proc, StringBuilder errors, Cancellable cancellable) {
            var stream = new DataInputStream (proc.get_stderr_pipe ());
            try {
                string? line;
                while ((line = yield stream.read_line_async (Priority.DEFAULT, cancellable)) != null) {
                    if (line.strip () != "") {
                        /* Keep only the last few lines. */
                        if (errors.len > 2048) {
                            errors.erase (0, errors.len - 1024);
                        }
                        errors.append (line.strip ()).append_c ('\n');
                    }
                }
            } catch (Error e) {
            }
        }

        private void on_session_ended (Subprocess proc, string errors) {
            var lines = errors.split ("\n");
            var last = lines.length > 0 ? lines[lines.length - 1] : "";

            if (proc.get_if_exited () && proc.get_exit_status () == 3 && os.has_prefix ("unsupported")) {
                fail (MonitorState.ERROR, "Only Linux servers can be monitored (this one runs %s)"
                      .printf (os.substring ("unsupported ".length)), false);
                return;
            }

            if (!proc.get_if_exited () || proc.get_exit_status () != 255) {
                fail (MonitorState.OFFLINE, last != "" ? last : "The monitoring session ended", true);
                return;
            }

            /* No automatic retry for these: repeated failed logins can get
             * our address banned (fail2ban), and they won't fix themselves. */
            var e = errors.down ();
            if (e.contains ("permission denied") || e.contains ("too many authentication failures")) {
                fail (MonitorState.ERROR, "Authentication failed. Monitoring needs the SSH agent, "
                      + "a key without passphrase or a saved password", false);
            } else if (e.contains ("host key verification failed")) {
                fail (MonitorState.ERROR, "Unknown or changed host key. Open an SSH session once to verify it", false);
            } else {
                fail (MonitorState.OFFLINE, last != "" ? last : "Connection failed", true);
            }
        }

        private void fail (MonitorState new_state, string text, bool retry) {
            message = text;
            state = new_state;
            updated ();
            if (!retry || stopped) {
                return;
            }
            /* 10 s, 20 s, 40 s… up to 5 minutes. */
            failures++;
            var delay = (uint) int.min (10 << int.min (failures - 1, 5), 300);
            retry_source = Timeout.add_seconds (delay, () => {
                retry_source = 0;
                if (!stopped) {
                    connect_session.begin ();
                }
                return Source.REMOVE;
            });
        }

        private void handle_line (string line) {
            /* "x <id> <output line>" */
            if (line.has_prefix ("x ")) {
                var rest = line.substring (2);
                var space = rest.index_of_char (' ');
                var id = space >= 0 ? rest.substring (0, space) : rest;
                var r = find_extension (id);
                if (r != null) {
                    r.append_output (space >= 0 ? rest.substring (space + 1) : "");
                }
                return;
            }
            var parts = Regex.split_simple ("\\s+", line.strip ());
            if (parts.length == 0) {
                return;
            }
            switch (parts[0]) {
                case "unsupported":
                    os = line.strip ();
                    break;
                case "os":
                    os = line.strip ().substring (3);
                    break;
                case "host":
                    hostname = parts.length > 1 ? parts[1] : "";
                    break;
                case "cores":
                    cores = parts.length > 1 ? int.parse (parts[1]) : 0;
                    break;
                case "cpu":
                    parse_cpu (parts);
                    break;
                case "load":
                    if (parts.length >= 4) {
                        load1 = double.parse (parts[1]);
                        load5 = double.parse (parts[2]);
                        load15 = double.parse (parts[3]);
                    }
                    break;
                case "MemTotal:":
                    mem_total_kb = uint64.parse (parts[1]);
                    break;
                case "MemAvailable:":
                    mem_available_kb = uint64.parse (parts[1]);
                    break;
                case "SwapTotal:":
                    swap_total_kb = uint64.parse (parts[1]);
                    break;
                case "SwapFree:":
                    swap_free_kb = uint64.parse (parts[1]);
                    break;
                case "uptime":
                    uptime_seconds = parts.length > 1 ? double.parse (parts[1]) : -1;
                    break;
                case "disk":
                    parse_disk (parts);
                    break;
                case "detected":
                    var ext = parts.length > 1 ? ExtensionRegistry.get_default ().lookup (parts[1]) : null;
                    if (ext != null) {
                        detected.add (ext);
                    }
                    break;
                case "xrc":
                    var r = parts.length > 2 ? find_extension (parts[1]) : null;
                    if (r != null) {
                        r.finish (int.parse (parts[2]), uptime_seconds);
                    }
                    break;
                case "end":
                    finish_sample ();
                    break;
            }
        }

        private void parse_cpu (string[] parts) {
            /* cpu user nice system idle iowait irq softirq steal … */
            if (parts.length < 9) {
                return;
            }
            uint64 total = 0;
            for (int i = 1; i <= 8; i++) {
                total += uint64.parse (parts[i]);
            }
            uint64 idle = uint64.parse (parts[4]) + uint64.parse (parts[5]);
            if (prev_cpu_total > 0 && total > prev_cpu_total) {
                var dt = total - prev_cpu_total;
                var di = idle >= prev_cpu_idle ? idle - prev_cpu_idle : 0;
                cpu_percent = (100.0 * (dt - uint64.min (di, dt))) / dt;
            }
            prev_cpu_total = total;
            prev_cpu_idle = idle;
        }

        private void parse_disk (string[] parts) {
            /* disk <device> <size KiB> <used KiB> <mount> */
            if (parts.length < 5) {
                return;
            }
            /* The same device mounted twice (bind mounts, btrfs subvolumes)
             * counts once. */
            foreach (var d in pending_disks) {
                if (d.device == parts[1]) {
                    return;
                }
            }
            var d = new DiskUsage ();
            d.device = parts[1];
            d.size_kb = uint64.parse (parts[2]);
            d.used_kb = uint64.parse (parts[3]);
            d.mount = string.joinv (" ", parts[4:parts.length]);
            pending_disks.add (d);
        }

        private void finish_sample () {
            disks = pending_disks;
            pending_disks = new GenericArray<DiskUsage> ();
            last_update = new DateTime.now_local ();
            failures = 0;
            message = "";
            /* The first sample has no previous CPU counters to compare with. */
            if (cpu_percent >= 0) {
                cpu_history.push (cpu_percent);
            }
            if (mem_percent >= 0) {
                mem_history.push (mem_percent);
            }
            if (state != MonitorState.ONLINE) {
                state = MonitorState.ONLINE;
            }
            updated ();
        }

        /* One-line summary for tooltips. */
        public string describe () {
            var name = connection.display_name;
            switch (state) {
                case MonitorState.ONLINE:
                    string[] parts = {};
                    if (cpu_percent >= 0) {
                        parts += "CPU %.0f%%".printf (cpu_percent);
                    }
                    if (mem_percent >= 0) {
                        parts += "RAM %.0f%%".printf (mem_percent);
                    }
                    if (load1 >= 0) {
                        parts += "Load %.2f".printf (load1);
                    }
                    return parts.length > 0 ? "%s — %s".printf (name, string.joinv (" · ", parts)) : "%s — Online".printf (name);
                case MonitorState.OFFLINE:
                case MonitorState.ERROR:
                    return "%s — %s: %s".printf (name, state.to_label (), message);
                default:
                    return "%s — %s".printf (name, state.to_label ());
            }
        }
    }

    /* Owns one ServerMonitor per connection that is monitored, either
     * because the connection has monitoring enabled or because a monitor
     * tab is open for it. */
    public class MonitorManager : Object {
        private static MonitorManager? _instance = null;

        private HashTable<string, ServerMonitor> monitors = new HashTable<string, ServerMonitor> (str_hash, str_equal);
        private Settings settings;
        private uint alert_timer = 0;

        /* A monitor was added or removed. */
        public signal void changed ();

        public static MonitorManager get_default () {
            if (_instance == null) {
                _instance = new MonitorManager ();
            }
            return _instance;
        }

        construct {
            settings = new Settings (Config.APP_ID);
            settings.changed["monitor-interval"].connect (() => sync ());
            settings.changed.connect ((key) => {
                if (key.has_prefix ("alert")) {
                    evaluate_alerts ();
                }
            });
            /* Conditions also expire while no sample arrives (offline). */
            alert_timer = Timeout.add_seconds (10, () => {
                evaluate_alerts ();
                return Source.CONTINUE;
            });
            Store.get_default ().changed.connect (() => sync ());
            sync ();
        }

        public ServerMonitor? lookup (string connection_id) {
            return monitors.lookup (connection_id);
        }

        /* Keeps the monitor running until release() is called. */
        public ServerMonitor acquire (Connection c) {
            var m = monitors.lookup (c.id);
            if (m == null) {
                m = add (c);
            }
            m.users++;
            return m;
        }

        public void release (ServerMonitor m) {
            m.users = int.max (m.users - 1, 0);
            sync ();
        }

        private ServerMonitor add (Connection c) {
            var m = new ServerMonitor (c);
            m.signature = signature_of (c);
            /* Methods, not closures: a closure capturing `m` would keep it
             * alive forever. */
            m.updated.connect (on_monitor_updated);
            m.alerts.raised.connect (on_alert_raised);
            m.alerts.cleared.connect (on_alert_cleared);
            monitors.insert (c.id, m);
            m.start ();
            changed ();
            return m;
        }

        /* Anything that changes how the session is started. */
        private string signature_of (Connection c) {
            return string.join ("\x1f", c.host, c.port.to_string (), c.username,
                                c.auth_method.to_string (), c.identity_file, c.jump_host,
                                c.extra_options, settings.get_int ("monitor-interval").to_string (),
                                ServerMonitor.extensions_signature (c));
        }

        /* Host, port and user part of a signature. */
        private static string server_of (string signature) {
            var parts = signature.split ("\x1f");
            return parts.length >= 3 ? string.joinv ("\x1f", parts[0:3]) : signature;
        }

        public void sync () {
            var store = Store.get_default ();
            bool any_change = false;

            foreach (var c in store.connections) {
                if (c.monitor_enabled && monitors.lookup (c.id) == null) {
                    add (c);
                }
            }

            string[] ids = {};
            foreach (var id in monitors.get_keys ()) {
                ids += id;
            }
            foreach (var id in ids) {
                var m = monitors.lookup (id);
                bool stored = store.find_connection (id) != null;
                bool wanted = m.users > 0 || (stored && m.connection.monitor_enabled);
                if (!wanted) {
                    m.stop ();
                    m.alerts.reset ();
                    monitors.remove (id);
                    any_change = true;
                    continue;
                }
                var sig = signature_of (m.connection);
                if (sig != m.signature) {
                    /* Keep the charts unless it is now another server. */
                    if (server_of (sig) != server_of (m.signature)) {
                        m.cpu_history.clear ();
                        m.mem_history.clear ();
                    }
                    m.signature = sig;
                    m.restart ();
                }
            }

            if (any_change) {
                changed ();
            }
        }

        private void on_monitor_updated (ServerMonitor m) {
            m.alerts.evaluate (settings);
        }

        private void on_alert_raised (AlertTracker tracker, Alert a) {
            notify_alert (tracker.monitor, a, true);
        }

        private void on_alert_cleared (AlertTracker tracker, Alert a, bool resolved) {
            if (resolved) {
                notify_alert (tracker.monitor, a, false);
            } else {
                withdraw_alert (tracker.monitor, a);
            }
        }

        private void evaluate_alerts () {
            foreach (var m in monitors.get_values ()) {
                m.alerts.evaluate (settings);
            }
        }

        private static string notification_id (ServerMonitor m, Alert a) {
            return "alert-%s-%s".printf (m.connection.id, a.id);
        }

        private void notify_alert (ServerMonitor m, Alert a, bool raised) {
            var app = GLib.Application.get_default ();
            if (app == null) {
                return;
            }
            var n = new Notification (raised
                ? "%s: %s".printf (m.connection.display_name, a.title)
                : "%s: back to normal".printf (m.connection.display_name));
            n.set_body (raised ? a.detail : "Resolved: %s".printf (a.title));
            n.set_priority (raised ? NotificationPriority.HIGH : NotificationPriority.NORMAL);
            n.set_default_action_and_target_value ("app.show-monitor", new Variant.string (m.connection.id));
            /* Same id: the resolution replaces the alert in the shell. */
            app.send_notification (notification_id (m, a), n);
        }

        private void withdraw_alert (ServerMonitor m, Alert a) {
            var app = GLib.Application.get_default ();
            if (app != null) {
                app.withdraw_notification (notification_id (m, a));
            }
        }

        public void stop_all () {
            foreach (var m in monitors.get_values ()) {
                m.stop ();
            }
        }
    }
}
