int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    Environment.set_application_name ("SxPilot");
    return new SxPilot.Application ().run (args);
}
