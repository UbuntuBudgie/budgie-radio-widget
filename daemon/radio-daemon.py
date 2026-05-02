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
import tempfile
import os
from pathlib import Path
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

# Default values for missing station data
DEFAULT_STATION_NAME = "Unknown Station"
DEFAULT_CODEC = "Unknown"
DEFAULT_COUNTRY = ""
DEFAULT_FAVICON = ""
DEFAULT_URL = ""
DEFAULT_BITRATE = 0

class RadioStation:
    """Simple station data class"""
    def __init__(self, uuid, name, url, favicon, codec, bitrate, country):
        self.uuid = uuid
        # Apply defaults for None values at construction
        self.name = name or DEFAULT_STATION_NAME
        self.url = url or DEFAULT_URL
        self.favicon = favicon or DEFAULT_FAVICON
        self.codec = codec or DEFAULT_CODEC
        self.bitrate = bitrate or DEFAULT_BITRATE
        self.country = country or DEFAULT_COUNTRY


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
        self.recorder = None
        self.record_file = None
        self.record_start_time = 0
        self.max_buffer_duration = 3600  # 1 hour in seconds
        self.max_buffer_size =  200 * 1024 * 1024  # 200MB for encoded audio
        self.is_paused = False
        self.is_playing_from_buffer = False
        self.auto_resume_timeout = None
        self.buffer_switch_time = 0      # wall-clock when we switched to buffer
        self.buffer_switch_position = 0  # position in buffer file at switch time (seconds)

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

        # Create temp directory for recordings in XDG_RUNTIME_DIR (secure, per-user)
        runtime_dir = os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
        self.temp_dir = Path(runtime_dir) / "budgie-radio-buffer"
        self.temp_dir.mkdir(exist_ok=True, mode=0o700)  # Owner only
        print(f"Buffer directory: {self.temp_dir}")

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

        # Enable progressive download for better seeking
        self.player.set_property("buffer-size", 10 * 1024 * 1024)
        self.player.set_property("buffer-duration", 5 * Gst.SECOND)

        # Connect to bus for tag messages
        bus = self.player.get_bus()
        bus.add_signal_watch()
        bus.connect("message::tag", self._on_tag_message)
        bus.connect("message::error", self._on_error_message)
        bus.connect("message::buffering", self._on_buffering_message)

    def _setup_recorder(self, stream_url):
        """Setup recording pipeline for rolling buffer"""
        # Stop any existing recorder
        if self.recorder:
            self.recorder.set_state(Gst.State.NULL)
            self.recorder = None

        # Create new temp file for this recording (overwrite old one)
        if self.record_file and os.path.exists(self.record_file):
            try:
                os.unlink(self.record_file)
            except Exception as e:
                print(f"Warning: Could not delete old buffer file: {e}")

        station_id = self.current_station.uuid if self.current_station else "unknown"
        # Use .mkv for Matroska container - supports seeking and various codecs
        self.record_file = str(self.temp_dir / f"buffer_{station_id}.mkv")

        print(f"\n=== RECORDER SETUP ===")
        print(f"  Record file: {self.record_file}")

        # Create proper recording pipeline with tee
        # souphttpsrc → decodebin → audioconvert → vorbisenc → matroskamux → filesink
        pipeline_str = f"""
            souphttpsrc location="{stream_url}" !
            decodebin name=dec
            dec. ! audioconvert ! audioresample !
            tee name=t
            t. ! queue ! vorbisenc ! matroskamux ! filesink location="{self.record_file}"
        """

        print(f"  Pipeline: {pipeline_str.strip()}")

        try:
            self.recorder = Gst.parse_launch(pipeline_str)

            # Connect to bus for errors
            rec_bus = self.recorder.get_bus()
            rec_bus.add_signal_watch()
            rec_bus.connect("message::error", self._on_recorder_error)

            self.recorder.set_state(Gst.State.PLAYING)
            self.record_start_time = GLib.get_monotonic_time() / 1000000  # seconds

            print(f"  Recorder state: PLAYING")
            print(f"  Record start time: {self.record_start_time}")
            print(f"=== RECORDER STARTED ===\n")

            # Monitor file size to implement rolling buffer
            GLib.timeout_add_seconds(10, self._check_buffer_size)

        except Exception as e:
            print(f"Failed to setup recorder: {e}")
            import traceback
            traceback.print_exc()
            self.recorder = None

    def _on_recorder_error(self, bus, message):
        """Handle recording pipeline errors"""
        err, debug = message.parse_error()
        print(f"\n=== RECORDER ERROR ===")
        print(f"Recording error: {err.message}")
        print(f"Debug: {debug}\n")

    def _check_buffer_size(self):
        """Check buffer file size and implement simple rolling buffer"""
        if not self.recorder or not self.record_file or not os.path.exists(self.record_file):
            return False  # Stop checking

        try:
            file_size = os.path.getsize(self.record_file)

            if file_size % (10 * 1024 * 1024) < 100000:  # Log every ~10MB
                print(f"[BUFFER] File size: {file_size/1024/1024:.2f}MB")

            # If file exceeds max size, restart recording (simple rolling buffer)
            if file_size > self.max_buffer_size:
                print(f"Buffer file reached {file_size/1024/1024:.1f}MB, restarting...")

                # Save current station URL
                station_url = self.current_station.url if self.current_station else None

                if station_url:
                    # Stop current recorder
                    self.recorder.set_state(Gst.State.NULL)

                    # Delete old file
                    try:
                        os.unlink(self.record_file)
                    except:
                        pass

                    # Restart recording
                    self._setup_recorder(station_url)

        except Exception as e:
            print(f"Error checking buffer size: {e}")

        # Continue checking
        return True

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

        # Cancel any pending auto-resume
        if self.auto_resume_timeout:
            GLib.source_remove(self.auto_resume_timeout)
            self.auto_resume_timeout = None

        # Stop recording
        if self.recorder:
            self.recorder.set_state(Gst.State.NULL)
            self.recorder = None

        if self.player:
            self.player.set_state(Gst.State.NULL)

        self.current_station = None
        self.is_paused = False
        self.is_playing_from_buffer = False
        self.buffer_switch_time = 0
        self.buffer_switch_position = 0

        # Keep the buffer file - don't delete it
        # It will be overwritten when next station plays

        self.PlaybackStopped()

    @dbus.service.method(INTERFACE, out_signature='')
    def PausePlayback(self):
        """Pause current playback (keeps buffering)"""
        print("PausePlayback called")

        if self.player and not self.is_paused:
            self.player.set_state(Gst.State.PAUSED)
            self.is_paused = True
            self.PlaybackPaused()

            # Recording continues in background

    @dbus.service.method(INTERFACE, out_signature='')
    def ResumePlayback(self):
        """Resume playback from current position"""
        print("ResumePlayback called")

        # Cancel any pending auto-resume
        if self.auto_resume_timeout:
            GLib.source_remove(self.auto_resume_timeout)
            self.auto_resume_timeout = None

        if self.player and self.is_paused:
            self.player.set_state(Gst.State.PLAYING)
            self.is_paused = False
            # Re-emit NowPlaying signal with current station info
            if self.current_station:
                self.NowPlaying(
                    self.current_station.name,
                    "",
                    self.current_station.favicon,
                    self.current_station.codec,
                    self.current_station.bitrate
                )

    @dbus.service.method(INTERFACE, in_signature='x', out_signature='')
    def SeekRelative(self, offset_seconds):
        """
        Seek relative to current position
        offset_seconds: seconds to skip (negative = backwards, positive = forwards)
        """
        print(f"\n=== SEEK RELATIVE CALLED ===")
        print(f"  Offset: {offset_seconds} seconds")
        print(f"  Currently playing from buffer: {self.is_playing_from_buffer}")

        if not self.player:
            print("  ERROR: No player!")
            return

        # Cancel any pending auto-resume
        if self.auto_resume_timeout:
            GLib.source_remove(self.auto_resume_timeout)
            self.auto_resume_timeout = None

        # If seeking backward and not already playing from buffer, switch to buffer
        if offset_seconds < 0 and not self.is_playing_from_buffer:
            print("  Switching to buffer playback first...")
            self._switch_to_buffer_playback()
            # Give it a moment to load, then seek
            GLib.timeout_add(200, lambda: self._do_seek(offset_seconds))
        else:
            print("  Seeking directly...")
            self._do_seek(offset_seconds)

        # Auto-resume after 0.7 seconds
        print(f"  Auto-resume scheduled in 700ms")
        self.auto_resume_timeout = GLib.timeout_add(700, self._auto_resume)

    def _auto_resume(self):
        """Auto-resume playback after scrubbing"""
        print(f"\n=== AUTO-RESUME TRIGGERED ===")
        print(f"  Is paused: {self.is_paused}")
        if self.is_paused:
            print("  Auto-resuming playback after scrub")
            self.ResumePlayback()
        else:
            print("  Already playing, not resuming")
        self.auto_resume_timeout = None
        return False  # Don't repeat

    def _do_seek(self, offset_seconds):
        """Actually perform the seek"""
        print(f"\n=== DO SEEK ===")
        print(f"  Offset: {offset_seconds} seconds")

        if not self.player:
            print("  ERROR: No player!")
            return False

        # Pause playback during seek
        was_playing = not self.is_paused
        print(f"  Was playing: {was_playing}")

        if was_playing:
            print("  Pausing for seek...")
            self.player.set_state(Gst.State.PAUSED)
            self.is_paused = True
            self.PlaybackPaused()

        if self.is_playing_from_buffer:
            # Seeking within buffer file
            position = self.player.query_position(Gst.Format.TIME)
            print(f"  Position query successful: {position[0]}")

            if position[0]:
                current_pos = position[1]
                current_sec = current_pos / Gst.SECOND
                new_pos = current_pos + (offset_seconds * Gst.SECOND)
                new_sec = new_pos / Gst.SECOND

                print(f"  Current position: {current_sec:.2f}s ({current_pos} ns)")
                print(f"  Target position: {new_sec:.2f}s ({new_pos} ns)")

                # Clamp to valid range (start at 0)
                new_pos = max(0, new_pos)

                # Get actual file duration for upper bound
                duration = self.player.query_duration(Gst.Format.TIME)
                print(f"  Duration query successful: {duration[0]}")

                if duration[0]:
                    dur_sec = duration[1] / Gst.SECOND
                    print(f"  File duration: {dur_sec:.2f}s ({duration[1]} ns)")
                    new_pos = min(new_pos, duration[1])
                else:
                    print("  WARNING: Could not get duration!")

                final_sec = new_pos / Gst.SECOND
                print(f"  Final seek position: {final_sec:.2f}s")

                print(f"  Performing seek...")
                self.player.seek_simple(
                    Gst.Format.TIME,
                    Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                    new_pos
                )
                print(f"  Seek command sent")
            else:
                print("  ERROR: Could not query position!")
        else:
            print("  Not playing from buffer, seek skipped")

        print(f"=== DO SEEK COMPLETE ===\n")

        return False

    def _switch_to_buffer_playback(self):
        """Switch from live stream to playing from buffer file"""
        # Record the wall-clock time we left live, so we can compute true lag
        self.buffer_switch_time = GLib.get_monotonic_time() / 1000000
        self.buffer_switch_position = self._get_buffer_duration_internal()

        print(f"\n=== SWITCH TO BUFFER PLAYBACK ===")

        if not self.record_file or not os.path.exists(self.record_file):
            print("  ERROR: No buffer file available!")
            print(f"  Record file: {self.record_file}")
            print(f"  Exists: {os.path.exists(self.record_file) if self.record_file else False}")
            return

        # Wait a moment for file to have some content
        file_size = os.path.getsize(self.record_file)
        print(f"  Buffer file size: {file_size/1024:.2f} KB")

        if file_size < 100000:  # Less than 100KB
            print(f"  WARNING: Buffer file too small ({file_size} bytes), may not work well")

        print(f"  Stopping live playback...")
        print(f"  Current URI: {self.player.get_property('uri')}")

        # Switch player to buffer file
        self.player.set_state(Gst.State.NULL)
        print(f"  Player state: NULL")

        buffer_uri = f"file://{self.record_file}"
        print(f"  New URI: {buffer_uri}")
        self.player.set_property("uri", buffer_uri)

        print(f"  Setting player to PAUSED...")
        self.player.set_state(Gst.State.PAUSED)

        # Give it a moment to open the file
        print(f"  Scheduling seek to buffer end in 100ms...")
        GLib.timeout_add(100, self._seek_to_buffer_end)

        print(f"=== SWITCH TO BUFFER INITIATED ===\n")

    def _seek_to_buffer_end(self):
        """Seek to end of buffer file after opening"""
        print(f"\n=== SEEK TO BUFFER END ===")

        # Query the file duration
        duration = self.player.query_duration(Gst.Format.TIME)
        print(f"  Duration query successful: {duration[0]}")

        if duration[0] and duration[1] > 0:
            dur_sec = duration[1] / Gst.SECOND
            print(f"  File duration: {dur_sec:.2f}s ({duration[1]} ns)")

            # Seek to near the end (leave 1 second buffer)
            end_pos = max(0, duration[1] - Gst.SECOND)
            end_sec = end_pos / Gst.SECOND
            print(f"  Target position (end - 1s): {end_sec:.2f}s")

            print(f"  Performing seek...")
            self.player.seek_simple(
                Gst.Format.TIME,
                Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                end_pos
            )
            print(f"  Seek command sent")

            self.is_playing_from_buffer = True
            print(f"  is_playing_from_buffer = True")

            if not self.is_paused:
                self.is_paused = True
                print(f"  Emitting PlaybackPaused signal")
                self.PlaybackPaused()
        else:
            print("  ERROR: Could not query buffer duration!")
            if duration[0]:
                print(f"    Duration value: {duration[1]}")

        print(f"=== SEEK TO BUFFER END COMPLETE ===\n")

        return False

    @dbus.service.method(INTERFACE, out_signature='')
    def SeekToLive(self):
        """Jump to live edge of stream and resume playback"""
        print(f"\n=== SEEK TO LIVE ===")

        if not self.player:
            print("  ERROR: No player!")
            return

        print(f"  Currently playing from buffer: {self.is_playing_from_buffer}")

        # Cancel any pending auto-resume
        if self.auto_resume_timeout:
            print("  Cancelling auto-resume timeout")
            GLib.source_remove(self.auto_resume_timeout)
            self.auto_resume_timeout = None

        # If playing from buffer, switch back to live stream
        if self.is_playing_from_buffer:
            print("  Switching back to live stream...")
            self._switch_to_live_playback()
        else:
            print("  Already on live stream")

        # Resume if paused
        if self.is_paused:
            print("  Resuming playback...")
            self.player.set_state(Gst.State.PLAYING)
            self.is_paused = False
            if self.current_station:
                self.NowPlaying(
                    self.current_station.name,
                    "",
                    self.current_station.favicon,
                    self.current_station.codec,
                    self.current_station.bitrate
                )

        print(f"=== SEEK TO LIVE COMPLETE ===\n")

    def _switch_to_live_playback(self):
        """Switch from buffer file back to live stream"""
        # Reset buffer tracking
        self.buffer_switch_time = 0
        self.buffer_switch_position = 0

        print(f"\n=== SWITCH TO LIVE PLAYBACK ===")

        if not self.current_station:
            print("  ERROR: No current station!")
            return

        print(f"  Live URL: {self.current_station.url}")
        print(f"  Stopping buffer playback...")

        # Switch back to live URL
        self.player.set_state(Gst.State.NULL)
        print(f"  Player state: NULL")

        self.player.set_property("uri", self.current_station.url)
        print(f"  Setting player to PLAYING...")
        self.player.set_state(Gst.State.PLAYING)

        self.is_playing_from_buffer = False
        print(f"  is_playing_from_buffer = False")
        print(f"=== SWITCH TO LIVE COMPLETE ===\n")

    @dbus.service.method(INTERFACE, out_signature='x')
    def GetBufferDuration(self):
        """Return available buffer duration in seconds"""
        return self._get_buffer_duration_internal()

    def _get_buffer_duration_internal(self):
        """Internal method to get buffer duration"""
        if not self.record_file or not os.path.exists(self.record_file):
            return 0

        # Always base buffer duration on how long the recorder has been running.
        # The recorder pipeline keeps writing to disk regardless of whether the
        # player is live, playing from buffer, or paused - so this is always the
        # correct measure of how much audio is available.
        current_time = GLib.get_monotonic_time() / 1000000
        elapsed = current_time - self.record_start_time

        # Cap at max duration
        return min(int(elapsed), self.max_buffer_duration)

    @dbus.service.method(INTERFACE, out_signature='x')
    def GetCurrentPosition(self):
        """Return current playback position (seconds from start of buffer)"""
        if not self.player:
            return 0

        if not self.is_playing_from_buffer:
            # If playing live, we're at the "end" of the buffer
            return self._get_buffer_duration_internal()

        # Playing from buffer file - get actual position
        position = self.player.query_position(Gst.Format.TIME)
        if not position[0]:
            return 0

        pos_sec = position[1] // Gst.SECOND
        # Debug log occasionally
        import random
        if random.random() < 0.1:  # 10% of calls
            print(f"[DEBUG] GetCurrentPosition: {pos_sec}s")
        return pos_sec

    @dbus.service.method(INTERFACE, out_signature='x')
    def GetTimeBehindLive(self):
        """
        Return how many seconds behind the real live stream we are.
        Zero means we are on the live stream directly.
        Only non-zero when playing from the buffer.
        """
        if not self.is_playing_from_buffer:
            return 0

        # Time elapsed in the real world since we left live
        now = GLib.get_monotonic_time() / 1000000
        real_world_elapsed = now - self.buffer_switch_time

        # Our position in the buffer file
        current_pos = self.GetCurrentPosition()

        # True lag = how far the live stream has moved on while we've been
        # playing (or paused) in the buffer
        behind = int(self.buffer_switch_position + real_world_elapsed - current_pos)
        return max(0, behind)

    @dbus.service.method(INTERFACE, out_signature='b')
    def IsPaused(self):
        """Return whether playback is currently paused"""
        return self.is_paused

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

    @dbus.service.signal(INTERFACE)
    def PlaybackPaused(self):
        """Emitted when playback is paused"""
        pass

    # Internal async methods

    async def _play_station_async(self, station_uuid):
        """Fetch station details from API and start playback"""
        try:
            # Fetch station details
            station_data = await self.radio_client.station(uuid=station_uuid)

            # Convert to our station object
            station = RadioStation(
                uuid=station_data.uuid,
                name=station_data.name,
                url=station_data.url_resolved or station_data.url,
                favicon=station_data.favicon,
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

        # Start recording buffer
        self._setup_recorder(station.url)

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

    def _on_buffering_message(self, bus, message):
        """Handle buffering messages"""
        percent = message.parse_buffering()
        print(f"[BUFFERING] {percent}%")

        # Pause during buffering if not already paused
        if percent < 100 and not self.is_paused:
            self.player.set_state(Gst.State.PAUSED)
        elif percent == 100 and not self.is_paused:
            self.player.set_state(Gst.State.PLAYING)

    def shutdown(self):
        """Clean shutdown"""
        # Stop recording
        if self.recorder:
            self.recorder.set_state(Gst.State.NULL)

        # Clean up temp files
        if self.record_file and os.path.exists(self.record_file):
            try:
                os.unlink(self.record_file)
            except:
                pass

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
