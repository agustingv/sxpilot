conf = configuration_data()
conf.set_quoted('APP_ID', app_id)
conf.set_quoted('VERSION', meson.project_version())
conf.set_quoted('GETTEXT_PACKAGE', meson.project_name())
conf.set_quoted('ASKPASS_PATH', get_option('prefix') / get_option('libexecdir') / 'sxpilot-askpass')

config_h = configure_file(output: 'config.h', configuration: conf)

common_args = ['-include', 'config.h']

posix_dep = meson.get_compiler('vala').find_library('posix')
secret_dep = dependency('libsecret-1')
adw_dep = dependency('libadwaita-1', version: '>= 1.5')
gtk_dep = dependency('gtk4', version: '>= 4.14')

executable('sxpilot',
  'config.vapi',
  'secrets.vala',
  'models.vala',
  'store.vala',
  'terminal-tab.vala',
  'connection-dialog.vala',
  'sidebar.vala',
  'preferences-dialog.vala',
  'window.vala',
  'application.vala',
  'main.vala',
  c_args: common_args,
  dependencies: [
    adw_dep,
    gtk_dep,
    dependency('vte-2.91-gtk4', version: '>= 0.76'),
    dependency('json-glib-1.0'),
    secret_dep,
    posix_dep,
  ],
  install: true,
)

executable('sxpilot-askpass',
  'config.vapi',
  'secrets.vala',
  'askpass.vala',
  c_args: common_args,
  dependencies: [adw_dep, gtk_dep, secret_dep],
  install: true,
  install_dir: get_option('libexecdir'),
)
