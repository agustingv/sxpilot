/* Passwords are kept in the Secret Service (GNOME Keyring / KWallet),
 * keyed by the connection id. They never touch the JSON config file. */
namespace SxPilot.Secrets {
    private static Secret.Schema? _schema = null;

    public unowned Secret.Schema get_schema () {
        if (_schema == null) {
            _schema = new Secret.Schema (Config.APP_ID + ".Password",
                                         Secret.SchemaFlags.NONE,
                                         "connection-id", Secret.SchemaAttributeType.STRING);
        }
        return _schema;
    }

    public async void store_password (string connection_id, string label, string password) throws Error {
        yield Secret.password_store (get_schema (), Secret.COLLECTION_DEFAULT,
                                     "SxPilot: " + label, password, null,
                                     "connection-id", connection_id);
    }

    public async string? lookup_password (string connection_id) throws Error {
        return yield Secret.password_lookup (get_schema (), null, "connection-id", connection_id);
    }

    public string? lookup_password_sync (string connection_id) throws Error {
        return Secret.password_lookup_sync (get_schema (), null, "connection-id", connection_id);
    }

    public async void clear_password (string connection_id) throws Error {
        yield Secret.password_clear (get_schema (), null, "connection-id", connection_id);
    }
}
