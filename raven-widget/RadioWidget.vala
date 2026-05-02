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
		private Gtk.Box scrub_overlay;
		private Gtk.Revealer scrub_revealer;
		private Gtk.Scale scrub_scale;
		private Gtk.Label buffer_label;
		private Gtk.EventBox track_eventbox;
		private bool scrub_overlay_visible = false;
		private Gtk.Button browse_button;
		private Gtk.Button toggle_button;
		private Gtk.Button pause_button;
		private Gtk.Image play_icon;
		private Gtk.Image pause_icon;
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
		private uint playback_paused_subscription = 0;

		private bool is_playing = false;
		private bool is_paused = false;
		private GLib.Settings settings;
		private bool updating_scrubber = false;
		private uint scrubber_update_timeout = 0;
		private uint paused_update_timeout = 0;

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

			// THEN load presets (needs D-Bus)
			load_all_presets();

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

			// Pause button
			pause_icon = new Gtk.Image.from_icon_name(
				"media-playback-pause-symbolic",
				Gtk.IconSize.MENU
			);
 			play_icon = new Gtk.Image.from_icon_name(
 				"media-playback-start-symbolic",
 				Gtk.IconSize.MENU
 			);

			pause_button = new Gtk.Button();
			pause_button.set_image(pause_icon);
			pause_button.set_tooltip_text("Pause playback");
			pause_button.get_style_context().add_class("flat");
			pause_button.get_style_context().add_class("expander-button");
			pause_button.margin = 4;
			pause_button.valign = Gtk.Align.CENTER;
			pause_button.clicked.connect(on_pause_clicked);
			pause_button.set_sensitive(false);  // Disabled until playing
			header_box.pack_end(pause_button, false, false, 0);

			// Toggle button (play/stop combined)
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

			// Track info area with hover-activated scrubber overlay
			var track_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

			track_label = new Gtk.Label("");
			track_label.halign = Gtk.Align.START;
			track_label.wrap = true;
			track_label.max_width_chars = 30;
			track_label.get_style_context().add_class("dim-label");
			track_container.pack_start(track_label, false, false, 0);

			// Scrub overlay in a revealer (revealed on hover when playing or paused)
			scrub_revealer = new Gtk.Revealer();
			scrub_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN);
			scrub_revealer.set_transition_duration(200);

			scrub_overlay = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
			scrub_overlay.valign = Gtk.Align.CENTER;
			scrub_overlay.margin_top = 5;

			var scrub_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 5);

			// Back 15s button
			var back_btn = new Gtk.Button.with_label("◄◄15s");
			back_btn.get_style_context().add_class("flat");
			back_btn.clicked.connect(() => seek_relative(-15));
			scrub_box.pack_start(back_btn, false, false, 0);

			// Seekbar
			scrub_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 3600, 1);
			scrub_scale.set_draw_value(false);
			scrub_scale.value_changed.connect(on_scrub_value_changed);
			scrub_box.pack_start(scrub_scale, true, true, 0);

			// Forward 15s button
			var fwd_btn = new Gtk.Button.with_label("►►15s");
			fwd_btn.get_style_context().add_class("flat");
			fwd_btn.clicked.connect(() => seek_relative(15));
			scrub_box.pack_start(fwd_btn, false, false, 0);

			// Live button
			var live_btn = new Gtk.Button.with_label("Live");
			live_btn.get_style_context().add_class("suggested-action");
			live_btn.clicked.connect(seek_to_live);
			scrub_box.pack_start(live_btn, false, false, 0);

			scrub_overlay.pack_start(scrub_box, false, false, 0);

			// Buffer info label
			buffer_label = new Gtk.Label("");
			buffer_label.halign = Gtk.Align.START;
			buffer_label.get_style_context().add_class("dim-label");
			var attr_list_buf = new Pango.AttrList();
			attr_list_buf.insert(Pango.attr_scale_new(0.85));
			buffer_label.set_attributes(attr_list_buf);
			scrub_overlay.pack_start(buffer_label, false, false, 0);

			scrub_revealer.add(scrub_overlay);
			track_container.pack_start(scrub_revealer, false, false, 0);

			// Wrap in EventBox for hover detection
			track_eventbox = new Gtk.EventBox();
			track_eventbox.add(track_container);

			// Set events to track pointer motion properly
			track_eventbox.set_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
									  Gdk.EventMask.LEAVE_NOTIFY_MASK);
			track_eventbox.enter_notify_event.connect(on_track_area_enter);
			track_eventbox.leave_notify_event.connect(on_track_area_leave);

			content_box.pack_start(track_eventbox, false, false, 2);

			// Show all widgets (revealer will control visibility)
			scrub_overlay.show_all();

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

			// Create 5 preset buttons
			preset_buttons = new Gtk.Button[5];
			for (int i = 0; i < 5; i++) {
				preset_buttons[i] = create_preset_button(i + 1);
				preset_buttons[i].show();  // Explicitly show each button
				favorites_box.pack_start(preset_buttons[i], true, true, 0);
			}

			favorites_box.show();  // Explicitly show the container
			content_box.pack_start(favorites_box, false, false, 5);

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
			if (preset_buttons == null) {
				return;
			}

			// Load all 5 preset buttons with their saved stations
			for (int i = 0; i < 5; i++) {
				int preset_num = i + 1;
				string uuid = settings.get_string(@"favorite-$preset_num-uuid");

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

				// Subscribe to PlaybackPaused signal
				playback_paused_subscription = bus_connection.signal_subscribe(
					"org.ubuntubudgie.radio",
					"org.ubuntubudgie.radio.Daemon",
					"PlaybackPaused",
					"/org/ubuntubudgie/radio/Daemon",
					null,
					GLib.DBusSignalFlags.NONE,
					on_playback_paused_signal
				);

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

				// Subscribe to PlaybackPaused signal
				playback_paused_subscription = bus_connection.signal_subscribe(
					"org.ubuntubudgie.radio",
					"org.ubuntubudgie.radio.Daemon",
					"PlaybackPaused",
					"/org/ubuntubudgie/radio/Daemon",
					null,
					GLib.DBusSignalFlags.NONE,
					on_playback_paused_signal
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
			is_paused = false;
			station_label.set_text(station_name);
			track_label.set_text(track_info);
			codec_label.set_text(@"$codec $bitrate kbps");

			update_visibility();
			update_preset_highlights();

			// Load icon asynchronously
			if (icon_url != "") {
				load_icon_async(icon_url);
			}

			// Enable favorites menu only if we have a valid UUID
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);
				string uuid = proxy.get_current_station_uuid();

				// Only enable if UUID is not empty and not "direct"
				bool has_valid_uuid = (uuid != "" && uuid != "direct");
				favorites_menu_button.set_sensitive(has_valid_uuid);

				if (has_valid_uuid) {
					favorites_menu_button.set_tooltip_text("Add to presets");
				} else {
					favorites_menu_button.set_tooltip_text("Play from browser to add to presets");
				}

				print(@"UUID: '$uuid', menu enabled: $has_valid_uuid\n");  // Debug
			} catch (Error e) {
				warning("Failed to get UUID: %s", e.message);
				favorites_menu_button.set_sensitive(false);
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
			is_paused = false;

			if (paused_update_timeout > 0) {
				GLib.Source.remove(paused_update_timeout);
				paused_update_timeout = 0;
			}

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

		private void on_playback_paused_signal(
			GLib.DBusConnection connection,
			string? sender_name,
			string object_path,
			string interface_name,
			string signal_name,
			Variant parameters
		) {
			// Update UI for paused state
			is_paused = true;
			// Start a repeating update so "behind live" keeps ticking
			if (paused_update_timeout == 0) {
				paused_update_timeout = GLib.Timeout.add(1000, update_paused_label);
			}

			update_paused_label();
			update_visibility();
		}

		private bool update_paused_label() {
			// Stop if we've resumed or stopped
			if (!is_paused) {
				paused_update_timeout = 0;
				return false;
			}

			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);
				int64 behind = proxy.get_time_behind_live();
				if (behind > 0) {
					track_label.set_text(@"⏸ Paused • $(format_time(behind)) behind live");
				} else {
					track_label.set_text("⏸ Paused • LIVE");
				}
			} catch (Error e) {
				track_label.set_text("⏸ Paused");
				paused_update_timeout = 0;
				return false;
			}

			return true; // Keep repeating every second
		}

		private bool on_track_area_enter(Gdk.EventCrossing event) {
			// Ignore if already showing or if no playback
			if (scrub_overlay_visible || (!is_playing && !is_paused)) {
				return false;
			}

			// Show scrubber if we're playing OR paused (anytime there's buffer)
			scrub_overlay_visible = true;
			scrub_revealer.set_reveal_child(true);
			update_buffer_info();

			// Start periodic updates while hovering
			if (scrubber_update_timeout == 0) {
				scrubber_update_timeout = GLib.Timeout.add(500, update_scrubber_position);
			}
			return false;
		}

		private bool on_track_area_leave(Gdk.EventCrossing event) {
			// Only hide if actually leaving to outside the widget
			// Check if we're entering a child widget
			if (event.detail == Gdk.NotifyType.INFERIOR) {
				return false;  // Ignore - we're just moving to a child widget
			}

			// Ignore if already hidden
			if (!scrub_overlay_visible) {
				return false;
			}

			scrub_overlay_visible = false;
			scrub_revealer.set_reveal_child(false);

			// Stop periodic updates
			if (scrubber_update_timeout > 0) {
				GLib.Source.remove(scrubber_update_timeout);
				scrubber_update_timeout = 0;
			}

			return false;
		}

		private bool update_scrubber_position() {
			// Only update while scrubber is visible
			if (!scrub_overlay_visible) {
				return false;  // Stop the timer
			}

			update_buffer_info();
			return true;  // Continue updating
		}

		private string format_time(int64 seconds) {
			int mins = (int)(seconds / 60);
			int secs = (int)(seconds % 60);
			return @"$(mins):$(secs.to_string().printf("%02d"))";
		}

		private void update_buffer_info() {
			if (!is_playing && !is_paused) {
				return;
			}

			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);

				int64 buffer_duration = proxy.get_buffer_duration();
				int64 current_pos = proxy.get_current_position();
				int64 behind_live = proxy.get_time_behind_live();

				// Update scale range
				updating_scrubber = true;  // Block value_changed signal
				scrub_scale.set_range(0, buffer_duration);
				scrub_scale.set_value(current_pos);
				updating_scrubber = false;

				// Show buffer info
				string status = is_paused ? "⏸ Paused" : "▶ Playing";
				string live_status;
				if (behind_live > 0) {
					live_status = @"$(format_time(behind_live)) behind live";
				} else {
					live_status = "● LIVE";
				}
				buffer_label.set_text(@"$status • $live_status • Buffer: $(format_time(buffer_duration))");
			} catch (Error e) {
				warning("Failed to get buffer info: %s", e.message);
			}
		}

		private void seek_relative(int seconds) {
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);
				proxy.seek_relative((int64)seconds);

				// Update UI after a short delay
				GLib.Timeout.add(100, () => {
					update_buffer_info();
					return false;
				});
			} catch (Error e) {
				warning("Failed to seek: %s", e.message);
			}
		}

		private void on_scrub_value_changed() {
			// Ignore programmatic updates
			if (updating_scrubber) {
				return;
			}

			// Seek to absolute position in buffer
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);

				int64 current_pos = proxy.get_current_position();
				int64 target_pos = (int64)scrub_scale.get_value();
				int64 offset = target_pos - current_pos;

				proxy.seek_relative(offset);
			} catch (Error e) {
				warning("Failed to scrub: %s", e.message);
			}
		}

		private void seek_to_live() {
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);

				proxy.seek_to_live();
			} catch (Error e) {
				warning("Failed to seek to live: %s", e.message);
			}
		}

 		private void update_visibility() {
			// Update toggle button and pause button based on playback state
			if (is_playing && !is_paused) {
				// Playing state
 				toggle_button.set_image(stop_icon);
 				toggle_button.set_tooltip_text("Stop playback");
				pause_button.set_image(pause_icon);
				pause_button.set_tooltip_text("Pause playback");
				pause_button.set_sensitive(true);
 				station_icon.get_style_context().remove_class("dim-label");
			} else if (is_paused) {
				// Paused state
				toggle_button.set_image(stop_icon);
				toggle_button.set_tooltip_text("Stop playback");
				pause_button.set_image(play_icon);
				pause_button.set_tooltip_text("Resume playback");
				pause_button.set_sensitive(true);
				station_icon.get_style_context().add_class("dim-label");
 			} else {
				// Stopped state
 				toggle_button.set_image(play_icon);
 				toggle_button.set_tooltip_text("Play last station");
				pause_button.set_sensitive(false);
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

		private void on_pause_clicked() {
			try {
				var proxy = bus_connection.get_proxy_sync<RadioDaemonProxy>(
					"org.ubuntubudgie.radio",
					"/org/ubuntubudgie/radio/Daemon"
				);

				if (is_paused) {
					// Resume playback
					proxy.resume_playback();
				} else {
					// Pause playback
					proxy.pause_playback();
				}
			} catch (Error e) {
				warning("Failed to pause/resume: %s", e.message);
			}
		}

		private void on_toggle_clicked() {
			if (is_playing) {
				// Stop playback (works whether playing or paused)
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
			// Note: This just displays info, doesn't auto-play
 			string name = settings.get_string("last-station-name");
			string favicon = settings.get_string("last-station-favicon");
 			string codec = settings.get_string("last-station-codec");
 			int bitrate = settings.get_int("last-station-bitrate");

			if (name != "") {
				station_label.set_text(name);
				codec_label.set_text(@"$codec $bitrate kbps");

				if (favicon != "") {
					load_icon_async(favicon);
				}
			}

			// Ensure menu button stays disabled (no UUID yet)
			favorites_menu_button.set_sensitive(false);
			favorites_menu_button.set_tooltip_text("Play from browser to add to presets");
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
				if (playback_paused_subscription != 0) {
					bus_connection.signal_unsubscribe(playback_paused_subscription);
				}
			}

			// Clean up timeout
			if (paused_update_timeout > 0) {
				GLib.Source.remove(paused_update_timeout);
				paused_update_timeout = 0;
			}
			if (scrubber_update_timeout > 0) {
				GLib.Source.remove(scrubber_update_timeout);
				scrubber_update_timeout = 0;
			}
		}
	}
}

// D-Bus proxy interface for calling daemon methods
[DBus (name = "org.ubuntubudgie.radio.Daemon")]
interface RadioDaemonProxy : Object {
	[DBus (name = "StopPlayback")]
	public abstract void stop_playback() throws Error;

	[DBus (name = "PausePlayback")]
	public abstract void pause_playback() throws Error;

	[DBus (name = "ResumePlayback")]
	public abstract void resume_playback() throws Error;

	[DBus (name = "SeekRelative")]
	public abstract void seek_relative(int64 offset_seconds) throws Error;

	[DBus (name = "GetBufferDuration")]
	public abstract int64 get_buffer_duration() throws Error;

	[DBus (name = "GetCurrentPosition")]
	public abstract int64 get_current_position() throws Error;

	[DBus (name = "GetTimeBehindLive")]
	public abstract int64 get_time_behind_live() throws Error;

	[DBus (name = "SeekToLive")]
	public abstract void seek_to_live() throws Error;

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
