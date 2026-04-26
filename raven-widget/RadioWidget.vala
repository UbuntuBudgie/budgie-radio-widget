using Gtk;
using Gdk;

/*
 * RadioWidget - Budgie Raven Plugin
 * 
 * Displays currently playing radio station information.
 * Listens to D-Bus signals from radio-daemon.
 * 
 * Copyright 2026 Ubuntu Budgie Developers
 */

namespace BudgieRadio {

    public class RadioPlugin : Budgie.RavenPlugin, Peas.ExtensionBase {
        
        public Budgie.RavenWidget new_widget_instance(string uuid, GLib.Settings? settings) {
            return new RadioWidget(uuid, settings);
        }
        
        public bool supports_settings() {
            return false;
        }
    }

    public class RadioWidget : Budgie.RavenWidget {
        
        private Gtk.Image station_icon;
        private Gtk.Label station_label;
        private Gtk.Label track_label;
        private Gtk.Label codec_label;
        private Gtk.Button browse_button;
        private Gtk.Button toggle_button;
        private Gtk.Image play_icon;
        private Gtk.Image stop_icon;
        private Gtk.Box header_box;
        private Gtk.Box content_box;
        
        private GLib.DBusConnection? bus_connection;
        private uint now_playing_subscription = 0;
        private uint playback_stopped_subscription = 0;
        
        private bool is_playing = false;
        private GLib.Settings settings;
        
        public RadioWidget(string uuid, GLib.Settings? settings) {
            initialize(uuid, settings);
            
            // Initialize our settings
            this.settings = new GLib.Settings("org.ubuntubudgie.plugins.radio-browser");
            
            // Main container
            var main_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            add(main_box);
            
            // Build header (similar to wallpaper switcher example)
            build_header();
            main_box.pack_start(header_box, false, false, 0);
            
            // Build content area
            build_content();
            main_box.pack_start(content_box, false, false, 0);
            
            // Connect to D-Bus
            setup_dbus();
            
            // Load last station from GSettings
            load_last_station();
            
            show_all();
            update_visibility();
        }
        
        private void build_header() {
            header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            header_box.get_style_context().add_class("raven-header");
            
            // Icon
            station_icon = new Gtk.Image.from_icon_name("audio-x-generic", Gtk.IconSize.MENU);
            station_icon.set_tooltip_text("Internet Radio Player");
            station_icon.margin = 4;
            station_icon.margin_start = 12;
            station_icon.margin_end = 10;
            header_box.add(station_icon);
            
            // Title label
            var title_label = new Gtk.Label("Radio Player");
            header_box.add(title_label);
            
            // Toggle button (play/stop combined)
            play_icon = new Gtk.Image.from_icon_name(
                "media-playback-start-symbolic",
                Gtk.IconSize.MENU
            );
            stop_icon = new Gtk.Image.from_icon_name(
                "media-playback-stop-symbolic",
                Gtk.IconSize.MENU
            );
            
            toggle_button = new Gtk.Button();
            toggle_button.set_image(play_icon);
            toggle_button.set_tooltip_text("Play last station");
            toggle_button.get_style_context().add_class("flat");
            toggle_button.get_style_context().add_class("expander-button");
            toggle_button.margin = 4;
            toggle_button.valign = Gtk.Align.CENTER;
            toggle_button.clicked.connect(on_toggle_clicked);
            header_box.pack_end(toggle_button, false, false, 0);
        }
        
        private void build_content() {
            content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
            content_box.margin = 10;
            
            // Station name label
            station_label = new Gtk.Label("No station playing");
            station_label.get_style_context().add_class("h3");
            station_label.halign = Gtk.Align.START;
            station_label.wrap = true;
            station_label.max_width_chars = 30;
            content_box.pack_start(station_label, false, false, 2);
            
            // Track info label
            track_label = new Gtk.Label("");
            track_label.halign = Gtk.Align.START;
            track_label.wrap = true;
            track_label.max_width_chars = 30;
            track_label.get_style_context().add_class("dim-label");
            content_box.pack_start(track_label, false, false, 2);
            
            // Codec/bitrate label
            codec_label = new Gtk.Label("");
            codec_label.halign = Gtk.Align.START;
            codec_label.get_style_context().add_class("dim-label");
            var attr_list = new Pango.AttrList();
            attr_list.insert(Pango.attr_scale_new(0.85));
            codec_label.set_attributes(attr_list);
            content_box.pack_start(codec_label, false, false, 2);
            
            // Separator
            var separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
            content_box.pack_start(separator, false, false, 5);
            
            // Browse button
            browse_button = new Gtk.Button.with_label("Browse Stations");
            browse_button.get_style_context().add_class("suggested-action");
            browse_button.clicked.connect(on_browse_clicked);
            content_box.pack_start(browse_button, false, false, 5);
        }
        
        private void setup_dbus() {
            try {
                bus_connection = GLib.Bus.get_sync(GLib.BusType.SESSION);
                
                // Subscribe to NowPlaying signal
                now_playing_subscription = bus_connection.signal_subscribe(
                    "org.ubuntubudgie.radio",
                    "org.ubuntubudgie.radio.Daemon",
                    "NowPlaying",
                    "/org/ubuntubudgie/radio/Daemon",
                    null,
                    GLib.DBusSignalFlags.NONE,
                    on_now_playing_signal
                );
                
                // Subscribe to PlaybackStopped signal
                playback_stopped_subscription = bus_connection.signal_subscribe(
                    "org.ubuntubudgie.radio",
                    "org.ubuntubudgie.radio.Daemon",
                    "PlaybackStopped",
                    "/org/ubuntubudgie/radio/Daemon",
                    null,
                    GLib.DBusSignalFlags.NONE,
                    on_playback_stopped_signal
                );
                
            } catch (Error e) {
                warning("Failed to connect to D-Bus: %s", e.message);
            }
        }
        
