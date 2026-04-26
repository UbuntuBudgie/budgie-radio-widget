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
		private Gtk.Box favorites_box;
		private Gtk.Button[] preset_buttons;
		private string current_playing_uuid = "";
		private Gtk.MenuButton favorites_menu_button;

		private GLib.DBusConnection? bus_connection;
		private uint now_playing_subscription = 0;
		private uint playback_stopped_subscription = 0;

		private bool is_playing = false;
		private GLib.Settings settings;

		public RadioWidget(string uuid, GLib.Settings? settings) {
			warning("RadioWidget constructor starting...\n");  // Debug

			initialize(uuid, settings);

			// Initialize our settings
			this.settings = new GLib.Settings("org.ubuntubudgie.plugins.radio-browser");

			// Main container
			var main_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
			add(main_box);

			warning("Building header...\n");  // Debug
			// Build header (similar to wallpaper switcher example)
			build_header();
			main_box.pack_start(header_box, false, false, 0);

			warning("Building content...\n");  // Debug
			// Build content area
			build_content();
			main_box.pack_start(content_box, false, false, 0);

			warning("Setting up D-Bus...\n");  // Debug
			// Connect to D-Bus
			setup_dbus();

			warning("Loading presets...\n");  // Debug
			// THEN load presets (needs D-Bus)
			load_all_presets();

			warning("Loading last station...\n");  // Debug
			// Load last station from GSettings
			load_last_station();

			warning("Showing all widgets...\n");  // Debug
			show_all();
			update_visibility();

			warning("RadioWidget constructor complete.\n");  // Debug
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

			// Station name label with menu button for favorites
			var station_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 5);

			station_label = new Gtk.Label("No station playing");
			station_label.get_style_context().add_class("h3");
			station_label.halign = Gtk.Align.START;
			station_label.wrap = true;
			station_label.max_width_chars = 25;
			station_box.pack_start(station_label, true, true, 0);

			// Menu button for adding to favorites
			var menu_button = new Gtk.MenuButton();
			menu_button.set_image(new Gtk.Image.from_icon_name("list-add-symbolic", Gtk.IconSize.BUTTON));
			menu_button.set_tooltip_text("Add to presets");
			menu_button.get_style_context().add_class("flat");
			menu_button.valign = Gtk.Align.CENTER;
			menu_button.set_sensitive(false);  // Disabled until playing

			// Create popover with preset options
			var popover = new Gtk.Popover(menu_button);
			var popover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

			for (int i = 1; i <= 5; i++) {
				var button = new Gtk.ModelButton();
				button.text = @"Set as Preset $i";
				int preset = i;  // Capture for closure
				button.clicked.connect(() => {
					set_current_as_favorite(preset);
					popover.popdown();
				});
				popover_box.pack_start(button, false, false, 0);
			}

			popover_box.show_all();
			popover.add(popover_box);
			menu_button.set_popover(popover);

			station_box.pack_end(menu_button, false, false, 0);
			content_box.pack_start(station_box, false, false, 2);

			// Store reference to enable/disable when playback state changes
			this.favorites_menu_button = menu_button;

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

			// Favorites section
			var favorites_label = new Gtk.Label("Presets");
			favorites_label.halign = Gtk.Align.START;
			favorites_label.get_style_context().add_class("dim-label");
			var attr_list_fav = new Pango.AttrList();
			attr_list_fav.insert(Pango.attr_scale_new(0.85));
			favorites_label.set_attributes(attr_list_fav);
			content_box.pack_start(favorites_label, false, false, 2);

			// Preset buttons container
			favorites_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 5);
			favorites_box.halign = Gtk.Align.CENTER;

			warning("Creating preset buttons...\n");  // Debug

			// Create 5 preset buttons
			preset_buttons = new Gtk.Button[5];
			for (int i = 0; i < 5; i++) {
				preset_buttons[i] = create_preset_button(i + 1);
				preset_buttons[i].show();  // Explicitly show each button
				favorites_box.pack_start(preset_buttons[i], true, true, 0);
				warning(@"Created and packed preset button $(i+1)\n");  // Debug line
			}

			favorites_box.show();  // Explicitly show the container
			content_box.pack_start(favorites_box, false, false, 5);
			warning("Favorites box added to content\n");  // Debug

			// Separator
			var separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
			content_box.pack_start(separator, false, false, 5);

			// Browse button
			browse_button = new Gtk.Button.with_label("Browse Stations");
			browse_button.get_style_context().add_class("suggested-action");
			browse_button.clicked.connect(on_browse_clicked);
			content_box.pack_start(browse_button, false, false, 5);
		}

		private Gtk.Button create_preset_button(int preset_num) {
			var button = new Gtk.Button.with_label(preset_num.to_string());
			button.set_size_request(40, 28);
			button.get_style_context().add_class("flat");

			// We'll load the preset info after D-Bus is connected
			// For now, just set it as empty
			button.set_tooltip_text("Click + button to assign");  // Fix 1 included here
			button.get_style_context().add_class("dim-label");
			button.set_sensitive(false);

			// Click handler - play the station
			button.clicked.connect(() => {
				on_preset_clicked(preset_num);
			});

			return button;
		}

		private void load_all_presets() {
			warning("load_all_presets() called\n");  // Debug

			if (preset_buttons == null) {
				warning("ERROR: preset_buttons is null!\n");
				return;
			}

			// Load all 5 preset buttons with their saved stations
			for (int i = 0; i < 5; i++) {
				int preset_num = i + 1;
				string uuid = settings.get_string(@"favorite-$preset_num-uuid");

				warning(@"Preset $preset_num UUID: '$uuid'\n");  // Debug

				if (uuid != "") {
					load_preset_info(preset_buttons[i], preset_num, uuid);
				}
			}
		}

		private void load_preset_info(Gtk.Button button, int preset_num, string uuid) {
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);

				var info = proxy.get_station_info(uuid);

				if (info.length > 0) {
					string name = info.contains("name") ? info["name"].get_string() : "Unknown";
					string country = info.contains("country") ? info["country"].get_string() : "";
					string codec = info.contains("codec") ? info["codec"].get_string() : "";
					int bitrate = info.contains("bitrate") ? (int)info["bitrate"].get_int32() : 0;

					// Build tooltip
					var tooltip_parts = new StringBuilder();
					tooltip_parts.append(name);
					if (country != "") {
						tooltip_parts.append(@"\n$country");
					}
					if (codec != "" && bitrate > 0) {
						tooltip_parts.append(@"\n$codec @ $bitrate kbps");
					}

					button.set_tooltip_markup(tooltip_parts.str);
					button.set_sensitive(true);
					button.get_style_context().remove_class("dim-label");

					// Highlight if currently playing
					if (uuid == current_playing_uuid) {
						button.get_style_context().add_class("suggested-action");
					}
				} else {
					// Station info not available
					button.set_tooltip_text("Station unavailable");
					button.set_sensitive(false);
				}

			} catch (Error e) {
				warning("Failed to load preset info: %s", e.message);
				button.set_tooltip_text("Error loading station");
				button.set_sensitive(false);
			}
		}

		private void on_preset_clicked(int preset_num) {
			string uuid = settings.get_string(@"favorite-$preset_num-uuid");

			if (uuid == "") {
				return;
			}

			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);
				proxy.play_station(uuid);
			} catch (Error e) {
				warning("Failed to play preset %d: %s", preset_num, e.message);
			}
		}

		private void set_current_as_favorite(int preset_num) {
			if (!is_playing) {
				return;
			}

			// Get current station UUID from daemon
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);
				string uuid = proxy.get_current_station_uuid();

				print(@"Got UUID from daemon: '$uuid'\n");  // Debug

				if (uuid != "") {
					// Save to settings
					settings.set_string(@"favorite-$preset_num-uuid", uuid);

					print(@"Saved UUID '$uuid' to preset $preset_num\n");  // Debug

					// Reload the preset button
					var button = preset_buttons[preset_num - 1];
					load_preset_info(button, preset_num, uuid);
				} else {
					print("UUID is empty, not saving\n");  // Debug
				}
			} catch (Error e) {
				warning("Failed to set favorite: %s", e.message);
			}
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
			update_preset_highlights();

			// Load icon asynchronously
			if (icon_url != "") {
				load_icon_async(icon_url);
			}

			// Enable favorites menu when playing
			favorites_menu_button.set_sensitive(true);
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
			current_playing_uuid = "";
			station_label.set_text("No station playing");
			track_label.set_text("");
			codec_label.set_text("");
			station_icon.set_from_icon_name("audio-x-generic", Gtk.IconSize.MENU);

			update_visibility();
			update_preset_highlights();

			// Disable favorites menu when stopped
			favorites_menu_button.set_sensitive(false);
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

		private void update_preset_highlights() {
			// Get currently playing station UUID from daemon
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);
				current_playing_uuid = proxy.get_current_station_uuid();
			} catch (Error e) {
				current_playing_uuid = "";
			}

			// Update all preset buttons
			for (int i = 0; i < 5; i++) {
				string uuid = settings.get_string(@"favorite-$(i+1)-uuid");

				if (uuid == current_playing_uuid && current_playing_uuid != "") {
					preset_buttons[i].get_style_context().add_class("suggested-action");
				} else {
					preset_buttons[i].get_style_context().remove_class("suggested-action");
				}
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
	[DBus (name = "StopPlayback")]
	public abstract void stop_playback() throws Error;

	[DBus (name = "PlayStation")]
	public abstract void play_station(string uuid) throws Error;

	[DBus (name = "PlayStationDirect")]
	public abstract void play_station_direct(
		string name,
		string url,
		string favicon,
		string codec,
		int bitrate,
		string country
	) throws Error;

	[DBus (name = "GetStationInfo")]
	public abstract HashTable<string, Variant> get_station_info(string uuid) throws Error;

	[DBus (name = "GetCurrentStationUUID")]
	public abstract string get_current_station_uuid() throws Error;
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
	var objmodule = module as Peas.ObjectModule;
	objmodule.register_extension_type(
		typeof(Budgie.RavenPlugin),
		typeof(BudgieRadio.RadioPlugin)
	);
}
