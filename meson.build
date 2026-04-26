project('budgie-radio-widget',
    ['vala', 'c'],
    version: '0.0.1',
    meson_version: '>= 0.57.0',
    default_options: [
        'warning_level=2',
    ]
)

# Project info
PROJECT_NAME = meson.project_name()
PROJECT_VERSION = meson.project_version()

# Install directories
PREFIX = get_option('prefix')
BINDIR = join_paths(PREFIX, get_option('bindir'))
DATADIR = join_paths(PREFIX, get_option('datadir'))
LIBDIR = join_paths(PREFIX, get_option('libdir'))

# Python installation
python = import('python').find_installation('python3', required: true)

# Dependencies
gtk_dep = dependency('gtk+-3.0', version: '>= 3.22')
gio_dep = dependency('gio-2.0')
gdk_pixbuf_dep = dependency('gdk-pixbuf-2.0')
dependency('gstreamer-1.0')
budgie_dep = dependency('budgie-3.0')
raven_dep = dependency('budgie-raven-plugin-3.0')
peas_dep = dependency('libpeas-2')

# Check for python dependencies
python_radios = run_command(
    python,
    '-c',
    'import radios',
    check: false
)

if python_radios.returncode() != 0
    warning('Python "radios" module not found. Install with: sudo apt install python3-radios')
endif

# Subdirectories
subdir('schema')
subdir('daemon')
subdir('gui-app')
subdir('raven-widget')

# Summary
message('Configuration:')
message('  Version:           @0@'.format(PROJECT_VERSION))
message('  Prefix:            @0@'.format(PREFIX))
message('  Binary directory:  @0@'.format(BINDIR))
message('  Data directory:    @0@'.format(DATADIR))
message('')
message('After installation:')
message('  1. Restart Budgie: budgie-panel --replace &')
message('  2. Enable widget in Budgie Settings → Raven')
message('  3. Run daemon: radio-daemon')
message('  4. Or launch browser: budgie-radio-browser')
message('')

