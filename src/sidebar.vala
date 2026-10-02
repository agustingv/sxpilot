namespace SxPilot {

    /* Groups and connections list. Every row triggers `win.*` actions
     * (targeted by id), so the window owns all the behaviour. */
    public class Sidebar : Adw.Bin {
        private Gtk.Stack stack;
        private Gtk.ListBox list;
        private Gtk.SearchEntry search;
        private string filter = "";
        private bool saving_expanded = false;

        public Gtk.SearchEntry search_entry {
            get { return search; }
        }

        construct {
            search = new Gtk.SearchEntry ();
            search.placeholder_text = "Search connections";
            search.margin_start = 12;
            search.margin_end = 12;
            search.margin_top = 6;
            search.margin_bottom = 6;
            search.search_changed.connect (() => {
                filter = search.text.strip ();
                rebuild ();
            });
            search.activate.connect (activate_first_match);

            list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.valign = Gtk.Align.START;
            list.margin_start = 12;
            list.margin_end = 12;
            list.margin_top = 6;
            list.margin_bottom = 12;

            var scroller = new Gtk.ScrolledWindow ();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.vexpand = true;
            scroller.child = list;

            var empty = new Adw.StatusPage ();
            empty.icon_name = "network-server-symbolic";
            empty.title = "No Connections";
            empty.description = "Add a server to get started";
            empty.add_css_class ("compact");
            var add = new Gtk.Button.with_mnemonic ("_Add Connection");
            add.halign = Gtk.Align.CENTER;
            add.add_css_class ("pill");
            add.add_css_class ("suggested-action");
            add.action_name = "win.new-connection";
            empty.child = add;

            var no_results = new Adw.StatusPage ();
            no_results.icon_name = "edit-find-symbolic";
            no_results.title = "No Results";
            no_results.add_css_class ("compact");

            stack = new Gtk.Stack ();
            stack.add_named (scroller, "list");
            stack.add_named (empty, "empty");
            stack.add_named (no_results, "no-results");

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (search);
            box.append (stack);
            child = box;

            Store.get_default ().changed.connect (() => {
                if (!saving_expanded) {
                    rebuild ();
                }
            });
            rebuild ();
        }

        private void activate_first_match () {
            for (var row = list.get_first_child (); row != null; row = row.get_next_sibling ()) {
                var expander = row as Adw.ExpanderRow;
                if (expander == null) {
                    continue;
                }
                var id = expander.get_data<string> ("first-connection");
                if (id != null) {
                    activate_action_variant ("win.connect-ssh", new Variant.string (id));
                    return;
                }
            }
        }

        public void rebuild () {
            var store = Store.get_default ();
            list.remove_all ();

            if (store.connections.length == 0 && store.groups.length == 0) {
                stack.visible_child_name = "empty";
                return;
            }

            int shown = 0;
            foreach (var g in store.sorted_groups ()) {
                shown += add_group (g.id, g.name, g);
            }
            shown += add_group ("", "Ungrouped", null);

            stack.visible_child_name = filter != "" && shown == 0 ? "no-results" : "list";
        }

        /* Returns how many connections were added. */
        private int add_group (string id, string name, Group? group) {
            var connections = Store.get_default ().connections_in (id);
            var matching = new GenericArray<Connection> ();
            foreach (var c in connections) {
                if (c.matches (filter)) {
                    matching.add (c);
                }
            }

            bool group_matches = group != null && filter != "" && name.casefold ().contains (filter.casefold ());
            if (matching.length == 0 && (group == null || (filter != "" && !group_matches))) {
                return 0;
            }
            if (group_matches) {
                matching = connections;
            }

            var expander = new Adw.ExpanderRow ();
            expander.title = Markup.escape_text (name);
            expander.subtitle = connections.length == 1 ? "1 connection" : "%u connections".printf (connections.length);
            expander.add_prefix (new Gtk.Image.from_icon_name (group != null ? "folder-symbolic" : "folder-documents-symbolic"));
            expander.expanded = filter != "" || group == null || group.expanded;
            if (group != null) {
                expander.notify["expanded"].connect (() => {
                    if (filter == "" && group.expanded != expander.expanded) {
                        group.expanded = expander.expanded;
                        /* Persist quietly; no need to rebuild the list. */
                        saving_expanded = true;
                        Store.get_default ().save ();
                        saving_expanded = false;
                    }
                });

                var menu = new Menu ();
                var section = new Menu ();
                section.append_item (target_item ("_New Connection…", "win.new-connection-in-group", id));
                menu.append_section (null, section);
                section = new Menu ();
                section.append_item (target_item ("_Rename…", "win.rename-group", id));
                section.append_item (target_item ("_Delete", "win.delete-group", id));
                menu.append_section (null, section);

                var button = new Gtk.MenuButton ();
                button.icon_name = "view-more-symbolic";
                button.valign = Gtk.Align.CENTER;
                button.tooltip_text = "Group Options";
                button.add_css_class ("flat");
                button.menu_model = menu;
                expander.add_suffix (button);
            }

            if (matching.length > 0) {
                expander.set_data<string> ("first-connection", matching[0].id);
            }
            foreach (var c in matching) {
                expander.add_row (build_connection_row (c));
            }
            if (connections.length == 0) {
                var placeholder = new Adw.ActionRow ();
                placeholder.title = "No connections";
                placeholder.add_css_class ("dim-label");
                expander.add_row (placeholder);
            }

            list.append (expander);
            return (int) matching.length;
        }

        private static MenuItem target_item (string label, string action, string target) {
            var item = new MenuItem (label, null);
            item.set_action_and_target_value (action, new Variant.string (target));
            return item;
        }

        private Gtk.Widget build_connection_row (Connection c) {
            var row = new Adw.ActionRow ();
            row.title = Markup.escape_text (c.display_name);
            row.subtitle = Markup.escape_text (c.summary);
            row.title_lines = 1;
            row.subtitle_lines = 1;
            row.tooltip_text = "Open SSH session";
            row.activatable = true;
            row.set_action_name ("win.connect-ssh");
            row.set_action_target_value (new Variant.string (c.id));
            row.add_prefix (new Gtk.Image.from_icon_name ("network-server-symbolic"));

            var sftp = new Gtk.Button.from_icon_name ("folder-remote-symbolic");
            sftp.valign = Gtk.Align.CENTER;
            sftp.tooltip_text = "Open SFTP Session";
            sftp.add_css_class ("flat");
            sftp.set_action_name ("win.connect-sftp");
            sftp.set_action_target_value (new Variant.string (c.id));
            row.add_suffix (sftp);

            var menu = new Menu ();
            var open = new Menu ();
            open.append_item (target_item ("Open _SSH", "win.connect-ssh", c.id));
            open.append_item (target_item ("Open S_FTP", "win.connect-sftp", c.id));
            menu.append_section (null, open);
            var edit = new Menu ();
            edit.append_item (target_item ("_Edit…", "win.edit-connection", c.id));
            edit.append_item (target_item ("D_uplicate", "win.duplicate-connection", c.id));
            edit.append_item (target_item ("Copy SSH _Command", "win.copy-command", c.id));
            menu.append_section (null, edit);
            var del = new Menu ();
            del.append_item (target_item ("_Delete", "win.delete-connection", c.id));
            menu.append_section (null, del);

            var more = new Gtk.MenuButton ();
            more.icon_name = "view-more-symbolic";
            more.valign = Gtk.Align.CENTER;
            more.tooltip_text = "Connection Options";
            more.add_css_class ("flat");
            more.menu_model = menu;
            row.add_suffix (more);

            /* Right click opens the same menu. */
            var click = new Gtk.GestureClick ();
            click.button = Gdk.BUTTON_SECONDARY;
            click.pressed.connect ((n, x, y) => {
                more.popup ();
                click.set_state (Gtk.EventSequenceState.CLAIMED);
            });
            row.add_controller (click);

            return row;
        }
    }
}
