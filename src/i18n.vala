namespace SxPilot {

    /* Translations come from the install prefix, or from build/po when
     * running uninstalled (the executables sit in build/src). */
    public void setup_gettext () {
        var localedir = Config.LOCALEDIR;
        try {
            var exe_dir = Path.get_dirname (FileUtils.read_link ("/proc/self/exe"));
            var build_po = Path.build_filename (exe_dir, "..", "po");
            if (FileUtils.test (Path.build_filename (build_po, "LINGUAS"), FileTest.EXISTS)
                || FileUtils.test (Path.build_filename (exe_dir, "..", "build.ninja"), FileTest.EXISTS)) {
                localedir = build_po;
            }
        } catch (FileError e) {
        }
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, localedir);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);
    }
}
