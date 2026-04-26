#!/usr/bin/env python3
"""
radio-daemon.py

D-Bus service that manages radio playback state.
Emits signals when station/track changes for the Raven widget to display.
Receives commands from the GUI browser app.

Copyright 2026 Ubuntu Budgie Developers
"""

import sys
import signal
import threading
import asyncio
from typing import Optional

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib, Gst, Gio

try:
    from radios import RadioBrowser
    HAS_RADIOS = True
except ImportError:
    HAS_RADIOS = False
    print("Warning: 'radios' library not found.")
    print("Install with: sudo apt install python3-radios")


class RadioStation:
    """Simple station data class"""
    def __init__(self, uuid, name, url, favicon, codec, bitrate, country):
        self.uuid = uuid
        self.name = name
        self.url = url
        self.favicon = favicon
        self.codec = codec
        self.bitrate = bitrate
        self.country = country


class RadioDaemon(dbus.service.Object):
    """
    D-Bus service for radio playback management.

    Interface: org.ubuntubudgie.radio.Daemon
    Object Path: /org/ubuntubudgie/radio/Daemon
    """

    INTERFACE = 'org.ubuntubudgie.radio.Daemon'
    OBJECT_PATH = '/org/ubuntubudgie/radio/Daemon'
    BUS_NAME = 'org.ubuntubudgie.radio'

    def __init__(self):
        # Initialize D-Bus
        bus_name = dbus.service.BusName(
            self.BUS_NAME,
            bus=dbus.SessionBus()
        )
        super().__init__(bus_name, self.OBJECT_PATH)

        # State
        self.current_station: Optional[RadioStation] = None
        self.radio_client = None
        self.player = None

        # GSettings for saving last station
        self.settings = Gio.Settings.new("org.ubuntubudgie.plugins.radio-browser")

        # Async event loop in separate thread
        self.async_loop = None
        self.async_thread = None

        # Initialize GStreamer
        Gst.init(None)
        self._setup_player()

        # Start async event loop in separate thread
        if HAS_RADIOS:
            self._start_async_loop()

        print(f"Radio daemon started on {self.OBJECT_PATH}")

    def _start_async_loop(self):
        """Start asyncio event loop in a separate thread"""
        def run_loop():
            self.async_loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.async_loop)

            # Initialize radio client
            async def init():
                self.radio_client = RadioBrowser(
                    user_agent="BudgieRadioWidget/1.0"
                )
                await self.radio_client.__aenter__()
                print("Radio Browser API client initialized")

            self.async_loop.run_until_complete(init())
            self.async_loop.run_forever()

        self.async_thread = threading.Thread(target=run_loop, daemon=True)
        self.async_thread.start()

    def _setup_player(self):
        """Initialize GStreamer playbin"""
        self.player = Gst.ElementFactory.make("playbin", "player")

        # Connect to bus for tag messages
        bus = self.player.get_bus()
        bus.add_signal_watch()
        bus.connect("message::tag", self._on_tag_message)
        bus.connect("message::error", self._on_error_message)

    # D-Bus Methods (called by GUI app)

    @dbus.service.method(INTERFACE, in_signature='s', out_signature='')
    def PlayStation(self, station_uuid):
        """
        Play a station by UUID.
        Called by the GUI browser app.
        """
        print(f"PlayStation called with UUID: {station_uuid}")

        if HAS_RADIOS and self.radio_client and self.async_loop:
            # Submit async task to the event loop
            asyncio.run_coroutine_threadsafe(
                self._play_station_async(station_uuid),
                self.async_loop
            )
        else:
            print("Cannot play station - radios library not available")

    @dbus.service.method(INTERFACE, in_signature='sssssi', out_signature='')
    def PlayStationDirect(self, name, url, favicon, codec, bitrate, country):
        """
        Play a station with provided details (no API lookup needed).
        Useful for testing or when radio_client is unavailable.
        """
        print(f"PlayStationDirect: {name}")

        station = RadioStation(
            uuid="direct",
            name=name,
            url=url,
            favicon=favicon,
            codec=codec,
            bitrate=bitrate,
            country=country
        )

        # Schedule on GLib main loop
        GLib.idle_add(self._start_playback, station)

    @dbus.service.method(INTERFACE, out_signature='')
    def StopPlayback(self):
        """Stop current playback"""
        print("StopPlayback called")

        if self.player:
            self.player.set_state(Gst.State.NULL)

        self.current_station = None
        self.PlaybackStopped()

    @dbus.service.method(INTERFACE, out_signature='s')
    def GetCurrentStation(self):
        """Return current station name or empty string"""
        if self.current_station:
            return self.current_station.name
        return ""

    @dbus.service.method(INTERFACE, out_signature='s')
    def GetCurrentStationUUID(self):
        """Return current station UUID or empty string"""
        if self.current_station:
            return self.current_station.uuid
        return ""

    @dbus.service.method(INTERFACE, out_signature='a{sv}')
    def GetLastStation(self):
        """Return last played station details from GSettings"""
        station_dict = {
            'name': self.settings.get_string("last-station-name"),
            'url': self.settings.get_string("last-station-url"),
            'favicon': self.settings.get_string("last-station-favicon"),
            'codec': self.settings.get_string("last-station-codec"),
            'bitrate': self.settings.get_int("last-station-bitrate"),
            'country': self.settings.get_string("last-station-country"),
        }
        return station_dict

    @dbus.service.method(INTERFACE, in_signature='s', out_signature='a{sv}')
    def GetStationInfo(self, station_uuid):
        """
        Get station details by UUID without playing.
        Used by Raven widget to populate favorite button tooltips.

        Returns empty dict if station not found or radios library unavailable.
        """
        if not station_uuid:
            return {}

        if HAS_RADIOS and self.radio_client and self.async_loop:
            # Create a future to get the result from async
            future = asyncio.run_coroutine_threadsafe(
                self._get_station_info_async(station_uuid),
                self.async_loop
            )

            try:
                # Wait for result (with timeout)
                station_dict = future.result(timeout=5.0)
                return station_dict
            except Exception as e:
                print(f"Error getting station info: {e}")
                return {}
        else:
            return {}

    # D-Bus Signals (emitted to Raven widget)

    @dbus.service.signal(INTERFACE, signature='ssssi')
    def NowPlaying(self, station_name, track_info, icon_url, codec, bitrate):
        """
        Emitted when station or track changes.

        Parameters:
        - station_name: Station name
        - track_info: Current track (from stream metadata)
        - icon_url: URL to station icon/favicon
        - codec: Audio codec (MP3, AAC, etc.)
        - bitrate: Bitrate in kbps
        """
        pass

    @dbus.service.signal(INTERFACE)
    def PlaybackStopped(self):
        """Emitted when playback stops"""
        pass

    # Internal async methods

    async def _play_station_async(self, station_uuid):
        """Fetch station details from API and start playback"""
        try:
            # Fetch station details
            station_data = await self.radio_client.station(uuid=station_uuid)

            # Convert to our station object
            station = RadioStation(
                uuid=station_data.uuid,  # Use uuid, not id
                name=station_data.name,
                url=station_data.url_resolved or station_data.url,
                favicon=station_data.favicon or "",
                codec=station_data.codec,
                bitrate=station_data.bitrate,
                country=station_data.country
            )

            # Start playback on GLib main thread
            GLib.idle_add(self._start_playback, station)

            # Register click with radio-browser
            await self.radio_client.station_click(uuid=station_uuid)

        except Exception as e:
            print(f"Error playing station: {e}")

    async def _get_station_info_async(self, station_uuid):
        """Fetch station details from API (async)"""
        try:
            station_data = await self.radio_client.station(uuid=station_uuid)

            # Check if station_data is None or invalid
            if station_data is None:
                print(f"Station {station_uuid} not found in API")
                return {}

            # Check if required fields exist
            if not hasattr(station_data, 'uuid') or station_data.uuid is None:
                print(f"Station data missing UUID: {station_data}")
                return {}

            return {
                'uuid': station_data.uuid,
                'name': station_data.name or "Unknown Station",
                'url': station_data.url_resolved or station_data.url or "",
                'favicon': station_data.favicon or "",
                'codec': station_data.codec or "Unknown",
                'bitrate': dbus.Int32(station_data.bitrate or 0),
                'country': station_data.country or "",
            }
        except Exception as e:
            print(f"Error fetching station info for UUID {station_uuid}: {e}")
            import traceback
            traceback.print_exc()
            return {}

    def _start_playback(self, station: RadioStation):
        """Start GStreamer playback (runs on GLib main loop)"""
        print(f"Starting playback: {station.name}")
        print(f"  URL: {station.url}")
        print(f"  Codec: {station.codec} @ {station.bitrate}kbps")

        self.current_station = station

        # Save to GSettings for Raven widget to restore
        self.settings.set_string("last-station-name", station.name)
        self.settings.set_string("last-station-url", station.url)
        self.settings.set_string("last-station-favicon", station.favicon)
        self.settings.set_string("last-station-codec", station.codec)
        self.settings.set_int("last-station-bitrate", station.bitrate)
        self.settings.set_string("last-station-country", station.country)

        # Set URI and play
        self.player.set_state(Gst.State.NULL)
        self.player.set_property("uri", station.url)
        self.player.set_state(Gst.State.PLAYING)

        # Emit initial signal (no track info yet)
        self.NowPlaying(
            station.name,
            "",  # Track info will come from stream tags
            station.favicon,
            station.codec,
            station.bitrate
        )

        return False  # Don't repeat GLib.idle_add

    def _on_tag_message(self, bus, message):
        """Handle tag messages from stream (track metadata)"""
        if not self.current_station:
            return

        taglist = message.parse_tag()

        title = None
        artist = None

        # Try to extract title and artist
        success, title = taglist.get_string('title')
        if not success:
            success, title = taglist.get_string('organization')

        success, artist = taglist.get_string('artist')

        # Build track info string
        if title or artist:
            if artist and title:
                track_info = f"{artist} - {title}"
            elif title:
                track_info = title
            else:
                track_info = artist

            print(f"Track info: {track_info}")

            # Emit updated signal
            self.NowPlaying(
                self.current_station.name,
                track_info,
                self.current_station.favicon,
                self.current_station.codec,
                self.current_station.bitrate
            )

    def _on_error_message(self, bus, message):
        """Handle playback errors"""
        err, debug = message.parse_error()
        print(f"Playback error: {err.message}")
        print(f"Debug: {debug}")

        # Stop playback on error
        self.StopPlayback()

    def shutdown(self):
        """Clean shutdown"""
        if self.async_loop:
            self.async_loop.call_soon_threadsafe(self.async_loop.stop)


def main():
    """Main entry point"""
    # Setup D-Bus main loop
    DBusGMainLoop(set_as_default=True)

    # Create daemon
    daemon = RadioDaemon()

    # Setup GLib main loop
    main_loop = GLib.MainLoop()

    # Handle signals
    def signal_handler(sig, frame):
        print("\nShutting down...")
        daemon.shutdown()
        main_loop.quit()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    print("Radio daemon ready. Press Ctrl+C to exit.")

    try:
        main_loop.run()
    except KeyboardInterrupt:
        print("\nExiting...")
    finally:
        daemon.shutdown()
        sys.exit(0)


if __name__ == '__main__':
    main()