        private void on_now_playing_signal(
            GLib.DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            // Extract signal parameters: (ssssi)
            string station_name = parameters.get_child_value(0).get_string();
            string track_info = parameters.get_child_value(1).get_string();
            string icon_url = parameters.get_child_value(2).get_string();
            string codec = parameters.get_child_value(3).get_string();
            int bitrate = (int)parameters.get_child_value(4).get_int32();
            
            // Update UI
            is_playing = true;
            station_label.set_text(station_name);
            track_label.set_text(track_info);
            codec_label.set_text(@"$codec $bitrate kbps");
            
            update_visibility();
            
            // Load icon asynchronously
            if (icon_url != "") {
                load_icon_async(icon_url);
            }
        }
        
        private void on_playback_stopped_signal(
            GLib.DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            // Reset UI
            is_playing = false;
            station_label.set_text("No station playing");
            track_label.set_text("");
            codec_label.set_text("");
            station_icon.set_from_icon_name("audio-x-generic", Gtk.IconSize.MENU);
            
            update_visibility();
        }
        
        private void update_visibility() {
            // Update toggle button icon and tooltip based on playback state
            if (is_playing) {
                toggle_button.set_image(stop_icon);
                toggle_button.set_tooltip_text("Stop playback");
                station_icon.get_style_context().remove_class("dim-label");
            } else {
                toggle_button.set_image(play_icon);
                toggle_button.set_tooltip_text("Play last station");
                station_icon.get_style_context().add_class("dim-label");
            }
        }
        
        private void load_icon_async(string url) {
            var file = File.new_for_uri(url);
            
            file.load_contents_async.begin(null, (obj, res) => {
                try {
                    uint8[] contents;
                    string etag_out;
                    
                    bool success = file.load_contents_async.end(
                        res, 
                        out contents, 
                        out etag_out
                    );
                    
                    if (success && contents.length > 0) {
                        var stream = new MemoryInputStream.from_data(contents);
                        var pixbuf = new Pixbuf.from_stream_at_scale(
                            stream, 
                            24, 24,  // Icon size for header
                            true,
                            null
                        );
                        
                        station_icon.set_from_pixbuf(pixbuf);
                    }
                } catch (Error e) {
                    warning("Failed to load station icon: %s", e.message);
                }
            });
        }
        
        private void on_toggle_clicked() {
            if (is_playing) {
                // Stop playback
                try {
                    var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
                        "org.ubuntubudgie.radio",
                        "/org/ubuntubudgie/radio/Daemon"
                    );
                    proxy.stop_playback();
                } catch (Error e) {
                    warning("Failed to stop playback: %s", e.message);
                }
            } else {
                // Play last station from GSettings
                string name = settings.get_string("last-station-name");
                string url = settings.get_string("last-station-url");
                string favicon = settings.get_string("last-station-favicon");
                string codec = settings.get_string("last-station-codec");
                int bitrate = settings.get_int("last-station-bitrate");
                string country = settings.get_string("last-station-country");
                
                if (url == "") {
                    warning("No last station to play");
                    return;
                }
                
                try {
                    var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
                        "org.ubuntubudgie.radio",
                        "/org/ubuntubudgie/radio/Daemon"
                    );
                    proxy.play_station_direct(name, url, favicon, codec, bitrate, country);
                } catch (Error e) {
                    warning("Failed to play station: %s", e.message);
                }
            }
        }
        
        private void load_last_station() {
            // Load last station info from GSettings and display it
            string name = settings.get_string("last-station-name");
            string codec = settings.get_string("last-station-codec");
            int bitrate = settings.get_int("last-station-bitrate");
            string favicon = settings.get_string("last-station-favicon");
            
            if (name != "") {
                station_label.set_text(name);
                codec_label.set_text(@"$codec $bitrate kbps");
                
                if (favicon != "") {
                    load_icon_async(favicon);
                }
            }
        }
        
        private void on_browse_clicked() {
            // Launch the full GUI browser application
            try {
                Process.spawn_command_line_async("budgie-radio-browser");
            } catch (SpawnError e) {
                warning("Failed to launch radio browser: %s", e.message);
            }
        }
        
        ~RadioWidget() {
            // Cleanup D-Bus subscriptions
            if (bus_connection != null) {
                if (now_playing_subscription != 0) {
                    bus_connection.signal_unsubscribe(now_playing_subscription);
                }
                if (playback_stopped_subscription != 0) {
                    bus_connection.signal_unsubscribe(playback_stopped_subscription);
                }
            }
        }
    }
}

// D-Bus proxy interface for calling daemon methods
[DBus (name = "org.ubuntubudgie.radio.Daemon")]
interface RadioDaemonProxy : Object {
    public abstract void stop_playback() throws Error;
    public abstract void play_station_direct(
        string name,
        string url,
        string favicon,
        string codec,
        int bitrate,
        string country
    ) throws Error;
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(
        typeof(Budgie.RavenPlugin),
        typeof(BudgieRadio.RadioPlugin)
    );
}
