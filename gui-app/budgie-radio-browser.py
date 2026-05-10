#!/usr/bin/env python3
"""
budgie-radio-browser.py

GUI application for browsing and searching radio stations.
Sends playback commands to the radio daemon via D-Bus.

Copyright 2026 Ubuntu Budgie Developers

"""

import asyncio
import sys
import threading
import gettext
import locale
import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gio

import dbus
from dbus.mainloop.glib import DBusGMainLoop

try:
    from radios import RadioBrowser, FilterBy, Order
    HAS_RADIOS = True
except ImportError:
    HAS_RADIOS = False
    print("ERROR: 'radios' library required. Install with:")
    print("  sudo apt install python3-radios")

# Setup translations
locale.setlocale(locale.LC_ALL, '')
gettext.bindtextdomain('budgie-radio-widget', '/usr/share/locale')
gettext.textdomain('budgie-radio-widget')
_ = gettext.gettext


class StationRow(Gtk.ListBoxRow):
    """Custom row for displaying a station"""

    def __init__(self, station):
        super().__init__()
        self.station = station

        # Create layout
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        hbox.set_margin_start(10)
        hbox.set_margin_end(10)
        hbox.set_margin_top(5)
        hbox.set_margin_bottom(5)

        # Station name (bold)
        name_label = Gtk.Label(xalign=0)
        name_label.set_markup(f"<b>{GLib.markup_escape_text(station.name)}</b>")
        name_label.set_ellipsize(3)  # PANGO_ELLIPSIZE_END

        # Info label - build info parts
        info_parts = []
        if station.country:
            info_parts.append(station.country)
        if station.codec:
            info_parts.append(f"{station.codec}")
        if station.bitrate:
            # TRANSLATORS: kbps = kilobits per second, audio quality measure
            # Keep short, shown after codec like "MP3 192 kbps"
            info_parts.append(_("{bitrate}kbps").format(bitrate=station.bitrate))

        info_label = Gtk.Label(xalign=0)
        info_label.set_text(" | ".join(info_parts))
        info_label.get_style_context().add_class("dim-label")

        # Pack labels
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        vbox.pack_start(name_label, False, False, 0)
        vbox.pack_start(info_label, False, False, 0)

        hbox.pack_start(vbox, True, True, 0)

        # Play button
        play_btn = Gtk.Button.new_from_icon_name(
            "media-playback-start",
            Gtk.IconSize.BUTTON
        )
        # TRANSLATORS: Tooltip for play button next to each station in the list
        play_btn.set_tooltip_text(_("Play this station"))
        play_btn.connect("clicked", self.on_play_clicked)
        hbox.pack_end(play_btn, False, False, 0)

        self.add(hbox)
        self.show_all()

    def on_play_clicked(self, button):
        """Emit a custom signal when play is clicked"""
        # Handled in parent window
        pass


