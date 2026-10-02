desktop_conf = configuration_data()
desktop_conf.set('APP_ID', app_id)

desktop_file = configure_file(
  input: 'sxpilot.desktop.in',
  output: app_id + '.desktop',
  configuration: desktop_conf,
  install: true,
  install_dir: get_option('datadir') / 'applications',
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('Validate desktop file', desktop_utils, args: [desktop_file])
endif

metainfo_file = configure_file(
  input: 'sxpilot.metainfo.xml.in',
  output: app_id + '.metainfo.xml',
  configuration: desktop_conf,
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test('Validate metainfo file', appstreamcli,
    args: ['validate', '--no-net', '--explain',
           # TODO: add a <url type="homepage"> once the project is published.
           '--override=url-homepage-missing=info', metainfo_file])
endif

schema_file = files(app_id + '.gschema.xml')
install_data(schema_file, install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')

compile_schemas = find_program('glib-compile-schemas', required: false)
if compile_schemas.found()
  test('Validate schema file', compile_schemas,
    args: ['--strict', '--dry-run', meson.current_source_dir()])
endif

install_data('icons/hicolor/scalable/apps/sxpilot.svg',
  rename: app_id + '.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
install_data('icons/hicolor/symbolic/apps/sxpilot-symbolic.svg',
  rename: app_id + '-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps',
)

# Compiled schema in the build dir so `meson devenv` can run the app uninstalled.
# Compiled into the build dir (and registered for `meson devenv`) so the
# app can run uninstalled.
gnome.compile_schemas(build_by_default: true, depend_files: schema_file)
