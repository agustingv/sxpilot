/* When run straight from the build tree (./build/src/sxpilot), use the
 * schema compiled in build/data and the bundled extensions copied there.
 * Must run before GSettings is first used. */
void use_build_tree_data () {
    try {
        var exe_dir = Path.get_dirname (FileUtils.read_link ("/proc/self/exe"));
        var data_dir = Path.build_filename (exe_dir, "..", "data");
        if (Environment.get_variable ("GSETTINGS_SCHEMA_DIR") == null
            && FileUtils.test (Path.build_filename (data_dir, "gschemas.compiled"), FileTest.EXISTS)) {
            Environment.set_variable ("GSETTINGS_SCHEMA_DIR", data_dir, true);
        }
        var ext_dir = Path.build_filename (data_dir, "extensions");
        if (Environment.get_variable ("SXPILOT_EXTENSIONS_DIR") == null
            && FileUtils.test (ext_dir, FileTest.IS_DIR)) {
            Environment.set_variable ("SXPILOT_EXTENSIONS_DIR", ext_dir, true);
        }
    } catch (FileError e) {
    }
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    SxPilot.setup_gettext ();
    use_build_tree_data ();
    Environment.set_application_name ("SxPilot");
    return new SxPilot.Application ().run (args);
}