class RadioBrowserWindow(Gtk.ApplicationWindow):
    """Main browser window"""

    def __init__(self, app):
        # TRANSLATORS: Main window title for the radio station browser application
        super().__init__(application=app, title=_("Radio Browser"))
        self.set_default_size(900, 600)
        self.set_border_width(0)

        # Radio browser client
        self.radio_client = None

        # Async event loop in separate thread
        self.async_loop = None
        self.async_thread = None

        # D-Bus connection to daemon
        self.daemon_proxy = None
        self._connect_to_daemon()

        # Build UI
        self.build_ui()

        # Start async operations
        if HAS_RADIOS:
            self._start_async_loop()

    def _start_async_loop(self):
        """Start asyncio event loop in a separate thread"""
        def run_loop():
            self.async_loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.async_loop)

            # Initialize and load initial data
            async def init():
                self.radio_client = RadioBrowser(
                    user_agent="BudgieRadioBrowser/1.0"
                )
                await self.radio_client.__aenter__()
                await self.load_stations(Order.VOTES)

            self.async_loop.run_until_complete(init())
            self.async_loop.run_forever()

        self.async_thread = threading.Thread(target=run_loop, daemon=True)
        self.async_thread.start()

    def _connect_to_daemon(self):
        """Connect to the radio daemon via D-Bus"""
        try:
            bus = dbus.SessionBus()
            self.daemon_proxy = bus.get_object(
                'org.ubuntubudgie.radio',
                '/org/ubuntubudgie/radio/Daemon'
            )
        except dbus.exceptions.DBusException as e:
            print(f"Failed to connect to daemon: {e}")
            print("Make sure radio-daemon is running!")

    def build_ui(self):
        """Build the user interface"""
        # Main vertical box
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        # Header bar
        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        # TRANSLATORS: Main window title
        header.set_title(_("Radio Browser"))
        # TRANSLATORS: Window subtitle describing the application purpose
        header.set_subtitle(_("Browse internet radio stations"))

        # Pause button in header
        pause_button = Gtk.Button.new_from_icon_name(
            "media-playback-pause",
            Gtk.IconSize.BUTTON
        )
        # TRANSLATORS: Tooltip for pause button in window header
        pause_button.set_tooltip_text(_("Pause playback"))
        pause_button.connect("clicked", self.on_pause_clicked)
        self.pause_button = pause_button  # Store reference
        header.pack_end(pause_button)

        # Stop button in header
        stop_button = Gtk.Button.new_from_icon_name(
            "media-playback-stop",
            Gtk.IconSize.BUTTON
        )
        # TRANSLATORS: Tooltip for stop button in window header
        stop_button.set_tooltip_text(_("Stop playback"))
        stop_button.connect("clicked", self.on_stop_clicked)
        header.pack_end(stop_button)

        # Track playback state
        self.is_paused = False

        self.set_titlebar(header)

        # Search bar
        search_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        search_box.set_margin_start(10)
        search_box.set_margin_end(10)
        search_box.set_margin_top(10)
        search_box.set_margin_bottom(5)

        self.search_entry = Gtk.SearchEntry()
        # TRANSLATORS: Placeholder text in search box, prompts user to type station name
        self.search_entry.set_placeholder_text(_("Search stations..."))
        self.search_entry.connect("search-changed", self.on_search_changed)
        search_box.pack_start(self.search_entry, True, True, 0)

        vbox.pack_start(search_box, False, False, 0)

        # Filter buttons
        filter_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        filter_box.set_margin_start(10)
        filter_box.set_margin_end(10)
        filter_box.set_margin_bottom(10)

        filters = [
            # TRANSLATORS: Filter button - shows stations with most user votes
            (_("Top Voted"), Order.VOTES),
            # TRANSLATORS: Filter button - shows stations with most listeners/clicks
            (_("Most Popular"), Order.CLICK_COUNT),
            # TRANSLATORS: Filter button - shows stations recently updated in database
            (_("Recently Changed"), Order.CHANGE_TIMESTAMP),
        ]

        for label, order in filters:
            btn = Gtk.Button(label=label)
            btn.connect("clicked", self.on_filter_clicked, order)
            filter_box.pack_start(btn, True, True, 0)

        vbox.pack_start(filter_box, False, False, 0)

        # Station list (scrollable)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        self.station_listbox = Gtk.ListBox()
        self.station_listbox.set_selection_mode(Gtk.SelectionMode.NONE)
        self.station_listbox.connect("row-activated", self.on_station_activated)

        scrolled.add(self.station_listbox)
        vbox.pack_start(scrolled, True, True, 0)

        # Status bar
        self.status_label = Gtk.Label(xalign=0)
        self.status_label.set_margin_start(10)
        self.status_label.set_margin_end(10)
        self.status_label.set_margin_top(5)
        self.status_label.set_margin_bottom(5)
        self.status_label.get_style_context().add_class("dim-label")
        # TRANSLATORS: Initial status message shown while application loads
        self.status_label.set_text(_("Loading..."))
        vbox.pack_end(self.status_label, False, False, 0)

        self.add(vbox)
        self.show_all()

    async def load_stations(self, order=Order.VOTES, filter_by=None, filter_term=None):
        """Load stations from API (runs in async thread)"""
        # TRANSLATORS: Status message shown while fetching station list from internet
        GLib.idle_add(self.status_label.set_text, _("Loading stations..."))

        try:
            kwargs = {
                'limit': 100,
                'order': order,
                'reverse': True,
            }

            if filter_by and filter_term:
                kwargs['filter_by'] = filter_by
                kwargs['filter_term'] = filter_term

            stations = await self.radio_client.stations(**kwargs)

            # Update UI on main thread
            GLib.idle_add(self.populate_stations, stations)

        except Exception as e:
            # TRANSLATORS: Error message when station list fails to load
            # {error} is the technical error message
            error_msg = _("Error loading stations: {error}").format(error=str(e))
            GLib.idle_add(self.status_label.set_text, error_msg)

    def populate_stations(self, stations):
        """Populate the station list (called on main thread)"""
        # Clear existing rows
        for child in self.station_listbox.get_children():
            self.station_listbox.remove(child)

        # Add new rows
        for station in stations:
            row = StationRow(station)
            # Connect play button
            play_btn = row.get_child().get_children()[1]
            play_btn.connect("clicked", self.on_play_station, station)
            self.station_listbox.add(row)

        # TRANSLATORS: Status message showing number of stations in list
        # {count} is the number of stations found/displayed
        status_msg = _("Showing {count} stations").format(count=len(stations))
        self.status_label.set_text(status_msg)
        self.station_listbox.show_all()

    def on_station_activated(self, listbox, row):
        """Handle row activation (double-click or Enter)"""
        if isinstance(row, StationRow):
            self.play_station(row.station)

    def on_play_station(self, button, station):
        """Handle play button click"""
        self.play_station(station)

    def play_station(self, station):
        """Send play command to daemon"""
        if not self.daemon_proxy:
            print("Daemon not connected!")
            return

        try:
            # Call daemon via D-Bus
            self.daemon_proxy.PlayStation(
                station.uuid,  # Use uuid, not id
                dbus_interface='org.ubuntubudgie.radio.Daemon'
            )

            # TRANSLATORS: Status message when station starts playing
            # {station} is the name of the radio station
            status_msg = _("Now playing: {station}").format(station=station.name)
            self.status_label.set_text(status_msg)

        except dbus.exceptions.DBusException as e:
            print(f"Failed to play station: {e}")
            # TRANSLATORS: Error message when playback fails to start
            self.status_label.set_text(_("Error: Failed to play station"))

    def on_search_changed(self, entry):
        """Handle search input"""
        query = entry.get_text().strip()

        if len(query) >= 3 and self.async_loop:
            # Submit search task to async loop
            asyncio.run_coroutine_threadsafe(
                self.load_stations(
                    order=Order.VOTES,
                    filter_by=FilterBy.NAME,
                    filter_term=query
                ),
                self.async_loop
            )
        elif len(query) == 0 and self.async_loop:
            # Reset to top voted
            asyncio.run_coroutine_threadsafe(
                self.load_stations(Order.VOTES),
                self.async_loop
            )

    def on_filter_clicked(self, button, order):
        """Handle filter button click"""
        if self.async_loop:
            asyncio.run_coroutine_threadsafe(
                self.load_stations(order=order),
                self.async_loop
            )

    def on_pause_clicked(self, button):
        """Handle pause/resume button click"""
        if not self.daemon_proxy:
            print("Daemon not connected!")
            return

        try:
            if self.is_paused:
                # Resume
                self.daemon_proxy.ResumePlayback(
                    dbus_interface='org.ubuntubudgie.radio.Daemon'
                )
                self.is_paused = False
                # TRANSLATORS: Tooltip for pause button when playback can be paused
                self.pause_button.set_tooltip_text(_("Pause playback"))
            else:
                # Pause
                self.daemon_proxy.PausePlayback(
                    dbus_interface='org.ubuntubudgie.radio.Daemon'
                )
                self.is_paused = True
                # TRANSLATORS: Tooltip for pause button when playback is paused (to resume)
                self.pause_button.set_tooltip_text(_("Resume playback"))
                # TRANSLATORS: Status message when playback is paused
                self.status_label.set_text(_("Playback paused"))
        except dbus.exceptions.DBusException as e:
            print(f"Failed to pause/resume: {e}")

    def on_stop_clicked(self, button):
        """Handle stop button click"""
        if not self.daemon_proxy:
            print("Daemon not connected!")
            return

        try:
            self.daemon_proxy.StopPlayback(
                dbus_interface='org.ubuntubudgie.radio.Daemon'
            )
            # TRANSLATORS: Status message when playback is stopped
            self.status_label.set_text(_("Playback stopped"))
            self.is_paused = False
        except dbus.exceptions.DBusException as e:
            print(f"Failed to stop playback: {e}")


class RadioBrowserApp(Gtk.Application):
    """Application wrapper"""

    def __init__(self):
        super().__init__(
            application_id='com.budgie.RadioBrowser',
            flags=Gio.ApplicationFlags.FLAGS_NONE
        )

    def do_activate(self):
        """Application activation"""
        window = RadioBrowserWindow(self)
        window.present()


def main():
    """Main entry point"""
    if not HAS_RADIOS:
        sys.exit(1)

    # Setup D-Bus
    DBusGMainLoop(set_as_default=True)

    # Run app
    app = RadioBrowserApp()
    exit_code = app.run(sys.argv)

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
