# Install GSettings schema
install_data(
    'org.ubuntubudgie.plugins.radio-browser.gschema.xml',
    install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas')
)

# Compile schemas after installation
gnome = import('gnome')
gnome.post_install(
    glib_compile_schemas: true,
)
