project('sxpilot', ['c', 'vala'],
  version: '0.1.0',
  meson_version: '>= 0.62.0',
  default_options: ['warning_level=2'],
)

i18n = import('i18n')
gnome = import('gnome')

app_id = 'io.github.agustingv.sxpilot'

# Vala-generated C is noisy; keep the build output readable.
add_project_arguments('-w', language: 'c')

subdir('data')
subdir('src')

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
