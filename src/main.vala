/* When run straight from the build tree (./build/src/sxpilot), use the
 * schema compiled in build/data. Must run before GSettings is first used. */
void use_build_tree_schemas () {
    if (Environment.get_variable ("GSETTINGS_SCHEMA_DIR") != null) {
        return;
    }
    try {
        var exe_dir = Path.get_dirname (FileUtils.read_link ("/proc/self/exe"));
        var data_dir = Path.build_filename (exe_dir, "..", "data");
        if (FileUtils.test (Path.build_filename (data_dir, "gschemas.compiled"), FileTest.EXISTS)) {
            Environment.set_variable ("GSETTINGS_SCHEMA_DIR", data_dir, true);
        }
    } catch (FileError e) {
    }
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    use_build_tree_schemas ();
    Environment.set_application_name ("SxPilot");
    return new SxPilot.Application ().run (args);
}
