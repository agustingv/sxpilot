extension_files = [
  'apache.json',
  'mysql.json',
  'nginx.json',
  'postgresql.json',
  'redis.json',
]

install_data(extension_files, install_dir: get_option('datadir') / 'sxpilot' / 'extensions')

# Copies in build/data/extensions so the app finds them when run uninstalled.
foreach f : extension_files
  configure_file(input: f, output: f, copy: true)
endforeach
