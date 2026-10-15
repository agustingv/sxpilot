namespace SxPilot {

    public class PreferencesDialog : Adw.PreferencesDialog {
        construct {
            var settings = new Settings (Config.APP_ID);

            var page = new Adw.PreferencesPage ();
            page.title = _("General");
            page.icon_name = "utilities-terminal-symbolic";

            var group = new Adw.PreferencesGroup ();
            group.title = _("Terminal");

            var font_row = new Adw.ActionRow ();
            font_row.title = _("Font");
            var font_button = new Gtk.FontDialogButton (new Gtk.FontDialog ());
            font_button.valign = Gtk.Align.CENTER;
            font_button.level = Gtk.FontLevel.FONT;
            font_button.use_font = true;
            font_button.font_desc = Pango.FontDescription.from_string (settings.get_string ("terminal-font"));
            font_button.notify["font-desc"].connect (() => {
                settings.set_string ("terminal-font", font_button.font_desc.to_string ());
            });
            font_row.add_suffix (font_button);
            font_row.activatable_widget = font_button;
            group.add (font_row);

            var scrollback = new Adw.SpinRow.with_range (100, 1000000, 1000);
            scrollback.title = _("Scrollback Lines");
            settings.bind ("terminal-scrollback", scrollback, "value", SettingsBindFlags.DEFAULT);
            group.add (scrollback);

            page.add (group);

            var monitoring = new Adw.PreferencesGroup ();
            monitoring.title = _("Monitoring");

            var interval = new Adw.SpinRow.with_range (2, 300, 1);
            interval.title = _("Update Interval");
            interval.subtitle = _("Seconds between samples of monitored servers");
            settings.bind ("monitor-interval", interval, "value", SettingsBindFlags.DEFAULT);
            monitoring.add (interval);

            page.add (monitoring);

            var alerts = new Adw.PreferencesGroup ();
            alerts.title = _("Alerts");
            alerts.description = _("Desktop notifications for monitored servers. A threshold of 0 disables that alert.");

            var enabled = new Adw.SwitchRow ();
            enabled.title = _("Enable Alerts");
            settings.bind ("alerts-enabled", enabled, "active", SettingsBindFlags.DEFAULT);
            alerts.add (enabled);

            var offline = new Adw.SwitchRow ();
            offline.title = _("Server Unreachable");
            settings.bind ("alert-offline", offline, "active", SettingsBindFlags.DEFAULT);
            alerts.add (offline);

            alerts.add (threshold_row (settings, "alert-cpu", _("CPU Usage Above")));
            alerts.add (threshold_row (settings, "alert-memory", _("Memory Usage Above")));
            alerts.add (threshold_row (settings, "alert-disk", _("Disk Usage Above")));

            var minutes = new Adw.SpinRow.with_range (0, 60, 1);
            minutes.title = _("Minimum Duration");
            minutes.subtitle = _("Minutes a condition must last before alerting");
            settings.bind ("alert-minutes", minutes, "value", SettingsBindFlags.DEFAULT);
            alerts.add (minutes);

            enabled.bind_property ("active", offline, "sensitive", BindingFlags.SYNC_CREATE);
            enabled.bind_property ("active", minutes, "sensitive", BindingFlags.SYNC_CREATE);
            foreach (var row in threshold_rows) {
                enabled.bind_property ("active", row, "sensitive", BindingFlags.SYNC_CREATE);
            }

            page.add (alerts);

            extensions_group = new Adw.PreferencesGroup ();
            extensions_group.title = _("Monitoring Extensions");
            extensions_group.description = _("Add your own as JSON files in %s. Enable them in each connection.")
                .printf (Markup.escape_text (ExtensionRegistry.user_dir ()));

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var open_folder = new Gtk.Button.from_icon_name ("folder-open-symbolic");
            open_folder.tooltip_text = _("Open Extensions Folder");
            open_folder.add_css_class ("flat");
            open_folder.clicked.connect (open_extensions_folder);
            buttons.append (open_folder);
            var reload = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
            reload.tooltip_text = _("Reload Extensions");
            reload.add_css_class ("flat");
            reload.clicked.connect (() => {
                ExtensionRegistry.get_default ().load ();
                /* Restarts the monitors whose extensions changed. */
                MonitorManager.get_default ().sync ();
                fill_extensions ();
                var loaded = ExtensionRegistry.get_default ().extensions.length;
                add_toast (new Adw.Toast (ngettext ("%u extension loaded", "%u extensions loaded", loaded).printf (loaded)));
            });
            buttons.append (reload);
            extensions_group.header_suffix = buttons;

            fill_extensions ();
            page.add (extensions_group);
            add (page);
        }

        private GenericArray<Gtk.Widget> threshold_rows = new GenericArray<Gtk.Widget> ();

        private Adw.SpinRow threshold_row (Settings settings, string key, string title) {
            var row = new Adw.SpinRow.with_range (0, 100, 5);
            row.title = title;
            row.subtitle = _("Percent");
            settings.bind (key, row, "value", SettingsBindFlags.DEFAULT);
            threshold_rows.add (row);
            return row;
        }

        private Adw.PreferencesGroup extensions_group;
        private GenericArray<Gtk.Widget> extension_rows = new GenericArray<Gtk.Widget> ();

        private void fill_extensions () {
            foreach (var row in extension_rows) {
                extensions_group.remove (row);
            }
            extension_rows = new GenericArray<Gtk.Widget> ();

            var registry = ExtensionRegistry.get_default ();
            if (registry.extensions.length == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = _("No extensions installed");
                empty.add_css_class ("dim-label");
                extensions_group.add (empty);
                extension_rows.add (empty);
                return;
            }
            foreach (var ext in registry.extensions) {
                var row = new Adw.ActionRow ();
                row.title = Markup.escape_text (ext.name);
                row.subtitle = Markup.escape_text (ext.path);
                row.subtitle_lines = 1;
                row.tooltip_text = ext.path;
                extensions_group.add (row);
                extension_rows.add (row);
            }
        }

        private void open_extensions_folder () {
            var dir = ExtensionRegistry.user_dir ();
            DirUtils.create_with_parents (dir, 0755);
            var launcher = new Gtk.FileLauncher (File.new_for_path (dir));
            launcher.launch.begin (get_root () as Gtk.Window, null, (obj, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    add_toast (new Adw.Toast (_("Could not open the folder")));
                }
            });
        }
    }
}
