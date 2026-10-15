namespace SxPilot.SshEnv {

    public string? find_askpass () {
        var env = Environment.get_variable ("SXPILOT_ASKPASS");
        if (env != null && FileUtils.test (env, FileTest.IS_EXECUTABLE)) {
            return env;
        }
        if (FileUtils.test (Config.ASKPASS_PATH, FileTest.IS_EXECUTABLE)) {
            return Config.ASKPASS_PATH;
        }
        /* Running from the build directory: the helper sits next to us. */
        try {
            var self = FileUtils.read_link ("/proc/self/exe");
            var candidate = Path.build_filename (Path.get_dirname (self), "sxpilot-askpass");
            if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                return candidate;
            }
        } catch (FileError e) {
        }
        return null;
    }

    /* Environment for an ssh process. When the connection has a password in
     * the keyring, ssh asks the helper, which reads it from the keyring
     * itself: it never appears in argv or env. With `batch`, the helper
     * refuses every other prompt instead of showing a dialog.
     * `password_saved` tells whether the helper will answer the password. */
    public async string[] prepare (Connection connection, bool batch, out bool password_saved) {
        string[] env = Environ.get ();
        password_saved = false;

        if (connection.auth_method != AuthMethod.PASSWORD) {
            return env;
        }
        string? password = null;
        try {
            password = yield Secrets.lookup_password (connection.id);
        } catch (Error e) {
            warning ("Keyring lookup failed: %s", e.message);
        }
        var askpass = find_askpass ();
        if (password != null && askpass != null) {
            password_saved = true;
            env = Environ.set_variable (env, "SSH_ASKPASS", askpass, true);
            env = Environ.set_variable (env, "SSH_ASKPASS_REQUIRE", "force", true);
            env = Environ.set_variable (env, "SXPILOT_CONNECTION_ID", connection.id, true);
            env = Environ.set_variable (env, "SXPILOT_CONNECTION_NAME", connection.display_name, true);
            if (batch) {
                env = Environ.set_variable (env, "SXPILOT_ASKPASS_BATCH", "1", true);
            }
        } else if (password != null) {
            warning ("sxpilot-askpass not found; the password will be asked in the terminal");
        }
        return env;
    }
}
