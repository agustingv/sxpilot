namespace SxPilot {

    /* Holds every group and connection and persists them as JSON in
     * $XDG_CONFIG_HOME/sxpilot/connections.json. */
    public class Store : Object {
        private static Store? _instance = null;

        public GenericArray<Group> groups { get; private set; default = new GenericArray<Group> (); }
        public GenericArray<Connection> connections { get; private set; default = new GenericArray<Connection> (); }

        public signal void changed ();

        public static Store get_default () {
            if (_instance == null) {
                _instance = new Store ();
                _instance.load ();
            }
            return _instance;
        }

        private string path {
            owned get { return Path.build_filename (Environment.get_user_config_dir (), "sxpilot", "connections.json"); }
        }

        public void load () {
            groups.remove_range (0, groups.length);
            connections.remove_range (0, connections.length);

            if (!FileUtils.test (path, FileTest.EXISTS)) {
                return;
            }
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ().get_object ();
                if (root.has_member ("groups")) {
                    root.get_array_member ("groups").foreach_element ((a, i, node) => {
                        groups.add (Group.from_json (node.get_object ()));
                    });
                }
                if (root.has_member ("connections")) {
                    root.get_array_member ("connections").foreach_element ((a, i, node) => {
                        var c = Connection.from_json (node.get_object ());
                        if (c.group_id != "" && find_group (c.group_id) == null) {
                            c.group_id = "";
                        }
                        connections.add (c);
                    });
                }
            } catch (Error e) {
                warning ("Could not load %s: %s", path, e.message);
            }
        }

        public void save () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("version").add_int_value (1);
            b.set_member_name ("groups").begin_array ();
            foreach (var g in groups) {
                b.add_value (g.to_json ());
            }
            b.end_array ();
            b.set_member_name ("connections").begin_array ();
            foreach (var c in connections) {
                b.add_value (c.to_json ());
            }
            b.end_array ();
            b.end_object ();

            var gen = new Json.Generator ();
            gen.pretty = true;
            gen.set_root (b.get_root ());
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents_full (path, gen.to_data (null),
                                             -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning ("Could not save %s: %s", path, e.message);
            }
            changed ();
        }

        public Group? find_group (string id) {
            foreach (var g in groups) {
                if (g.id == id) {
                    return g;
                }
            }
            return null;
        }

        public Connection? find_connection (string id) {
            foreach (var c in connections) {
                if (c.id == id) {
                    return c;
                }
            }
            return null;
        }

        public GenericArray<Connection> connections_in (string group_id) {
            var result = new GenericArray<Connection> ();
            foreach (var c in connections) {
                if (c.group_id == group_id) {
                    result.add (c);
                }
            }
            result.sort ((a, b) => a.display_name.collate (b.display_name));
            return result;
        }

        public GenericArray<Group> sorted_groups () {
            var result = new GenericArray<Group> ();
            foreach (var g in groups) {
                result.add (g);
            }
            result.sort ((a, b) => a.name.collate (b.name));
            return result;
        }

        public void add_group (Group g) {
            groups.add (g);
            save ();
        }

        /* Connections of a deleted group become ungrouped. */
        public void remove_group (Group g) {
            foreach (var c in connections) {
                if (c.group_id == g.id) {
                    c.group_id = "";
                }
            }
            groups.remove (g);
            save ();
        }

        public void add_connection (Connection c) {
            connections.add (c);
            save ();
        }

        public void remove_connection (Connection c) {
            connections.remove (c);
            save ();
            Secrets.clear_password.begin (c.id, (obj, res) => {
                try {
                    Secrets.clear_password.end (res);
                } catch (Error e) {
                    warning ("Could not clear password: %s", e.message);
                }
            });
        }
    }
}
