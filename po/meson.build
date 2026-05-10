# Translation support

i18n = import('i18n')

# Process translations using gettext
i18n.gettext(
    'budgie-radio-widget',
    args: [
        '--keyword=_',
        '--keyword=N_',
        '--from-code=UTF-8',
    ],
    preset: 'glib'
)

# Desktop file translation
# The desktop file will be processed during build
# and translations merged from .po files
i18n.merge_file(
    input: 'budgie-radio-widget.desktop',
    output: 'budgie-radio-browser.desktop',
    type: 'desktop',
    po_dir: meson.current_source_dir(),
    install: true,
    install_dir: join_paths(get_option('datadir'), 'applications')
)
