namespace SxPilot {

    public enum Protocol {
        SSH,
        SFTP;

        public string to_label () {
            return this == SSH ? "SSH" : "SFTP";
        }
    }

    public enum AuthMethod {
        AGENT,
        PASSWORD,
        KEY_FILE;

        public string to_string () {
            switch (this) {
                case PASSWORD: return "password";
                case KEY_FILE: return "key";
                default: return "agent";
            }
        }

        public static AuthMethod from_string (string? s) {
            switch (s) {
                case "password": return PASSWORD;
                case "key": return KEY_FILE;
                default: return AGENT;
            }
        }
    }

    public class Group : Object {
        public string id { get; set; }
        public string name { get; set; }
        public bool expanded { get; set; default = true; }

        public Group (string name) {
            Object (id: Uuid.string_random (), name: name);
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("expanded").add_boolean_value (expanded);
            b.end_object ();
            return b.get_root ();
        }

        public static Group from_json (Json.Object o) {
            var g = new Group (o.get_string_member_with_default ("name", "Group"));
            g.id = o.get_string_member_with_default ("id", g.id);
            g.expanded = o.get_boolean_member_with_default ("expanded", true);
            return g;
        }
    }

    public class Connection : Object {
        public string id { get; set; }
        public string name { get; set; default = ""; }
        public string group_id { get; set; default = ""; }
        public string host { get; set; default = ""; }
        public int port { get; set; default = 22; }
        public string username { get; set; default = ""; }
        public AuthMethod auth_method { get; set; default = AuthMethod.AGENT; }
        public string identity_file { get; set; default = ""; }
        public string jump_host { get; set; default = ""; }
        public string remote_directory { get; set; default = ""; }
        public string extra_options { get; set; default = ""; }

        public Connection () {
            Object (id: Uuid.string_random ());
        }

        public string display_name {
            owned get { return name != "" ? name : destination; }
        }

        public string destination {
            owned get { return username != "" ? @"$username@$host" : host; }
        }

        public string summary {
            owned get { return port != 22 ? @"$destination:$port" : destination; }
        }

        public Connection duplicate () {
            var c = new Connection ();
            c.name = name + " (copy)";
            c.group_id = group_id;
            c.host = host;
            c.port = port;
            c.username = username;
            c.auth_method = auth_method;
            c.identity_file = identity_file;
            c.jump_host = jump_host;
            c.remote_directory = remote_directory;
            c.extra_options = extra_options;
            return c;
        }

        public bool matches (string needle) {
            if (needle == "") {
                return true;
            }
            var n = needle.casefold ();
            return name.casefold ().contains (n)
                || host.casefold ().contains (n)
                || username.casefold ().contains (n);
        }

        /* Host names and users are passed to ssh as arguments; refuse anything
         * that could be interpreted as an option or split into several args. */
        public static bool is_safe_token (string s) {
            if (s.has_prefix ("-")) {
                return false;
            }
            for (int i = 0; i < s.length; i++) {
                if (s[i].isspace () || s[i] == '\0') {
                    return false;
                }
            }
            return true;
        }

        public bool is_valid () {
            return host != "" && is_safe_token (host)
                && is_safe_token (username)
                && is_safe_token (jump_host)
                && port > 0 && port < 65536;
        }

        /* Builds the command line for ssh(1) or sftp(1). `password_saved` tells
         * whether the askpass helper will answer the password prompt. */
        public string[] build_argv (Protocol protocol, bool password_saved) throws ShellError {
            string[] argv = {};
            if (protocol == Protocol.SSH) {
                argv += "ssh";
                argv += "-p";
            } else {
                argv += "sftp";
                argv += "-P";
            }
            argv += port.to_string ();

            if (auth_method == AuthMethod.KEY_FILE && identity_file != "") {
                argv += "-i";
                argv += identity_file;
                argv += "-o";
                argv += "IdentitiesOnly=yes";
            } else if (auth_method == AuthMethod.PASSWORD) {
                argv += "-o";
                argv += "PreferredAuthentications=keyboard-interactive,password";
                argv += "-o";
                argv += "PubkeyAuthentication=no";
                if (password_saved) {
                    /* The askpass helper answers once; don't loop on a wrong password. */
                    argv += "-o";
                    argv += "NumberOfPasswordPrompts=1";
                }
            }

            if (jump_host != "") {
                argv += "-J";
                argv += jump_host;
            }

            if (extra_options.strip () != "") {
                string[] extra;
                Shell.parse_argv (extra_options.strip (), out extra);
                foreach (var a in extra) {
                    argv += a;
                }
            }

            argv += "--";
            if (protocol == Protocol.SFTP && remote_directory != "") {
                argv += destination + ":" + remote_directory;
            } else {
                argv += destination;
            }
            return argv;
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("group").add_string_value (group_id);
            b.set_member_name ("host").add_string_value (host);
            b.set_member_name ("port").add_int_value (port);
            b.set_member_name ("username").add_string_value (username);
            b.set_member_name ("auth").add_string_value (auth_method.to_string ());
            b.set_member_name ("identity_file").add_string_value (identity_file);
            b.set_member_name ("jump_host").add_string_value (jump_host);
            b.set_member_name ("remote_directory").add_string_value (remote_directory);
            b.set_member_name ("extra_options").add_string_value (extra_options);
            b.end_object ();
            return b.get_root ();
        }

        public static Connection from_json (Json.Object o) {
            var c = new Connection ();
            c.id = o.get_string_member_with_default ("id", c.id);
            c.name = o.get_string_member_with_default ("name", "");
            c.group_id = o.get_string_member_with_default ("group", "");
            c.host = o.get_string_member_with_default ("host", "");
            c.port = (int) o.get_int_member_with_default ("port", 22);
            c.username = o.get_string_member_with_default ("username", "");
            c.auth_method = AuthMethod.from_string (o.get_string_member_with_default ("auth", "agent"));
            c.identity_file = o.get_string_member_with_default ("identity_file", "");
            c.jump_host = o.get_string_member_with_default ("jump_host", "");
            c.remote_directory = o.get_string_member_with_default ("remote_directory", "");
            c.extra_options = o.get_string_member_with_default ("extra_options", "");
            return c;
        }
    }
}
