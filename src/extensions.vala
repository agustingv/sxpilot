namespace SxPilot {

    public errordomain ExtensionError {
        INVALID,
        PARSE,
    }

    public enum MetricFormat {
        NUMBER,
        PERCENT,
        BYTES,
        KIB,
        DURATION,
        TEXT;

        public static MetricFormat from_string (string s) throws ExtensionError {
            switch (s) {
                case "number": return NUMBER;
                case "percent": return PERCENT;
                case "bytes": return BYTES;
                case "kib": return KIB;
                case "duration": return DURATION;
                case "text": return TEXT;
                default: throw new ExtensionError.INVALID ("unknown format “%s”", s);
            }
        }
    }

    public class ExtensionParam {
        public string key;
        public string label;
        public string default_value;
    }

    public class ExtensionMetric {
        public string key;
        public string label;
        public string unit = "";
        public MetricFormat format = MetricFormat.NUMBER;
        /* The value is a counter; show its change per second. */
        public bool rate = false;
        public bool chart = false;
        /* Alert when the value is above / below these; NAN when unset. */
        public double alert_above = double.NAN;
        public double alert_below = double.NAN;
        public string alert_message = "";

        public bool has_alert {
            get { return !alert_above.is_nan () || !alert_below.is_nan (); }
        }

        public string format_value (double v) {
            var suffix = rate ? "/s" : "";
            switch (format) {
                case MetricFormat.PERCENT:
                    return "%.1f %%".printf (v);
                case MetricFormat.BYTES:
                    return format_size ((uint64) double.max (v, 0), FormatSizeFlags.IEC_UNITS) + suffix;
                case MetricFormat.KIB:
                    return format_kib ((uint64) double.max (v, 0)) + suffix;
                case MetricFormat.DURATION:
                    return format_uptime (v);
                default:
                    var number = v != Math.floor (v) && v < 100 ? "%.2f".printf (v) : "%.0f".printf (v);
                    var unit_part = unit != "" ? " " + unit : "";
                    return number + unit_part + suffix;
            }
        }
    }

    /* A monitoring probe described by a JSON file: a shell command run on
     * the server on every sample, and how to read the values in its output.
     * See data/extensions/ for examples. */
    public class Extension : Object {
        public string id { get; private set; }
        public string name { get; private set; }
        public string description { get; private set; default = ""; }
        public string hint { get; private set; default = ""; }
        public string command { get; private set; }
        /* Optional command that exits with 0 when the service is present. */
        public string detect { get; private set; default = ""; }
        public string path { get; private set; }
        /* Checksum of the file, to notice when it changes. */
        public string digest { get; set; default = ""; }

        public GenericArray<ExtensionParam> params = new GenericArray<ExtensionParam> ();
        public GenericArray<ExtensionMetric> metrics = new GenericArray<ExtensionMetric> ();

        private string parser_type;
        private string separator = ":";
        private int key_column = 0;
        private int value_column = 1;
        private HashTable<string, Regex> patterns = new HashTable<string, Regex> (str_hash, str_equal);

        private static Regex? placeholder = null;

        /* Ids end up in the remote script and in config keys. */
        public static bool is_valid_id (string id) {
            return Regex.match_simple ("^[a-z0-9][a-z0-9_-]{0,63}$", id);
        }

        /* Bundled extensions' texts are in the translation catalog (see
         * po/extension-strings.py); others come back unchanged. */
        private static string tr (string s) {
            return s != "" ? _(s) : s;
        }

        private static string required_string (Json.Object o, string member) throws ExtensionError {
            var v = o.get_string_member_with_default (member, "").strip ();
            if (v == "") {
                throw new ExtensionError.INVALID ("missing “%s”", member);
            }
            return v;
        }

        public static Extension from_json (Json.Object o, string path) throws Error {
            var e = new Extension ();
            e.path = path;
            e.id = required_string (o, "id");
            if (!is_valid_id (e.id)) {
                throw new ExtensionError.INVALID ("invalid id “%s” (use a-z, 0-9, - and _)", e.id);
            }
            e.name = tr (required_string (o, "name"));
            e.description = tr (o.get_string_member_with_default ("description", ""));
            e.hint = tr (o.get_string_member_with_default ("hint", ""));
            e.command = required_string (o, "command");
            e.detect = o.get_string_member_with_default ("detect", "").strip ();

            if (o.has_member ("params")) {
                foreach (var node in o.get_array_member ("params").get_elements ()) {
                    var po = node.get_object ();
                    var p = new ExtensionParam ();
                    p.key = required_string (po, "key");
                    if (!Regex.match_simple ("^[a-z_][a-z0-9_]*$", p.key)) {
                        throw new ExtensionError.INVALID ("invalid param key “%s”", p.key);
                    }
                    p.label = tr (po.get_string_member_with_default ("label", p.key));
                    p.default_value = po.get_string_member_with_default ("default", "");
                    e.params.add (p);
                }
            }

            if (!o.has_member ("parser")) {
                throw new ExtensionError.INVALID ("missing “parser”");
            }
            var parser = o.get_object_member ("parser");
            e.parser_type = required_string (parser, "type");
            switch (e.parser_type) {
                case "keyvalue":
                    e.separator = parser.get_string_member_with_default ("separator", ":");
                    if (e.separator == "") {
                        throw new ExtensionError.INVALID ("empty separator");
                    }
                    break;
                case "table":
                    e.key_column = (int) parser.get_int_member_with_default ("key_column", 0);
                    e.value_column = (int) parser.get_int_member_with_default ("value_column", 1);
                    break;
                case "regex":
                    if (!parser.has_member ("patterns")) {
                        throw new ExtensionError.INVALID ("regex parser without “patterns”");
                    }
                    var patterns = parser.get_object_member ("patterns");
                    foreach (var key in patterns.get_members ()) {
                        e.patterns.insert (key, new Regex (patterns.get_string_member (key),
                                                           RegexCompileFlags.MULTILINE));
                    }
                    break;
                case "json":
                    break;
                default:
                    throw new ExtensionError.INVALID ("unknown parser “%s”", e.parser_type);
            }

            if (!o.has_member ("metrics")) {
                throw new ExtensionError.INVALID ("missing “metrics”");
            }
            foreach (var node in o.get_array_member ("metrics").get_elements ()) {
                var mo = node.get_object ();
                var m = new ExtensionMetric ();
                m.key = required_string (mo, "key");
                m.label = tr (mo.get_string_member_with_default ("label", m.key));
                m.unit = mo.get_string_member_with_default ("unit", "");
                m.format = MetricFormat.from_string (mo.get_string_member_with_default ("format", "number"));
                m.rate = mo.get_boolean_member_with_default ("rate", false);
                m.chart = mo.get_boolean_member_with_default ("chart", false) && m.format != MetricFormat.TEXT;
                if (mo.has_member ("alert")) {
                    var ao = mo.get_object_member ("alert");
                    if (ao == null || m.format == MetricFormat.TEXT) {
                        throw new ExtensionError.INVALID ("invalid alert for “%s”", m.key);
                    }
                    if (ao.has_member ("above")) {
                        m.alert_above = ao.get_double_member ("above");
                    }
                    if (ao.has_member ("below")) {
                        m.alert_below = ao.get_double_member ("below");
                    }
                    if (!m.has_alert) {
                        throw new ExtensionError.INVALID ("alert for “%s” needs “above” or “below”", m.key);
                    }
                    m.alert_message = tr (ao.get_string_member_with_default ("message", ""));
                }
                e.metrics.add (m);
            }
            if (e.metrics.length == 0) {
                throw new ExtensionError.INVALID ("no metrics");
            }
            /* Fails on placeholders that are not params. */
            e.build_command (null);
            return e;
        }

        public ExtensionParam? find_param (string key) {
            foreach (var p in params) {
                if (p.key == key) {
                    return p;
                }
            }
            return null;
        }

        /* The command with every ${key} replaced by the configured value (or
         * the default), shell-quoted so a value is always a single word. */
        public string build_command (HashTable<string, string>? values) throws Error {
            if (placeholder == null) {
                placeholder = new Regex ("\\$\\{([a-z_][a-z0-9_]*)\\}");
            }
            string? missing = null;
            var result = placeholder.replace_eval (command, -1, 0, 0, (info, builder) => {
                var key = info.fetch (1);
                var p = find_param (key);
                if (p == null) {
                    missing = key;
                    return true;
                }
                var v = values != null ? values.lookup (key) : null;
                if (v == null || v.strip () == "") {
                    v = p.default_value;
                }
                builder.append (Shell.quote (v));
                return false;
            });
            if (missing != null) {
                throw new ExtensionError.INVALID ("the command uses ${%s}, which is not a param", missing);
            }
            return result;
        }

        /* Raw values found in the command output, by key. */
        public HashTable<string, string> parse (string output) throws Error {
            var values = new HashTable<string, string> (str_hash, str_equal);
            switch (parser_type) {
                case "keyvalue":
                    foreach (var line in output.split ("\n")) {
                        var i = line.index_of (separator);
                        if (i > 0) {
                            values.insert (line.substring (0, i).strip (),
                                           line.substring (i + separator.length).strip ());
                        }
                    }
                    break;
                case "table":
                    foreach (var line in output.split ("\n")) {
                        var cols = Regex.split_simple ("\\s+", line.strip ());
                        if (line.strip () != "" && cols.length > int.max (key_column, value_column)) {
                            values.insert (cols[key_column], cols[value_column]);
                        }
                    }
                    break;
                case "regex":
                    foreach (var key in patterns.get_keys ()) {
                        MatchInfo info;
                        if (patterns.lookup (key).match (output, 0, out info)) {
                            var v = info.fetch (info.get_match_count () > 1 ? 1 : 0);
                            if (v != null) {
                                values.insert (key, v.strip ());
                            }
                        }
                    }
                    break;
                case "json":
                    var parser = new Json.Parser ();
                    parser.load_from_data (output);
                    flatten (parser.get_root (), "", values);
                    break;
            }
            return values;
        }

        /* {"a": {"b": 1}, "c": [2]} → a.b = 1, c.0 = 2 */
        private static void flatten (Json.Node? node, string prefix, HashTable<string, string> values) {
            if (node == null) {
                return;
            }
            switch (node.get_node_type ()) {
                case Json.NodeType.OBJECT:
                    var o = node.get_object ();
                    foreach (var key in o.get_members ()) {
                        flatten (o.get_member (key), prefix == "" ? key : prefix + "." + key, values);
                    }
                    break;
                case Json.NodeType.ARRAY:
                    var a = node.get_array ();
                    for (uint i = 0; i < a.get_length (); i++) {
                        flatten (a.get_element (i), "%s%s%u".printf (prefix, prefix == "" ? "" : ".", i), values);
                    }
                    break;
                case Json.NodeType.VALUE:
                    var t = node.get_value_type ();
                    if (t == typeof (string)) {
                        values.insert (prefix, node.get_string ());
                    } else if (t == typeof (bool)) {
                        values.insert (prefix, node.get_boolean () ? "1" : "0");
                    } else if (t == typeof (int64)) {
                        values.insert (prefix, node.get_int ().to_string ());
                    } else {
                        values.insert (prefix, "%.17g".printf (node.get_double ()));
                    }
                    break;
                default:
                    break;
            }
        }
    }

    /* Every extension available: the bundled ones and the user's. A file in
     * a later directory replaces one with the same id from an earlier one. */
    public class ExtensionRegistry : Object {
        private static ExtensionRegistry? _instance = null;

        public GenericArray<Extension> extensions { get; private set; default = new GenericArray<Extension> (); }

        public static ExtensionRegistry get_default () {
            if (_instance == null) {
                _instance = new ExtensionRegistry ();
                _instance.load ();
            }
            return _instance;
        }

        public static string user_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "sxpilot", "extensions");
        }

        /* Lowest priority first. */
        private static string[] search_dirs () {
            string[] dirs = {};
            var system = Environment.get_system_data_dirs ();
            for (int i = system.length - 1; i >= 0; i--) {
                dirs += Path.build_filename (system[i], "sxpilot", "extensions");
            }
            var dev = Environment.get_variable ("SXPILOT_EXTENSIONS_DIR");
            if (dev != null) {
                dirs += dev;
            }
            dirs += user_dir ();
            return dirs;
        }

        public void load () {
            var by_id = new HashTable<string, Extension> (str_hash, str_equal);
            foreach (var dir in search_dirs ()) {
                Dir d;
                try {
                    d = Dir.open (dir);
                } catch (FileError e) {
                    continue;
                }
                string[] names = {};
                string? name;
                while ((name = d.read_name ()) != null) {
                    if (name.has_suffix (".json")) {
                        names += name;
                    }
                }
                foreach (var n in names) {
                    var path = Path.build_filename (dir, n);
                    try {
                        string contents;
                        FileUtils.get_contents (path, out contents);
                        var parser = new Json.Parser ();
                        parser.load_from_data (contents);
                        var root = parser.get_root ();
                        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                            throw new ExtensionError.INVALID ("not a JSON object");
                        }
                        var ext = Extension.from_json (root.get_object (), path);
                        ext.digest = Checksum.compute_for_string (ChecksumType.SHA1, contents);
                        by_id.insert (ext.id, ext);
                    } catch (Error e) {
                        warning ("Ignoring extension %s: %s", path, e.message);
                    }
                }
            }

            var list = new GenericArray<Extension> ();
            foreach (var ext in by_id.get_values ()) {
                list.add (ext);
            }
            list.sort ((a, b) => a.name.collate (b.name));
            extensions = list;
        }

        public Extension? lookup (string id) {
            foreach (var e in extensions) {
                if (e.id == id) {
                    return e;
                }
            }
            return null;
        }
    }
}
