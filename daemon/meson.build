# Install daemon script
install_data(
    'radio-daemon.py',
    install_dir: get_option('bindir'),
    install_mode: 'rwxr-xr-x',
    rename: 'radio-daemon'
)

# Install D-Bus service file
dbus_service_dir = join_paths(get_option('datadir'), 'dbus-1', 'services')
install_data(
    'org.ubuntubudgie.radio.service',
    install_dir: dbus_service_dir
)
