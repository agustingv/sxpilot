/* SSH_ASKPASS helper. ssh runs it with the prompt as argv[1] and reads the
 * answer from stdout. Password prompts are answered from the keyring entry
 * of $SXPILOT_CONNECTION_ID; anything else (host key confirmation, key
 * passphrases, OTPs) is shown in a small dialog. */

static bool is_password_prompt (string prompt) {
    var p = prompt.down ();
    return p.contains ("password") && !p.contains ("passphrase") && !p.contains ("new password");
}

static bool is_confirmation (string prompt) {
    return prompt.contains ("(yes/no") || prompt.contains ("yes/no)");
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    var prompt = args.length > 1 ? args[1] : "Password:";
    var connection_id = Environment.get_variable ("SXPILOT_CONNECTION_ID");

    if (connection_id != null && is_password_prompt (prompt)) {
        try {
            var password = SxPilot.Secrets.lookup_password_sync (connection_id);
            if (password != null) {
                stdout.printf ("%s\n", password);
                return 0;
            }
        } catch (Error e) {
            printerr ("sxpilot-askpass: %s\n", e.message);
        }
    }

    return run_dialog (prompt);
}

static int run_dialog (string prompt) {
    var name = Environment.get_variable ("SXPILOT_CONNECTION_NAME") ?? "SSH";
    var app = new Adw.Application (null, ApplicationFlags.NON_UNIQUE);
    int status = 1;

    app.activate.connect (() => {
        var window = new Adw.ApplicationWindow (app);
        window.title = name;
        window.default_width = 460;
        window.resizable = false;

        bool confirm = is_confirmation (prompt);
        var label = new Gtk.Label (prompt.strip ());
        label.wrap = true;
        label.wrap_mode = Pango.WrapMode.WORD_CHAR;
        label.xalign = 0;
        label.selectable = true;
        label.max_width_chars = 60;
        if (confirm) {
            label.add_css_class ("monospace");
        }

        var entry = new Gtk.PasswordEntry ();
        entry.show_peek_icon = true;
        entry.activates_default = true;
        entry.visible = !confirm;

        var cancel = new Gtk.Button.with_mnemonic ("_Cancel");
        var ok = new Gtk.Button.with_mnemonic (confirm ? "_Accept" : "_OK");
        ok.add_css_class ("suggested-action");
        window.default_widget = ok;

        cancel.clicked.connect (() => window.close ());
        ok.clicked.connect (() => {
            stdout.printf ("%s\n", confirm ? "yes" : entry.text);
            stdout.flush ();
            status = 0;
            window.close ();
        });

        var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        buttons.halign = Gtk.Align.END;
        buttons.append (cancel);
        buttons.append (ok);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18);
        box.margin_top = box.margin_bottom = box.margin_start = box.margin_end = 18;
        box.append (label);
        box.append (entry);
        box.append (buttons);

        var view = new Adw.ToolbarView ();
        view.add_top_bar (new Adw.HeaderBar ());
        view.content = box;
        window.content = view;
        window.present ();
        if (confirm) {
            ok.grab_focus ();
        } else {
            entry.grab_focus ();
        }
    });

    app.run (null);
    return status;
}
