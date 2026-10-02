namespace SxPilot {

    public class PreferencesDialog : Adw.PreferencesDialog {
        construct {
            var settings = new Settings (Config.APP_ID);

            var page = new Adw.PreferencesPage ();
            page.title = "General";
            page.icon_name = "utilities-terminal-symbolic";

            var group = new Adw.PreferencesGroup ();
            group.title = "Terminal";

            var font_row = new Adw.ActionRow ();
            font_row.title = "Font";
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
            scrollback.title = "Scrollback Lines";
            settings.bind ("terminal-scrollback", scrollback, "value", SettingsBindFlags.DEFAULT);
            group.add (scrollback);

            page.add (group);
            add (page);
        }
    }
}
