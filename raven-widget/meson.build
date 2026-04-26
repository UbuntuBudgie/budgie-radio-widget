
# Vala compiler arguments
vala_args = [
    '--target-glib=2.56',
]

# Vala generates bad C code and missing these on gcc 14 will cause FTBFS
# Additionally, Meson 1.4 unhides warnings from valac-generated C code,
# which causes unreadable logspam. Reenables prior behavior.
am_cflags = [
    '-w',
    '-Wno-incompatible-pointer-types',
    '-Wno-implicit-function-declaration',
]
add_global_arguments(am_cflags, language: 'c')

# Source files
widget_sources = files(
    'RadioWidget.vala',
)

# Module name and install directory
WIDGET_MODULE = 'org.ubuntubudgie.raven.widget.radio-browser'
RAVEN_PLUGIN_LIBDIR = join_paths(LIBDIR, 'budgie-desktop', 'raven-plugins', WIDGET_MODULE)

# Shared library for Raven widget
shared_library(
    WIDGET_MODULE,
    widget_sources,
    dependencies: [
        budgie_dep,
        raven_dep,
        gtk_dep,
        gio_dep,
        gdk_pixbuf_dep,
        peas_dep,
    ],
    vala_args: vala_args,
    install: true,
    install_dir: RAVEN_PLUGIN_LIBDIR
)

# Plugin metadata
install_data(
    'BudgieRadioWidget.plugin',
    install_dir: RAVEN_PLUGIN_LIBDIR
)
