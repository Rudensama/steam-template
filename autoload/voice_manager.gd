extends Node
## Push-to-talk OR open-mic voice chat. Audio is captured and encoded by Steam's
## built-in voice codec, shipped to peers as small packets over whatever
## MultiplayerPeer is active (Steam OR LAN), then decoded by Steam and played
## back through an AudioStreamGenerator. Steam must be running for capture/decode.
##
## Design notes (these fix the classic voice-chat bugs):
##   * A Godot mic-monitor bus continuously measures input level, independent of
##     Steam recording. That level drives the noise gate AND the settings meter,
##     so calibration works even outside a session.
##   * The gate blocks BOTH modes: open mic sends only when you're above the
##     threshold; push-to-talk sends only while the key is down AND you're above
##     it. Steam only records while actually transmitting, so no stale backlog
##     builds up (that backlog was the source of the laggy/garbled audio).
##   * Playback uses a small per-speaker jitter buffer that is primed before it
##     starts and never overflows, which removes the clicks/static from dropped
##     frames and the crackle from buffer underruns.
##
## Autoload singleton name: VoiceManager
## Public API used by the UI: get_mic_level(), set_calibrating(), is_talking(),
## set_peer_volume()/get_peer_volume(), set_peer_muted()/is_peer_muted().

signal talking_changed(peer_id: int, talking: bool)

enum MicMode { PUSH_TO_TALK, OPEN_MIC }

const PTT_ACTION: String = "voice_ptt"
const SILENCE_TIMEOUT_MS: int = 300
const MIC_MONITOR_BUS: String = "MicMonitor"
const MIC_RELEASE_MS: int = 400        ## Keep the gate open briefly after a dip.
## Jitter buffer: smooth out bursty/late packets without letting latency grow.
const VOICE_GEN_BUFFER: float = 0.5    ## AudioStreamGenerator capacity (seconds).
const VOICE_TARGET_MS: int = 90        ## Keep ~this much queued in the generator (cushion).
const VOICE_PRIME_MS: int = 90         ## Build this much before a speaker starts playing.
const VOICE_MAX_QUEUE_MS: int = 250    ## Hard cap on buffered audio; drop oldest beyond this.

var enabled: bool = true          ## Master toggle (see Settings).
var playback_volume: float = 1.0  ## 0..1 multiplier applied to incoming voice.
var mic_mode: MicMode = MicMode.PUSH_TO_TALK
var listen_to_self: bool = false  ## Hear your own microphone back (see Settings).
var mic_threshold: float = 0.02   ## RMS level required to open the gate.

## Logs a once-per-second summary of the voice pipeline to the Output panel, on
## both machines, so we can see where remote voice breaks:
##   sent>0        -> we ARE capturing + transmitting voice packets
##   recv>0        -> we ARE receiving the other player's packets
##   decode_fail>0 -> packets arrive but Steam can't decompress them
##   issue=...     -> why the last send attempt produced nothing
## Set to true to re-enable diagnostics if you ever need to debug voice again.
var debug_voice: bool = false
var _dbg_sent: int = 0
var _dbg_recv: int = 0
var _dbg_decode_fail: int = 0
var _dbg_last_issue: String = ""
var _dbg_send_bytes: int = 0
var _dbg_recv_bytes: int = 0
var _dbg_decode_result: int = 0
var _dbg_enq_frames: int = 0   # PCM frames decoded+queued this second (should ~= rate)
var _dbg_play_frames: int = 0  # PCM frames pushed to the speakers this second
var _dbg_next_ms: int = 0
var _dbg_recv_from: Dictionary = {}   # peer_id -> packets received this second
var _dbg_seen_recv: Dictionary = {}   # peer_id -> already logged first packet
var _dbg_seen_play: Dictionary = {}   # peer_id -> already logged first playback
## On-screen overlay so the log is visible in EXPORTED builds (no Output panel).
## Toggle with F3. Only built when debug_voice is true.
var _dbg_overlay: CanvasLayer
var _dbg_label: Label
var _dbg_events: Array[String] = []
## Per-day log file written to a `logs/` folder next to the executable, so the
## send/receive timeline survives after the game closes (for offline debugging).
var _log_file: FileAccess
var _log_date: String = ""

var _recording: bool = false
var _sample_rate: int = 24000
var _talking: Dictionary = {}   # peer_id -> bool

## When true the mic monitor runs even outside a session so Settings can show a
## live level meter for calibration.
var _calibrating: bool = false

var _mic_monitor_player: AudioStreamPlayer
var _mic_capture: AudioEffectCapture
var _mic_bus_index: int = -1
var _mic_envelope: float = 0.0
var _mic_last_heard_ms: int = -100000

## Per-listener voice mixing, applied locally only.
var _peer_volume: Dictionary = {}   # peer_id -> float (0..1)
var _peer_muted: Dictionary = {}    # peer_id -> bool

## peer_id -> { player, playback, queue: PackedFloat32Array, last_ms, primed }
var _speakers: Dictionary = {}

func _ready() -> void:
	if SteamManager.is_online():
		_sample_rate = Steam.getVoiceOptimalSampleRate()
	_setup_mic_monitor()
	if debug_voice:
		print("[voice] ready  online=%s  sample_rate=%d" % [SteamManager.is_online(), _sample_rate])
		_setup_debug_overlay()
		_log("=== SESSION START  online=%s  sample_rate=%d ===" % [SteamManager.is_online(), _sample_rate])

func _process(_delta: float) -> void:
	_update_mic_monitor()
	_update_transmit()
	_pump_speakers()
	_expire_silent_speakers()
	_debug_tick()

func _debug_tick() -> void:
	if not debug_voice:
		return
	var now: int = Time.get_ticks_msec()
	if now < _dbg_next_ms:
		return
	_dbg_next_ms = now + 1000
	var summary: String = "rec=%s talking=%s | sent=%d (%dB) | recv=%d from=%s fail=%d dresult=%d\npcm_fps=%d play_fps=%d rate=%d (want pcm_fps~=rate) | speakers=%d | issue=%s" % [
		_recording, _talking.get(_local_id(), false),
		_dbg_sent, _dbg_send_bytes, _dbg_recv, str(_dbg_recv_from), _dbg_decode_fail, _dbg_decode_result,
		_dbg_enq_frames, _dbg_play_frames, _sample_rate, _speakers.size(), _dbg_last_issue]
	print("[voice] " + summary)
	_refresh_debug_overlay(summary)
	_log(summary.replace("\n", "  "))
	_dbg_sent = 0
	_dbg_recv = 0
	_dbg_decode_fail = 0
	_dbg_enq_frames = 0
	_dbg_play_frames = 0
	_dbg_recv_from.clear()

# --- On-screen debug overlay (for exported builds) -------------------------

func _setup_debug_overlay() -> void:
	_dbg_overlay = CanvasLayer.new()
	_dbg_overlay.layer = 128   # Above everything else.
	add_child(_dbg_overlay)
	var panel: PanelContainer = PanelContainer.new()
	panel.position = Vector2(8, 8)
	panel.self_modulate = Color(0, 0, 0, 0.7)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dbg_overlay.add_child(panel)
	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	_dbg_label = Label.new()
	_dbg_label.add_theme_font_size_override("font_size", 13)
	_dbg_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.65))
	_dbg_label.text = "VOICE DEBUG (F3)\nwaiting..."
	margin.add_child(_dbg_label)

## Push a highlighted event line (RECEIVING / PLAYING) into the overlay history.
func _dbg_event(text: String) -> void:
	_dbg_events.append(text)
	while _dbg_events.size() > 6:
		_dbg_events.pop_front()

func _refresh_debug_overlay(summary: String) -> void:
	if _dbg_label == null:
		return
	var lines: String = "VOICE DEBUG (F3 to hide)  online=%s rate=%d\n%s" % [
		SteamManager.is_online(), _sample_rate, summary]
	if not _dbg_events.is_empty():
		lines += "\n" + "\n".join(_dbg_events)
	_dbg_label.text = lines

func _input(event: InputEvent) -> void:
	if not debug_voice or _dbg_overlay == null:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_dbg_overlay.visible = not _dbg_overlay.visible

# --- File logging (logs/ next to the exe, one file per day) -----------------

## Folder that holds the log files: `logs/` beside the executable in an exported
## build, or beside project.godot when running from the editor.
func _log_base_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()

func _open_append(path: String) -> FileAccess:
	if FileAccess.file_exists(path):
		var f: FileAccess = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
		return f
	return FileAccess.open(path, FileAccess.WRITE)

## Ensures _log_file points at today's file, rotating at midnight.
func _ensure_log() -> void:
	var today: String = Time.get_date_string_from_system()   # YYYY-MM-DD
	if _log_file != null and _log_date == today:
		return
	if _log_file != null:
		_log_file.close()
		_log_file = null
	var dir: String = _log_base_dir().path_join("logs")
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = dir.path_join("voice_%s.log" % today)
	_log_file = _open_append(path)
	if _log_file == null:
		# Exe folder not writable (e.g. Program Files) — fall back to user://.
		var udir: String = "user://logs"
		DirAccess.make_dir_recursive_absolute(udir)
		path = udir.path_join("voice_%s.log" % today)
		_log_file = _open_append(path)
	if _log_file != null:
		print("[voice] logging to ", ProjectSettings.globalize_path(path))
	_log_date = today

func _log(line: String) -> void:
	if not debug_voice:
		return
	_ensure_log()
	if _log_file == null:
		return
	# Tag every line with time + which instance wrote it, so two sandboxes' logs
	# are easy to tell apart.
	_log_file.store_line("%s [id=%d host=%s] %s" % [
		Time.get_time_string_from_system(), _local_id(), NetworkManager.is_host, line])
	_log_file.flush()

# --- Public helpers --------------------------------------------------------

## Current smoothed mic level (0..1). Drives the Settings meter.
func get_mic_level() -> float:
	return _mic_envelope

## Ask the mic monitor to keep running while a calibration UI (Settings) is open.
func set_calibrating(on: bool) -> void:
	_calibrating = on

func set_listen_to_self(on: bool) -> void:
	listen_to_self = on
	_update_monitor_volume()

func is_talking(peer_id: int) -> bool:
	return _talking.get(peer_id, false)

## Our peer id, or 1 when no peer is assigned (menu / calibration). Avoids the
## "No multiplayer peer is assigned" error from get_unique_id() outside a session.
func _local_id() -> int:
	if not _in_session():
		return 1
	return multiplayer.get_unique_id()

## Local, per-speaker playback volume (0..1). Does not affect other listeners.
func set_peer_volume(peer_id: int, volume: float) -> void:
	_peer_volume[peer_id] = clampf(volume, 0.0, 1.0)

func get_peer_volume(peer_id: int) -> float:
	return _peer_volume.get(peer_id, 1.0)

func set_peer_muted(peer_id: int, muted: bool) -> void:
	_peer_muted[peer_id] = muted
	if muted and _speakers.has(peer_id):
		_speakers[peer_id].queue = PackedFloat32Array()

func is_peer_muted(peer_id: int) -> bool:
	return _peer_muted.get(peer_id, false)

# --- Mic monitor (Godot input: level detection + listen-to-self) -----------

func _setup_mic_monitor() -> void:
	if _mic_bus_index != -1:
		return
	if AudioServer.get_bus_index(MIC_MONITOR_BUS) == -1:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, MIC_MONITOR_BUS)
		AudioServer.set_bus_send(AudioServer.get_bus_index(MIC_MONITOR_BUS), "Master")
		AudioServer.set_bus_mute(AudioServer.get_bus_index(MIC_MONITOR_BUS), true)
	_mic_bus_index = AudioServer.get_bus_index(MIC_MONITOR_BUS)
	# The capture effect reads the signal BEFORE the bus mute/volume fader, so we
	# can measure level while the bus stays muted (no self-echo).
	_mic_capture = AudioEffectCapture.new()
	_mic_capture.buffer_length = 0.25
	AudioServer.add_bus_effect(_mic_bus_index, _mic_capture)
	_mic_monitor_player = AudioStreamPlayer.new()
	_mic_monitor_player.stream = AudioStreamMicrophone.new()
	_mic_monitor_player.bus = MIC_MONITOR_BUS
	add_child(_mic_monitor_player)

## Whether the mic monitor should be capturing right now.
func _need_monitor() -> bool:
	return _calibrating or (enabled and SteamManager.is_online() and _in_session())

## Keeps the monitor player running when needed and refreshes the level envelope.
func _update_mic_monitor() -> void:
	if _mic_monitor_player == null:
		return
	if _need_monitor():
		if not _mic_monitor_player.playing:
			_mic_monitor_player.play()
		_measure_level()
	else:
		if _mic_monitor_player.playing:
			_mic_monitor_player.stop()
		# Let the meter fall back to silence when idle.
		_mic_envelope = maxf(0.0, _mic_envelope * 0.8)

func _measure_level() -> void:
	if _mic_capture == null or _mic_capture.get_frames_available() <= 0:
		# No new frames: decay toward zero so the meter drops when you go quiet.
		_mic_envelope *= 0.9
		return
	var frames: PackedVector2Array = _mic_capture.get_buffer(_mic_capture.get_frames_available())
	if frames.is_empty():
		return
	var energy: float = 0.0
	for f: Vector2 in frames:
		energy += f.x * f.x
	var rms: float = sqrt(energy / frames.size())
	# Smooth with an envelope so speech gaps don't drop the signal instantly.
	if rms > _mic_envelope:
		_mic_envelope = rms
	else:
		_mic_envelope = maxf(rms, _mic_envelope * 0.9)
	if _mic_envelope >= mic_threshold:
		_mic_last_heard_ms = Time.get_ticks_msec()

## True while the noise gate is open (above threshold, or within the release tail).
func _gate_open() -> bool:
	if _mic_envelope >= mic_threshold:
		return true
	return Time.get_ticks_msec() - _mic_last_heard_ms < MIC_RELEASE_MS

# --- Capture / send --------------------------------------------------------

func _update_transmit() -> void:
	if not enabled or not SteamManager.is_online() or not _in_session():
		_set_recording(false)
		_set_self_talking(false)
		_update_monitor_volume()
		return

	var ptt_held: bool = mic_mode == MicMode.PUSH_TO_TALK and Input.is_action_pressed(PTT_ACTION)
	var open_mic: bool = mic_mode == MicMode.OPEN_MIC
	# Keep Steam recording CONTINUOUSLY while the mic is live for this mode. Never
	# stop/start capture mid-sentence — that restarts Steam's codec and chops the
	# speech into fragments ("one letter at a time").
	var mic_live: bool = ptt_held or open_mic
	_set_recording(mic_live)

	# What we actually transmit: push-to-talk ships everything while the key is
	# down (the key press IS the intent, so the noise gate is bypassed); open mic
	# ships only while the gate is open, so background noise/static is filtered.
	var transmit: bool = false
	if mic_live:
		transmit = true if ptt_held else _gate_open()
		# Always drain Steam's buffer (kills stale backlog); only ship when transmitting.
		_capture_and_send(transmit)
	_set_self_talking(transmit)
	_update_monitor_volume()

func _set_recording(on: bool) -> void:
	if _recording == on:
		return
	_recording = on
	if on:
		Steam.startVoiceRecording()
	else:
		Steam.stopVoiceRecording()
	_log("recording=%s" % on)

## Drains Steam's captured voice every frame while recording (so no stale backlog
## builds up), but only ships packets to peers when should_send is true.
func _capture_and_send(should_send: bool) -> void:
	# getVoice() returns the compressed voice captured since the last call. When
	# there's nothing yet (just started recording) result is not OK — we skip.
	# NOTE: no getAvailableVoice() gate, so a wrong dict key there can't stall us.
	var voice: Dictionary = Steam.getVoice()
	var result: int = int(voice.get("result", -1))
	if result != Steam.VOICE_RESULT_OK:
		_dbg_last_issue = "getVoice.result=%d" % result
		return
	var buffer: PackedByteArray = voice.get("buffer", PackedByteArray())
	if buffer.is_empty():
		_dbg_last_issue = "empty buffer (written=%s)" % voice.get("written", "?")
		return
	if not should_send:
		return   # Buffer drained; gate closed, so discard instead of sending noise.
	_recv_voice.rpc(buffer)
	_dbg_sent += 1
	_dbg_send_bytes = buffer.size()
	_dbg_last_issue = ""

func _update_monitor_volume() -> void:
	if _mic_bus_index == -1:
		return
	var self_talking: bool = _talking.get(_local_id(), false)
	# Only let yourself be heard while actually talking, so a mic that is always
	# open does not leak into your own speakers constantly.
	AudioServer.set_bus_mute(_mic_bus_index, not (listen_to_self and self_talking))

# --- Talking replication ---------------------------------------------------

func _set_self_talking(on: bool) -> void:
	var my_id: int = _local_id()
	if _set_talking(my_id, on) and _in_session():
		_sync_talking.rpc(my_id, on)

func _set_talking(peer_id: int, on: bool) -> bool:
	if _talking.get(peer_id, false) == on:
		return false
	_talking[peer_id] = on
	if peer_id == _local_id() and SteamManager.is_online():
		# Tell Steam the local user is using voice in-game (suppresses its own
		# voice-chat UI sounds).
		Steam.setInGameVoiceSpeaking(SteamManager.steam_id, on)
	talking_changed.emit(peer_id, on)
	return true

@rpc("any_peer", "call_remote", "reliable")
func _sync_talking(peer_id: int, on: bool) -> void:
	# Only trust talking states broadcast by the peer they belong to.
	if peer_id == multiplayer.get_remote_sender_id():
		_set_talking(peer_id, on)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _recv_voice(compressed: PackedByteArray) -> void:
	if not enabled or not SteamManager.is_online():
		return
	_dbg_recv += 1
	_dbg_recv_bytes = compressed.size()
	var sender: int = multiplayer.get_remote_sender_id()
	if is_peer_muted(sender):
		return
	var decoded: Dictionary = Steam.decompressVoice(compressed, _sample_rate)
	_dbg_decode_result = int(decoded.get("result", -1))
	if _dbg_decode_result != Steam.VOICE_RESULT_OK:
		_dbg_decode_fail += 1
		return
	# Post-4.19 GodotSteam returns the PCM under "uncompressed"; fall back to other
	# known key names so a rename in the binding can't silence playback.
	var pcm: PackedByteArray = decoded.get("uncompressed", decoded.get("buffer", decoded.get("uncompressed_data", PackedByteArray())))
	if pcm.is_empty():
		_dbg_decode_fail += 1
		_dbg_last_issue = "decoded keys=%s" % str(decoded.keys())
		return
	# CRITICAL: decompressVoice returns a FIXED-capacity buffer (e.g. 20480 bytes);
	# only the first `size` bytes are real audio. Playing the whole buffer meant
	# ~5x too many samples (silence/garbage padding) -> chopped, gappy, then silent.
	# Truncate to the real decoded byte count.
	var real_bytes: int = int(decoded.get("size", decoded.get("written", decoded.get("size_uncompressed", pcm.size()))))
	if real_bytes > 0 and real_bytes < pcm.size():
		pcm = pcm.slice(0, real_bytes)
	_dbg_recv_from[sender] = int(_dbg_recv_from.get(sender, 0)) + 1
	if debug_voice and not _dbg_seen_recv.get(sender, false):
		_dbg_seen_recv[sender] = true
		var msg: String = ">>> RECEIVING peer %d: %dB in -> buffer=%dB real=%dB keys=%s" % [
			sender, compressed.size(), int(decoded.get("uncompressed", PackedByteArray()).size()), real_bytes, str(decoded.keys())]
		print("[voice] " + msg)
		_dbg_event(msg)
		_log(msg)
	_enqueue(sender, pcm)

# --- Playback (bounded jitter buffer) --------------------------------------

## Decode PCM into the speaker's queue. _pump_speakers() drains it into the audio
## generator at real time, keeping a small cushion so jitter/bursts don't cause
## gaps. The queue is hard-capped (VOICE_MAX_QUEUE_MS) so latency can't run away.
func _enqueue(peer_id: int, pcm: PackedByteArray) -> void:
	var speaker: Dictionary = _get_speaker(peer_id)
	@warning_ignore("integer_division")
	var frames: int = pcm.size() / 2   # 16-bit signed mono
	var queue: PackedFloat32Array = speaker.queue
	var start: int = queue.size()
	queue.resize(start + frames)
	for i: int in frames:
		queue[start + i] = float(pcm.decode_s16(i * 2)) / 32768.0
	speaker.queue = queue
	speaker.last_ms = Time.get_ticks_msec()
	_dbg_enq_frames += frames
	_set_talking(peer_id, true)

func _pump_speakers() -> void:
	var target: int = int(_sample_rate * VOICE_TARGET_MS / 1000.0)
	var prime: int = int(_sample_rate * VOICE_PRIME_MS / 1000.0)
	var max_q: int = int(_sample_rate * VOICE_MAX_QUEUE_MS / 1000.0)
	var capacity: int = int(_sample_rate * VOICE_GEN_BUFFER)
	for peer_id: int in _speakers:
		var speaker: Dictionary = _speakers[peer_id]
		var queue: PackedFloat32Array = speaker.queue
		# Bound latency: if we've fallen behind, fast-forward by dropping oldest.
		if queue.size() > max_q:
			queue = queue.slice(queue.size() - max_q)
		if queue.is_empty():
			speaker.queue = queue
			continue
		# Build an initial cushion before the first sound, then stay primed.
		if not speaker.primed:
			if queue.size() < prime:
				speaker.queue = queue
				continue
			speaker.primed = true
			if debug_voice and not _dbg_seen_play.get(peer_id, false):
				_dbg_seen_play[peer_id] = true
				var msg: String = ">>> PLAYING peer %d (primed %d frames)" % [peer_id, queue.size()]
				print("[voice] " + msg)
				_dbg_event(msg)
				_log(msg)
		# Only top the generator up to the target fill — NOT dump the whole queue
		# in (that put all the audio downstream and made latency unbounded before).
		var playback: AudioStreamGeneratorPlayback = speaker.playback
		var buffered: int = capacity - playback.get_frames_available()
		var room: int = max(0, target - buffered)
		var count: int = min(room, queue.size())
		if count > 0:
			var gain: float = playback_volume * get_peer_volume(peer_id)
			for i: int in count:
				playback.push_frame(Vector2(queue[i] * gain, queue[i] * gain))
			_dbg_play_frames += count
			queue = queue.slice(count)
		speaker.queue = queue

func _get_speaker(peer_id: int) -> Dictionary:
	if _speakers.has(peer_id):
		return _speakers[peer_id]
	var generator: AudioStreamGenerator = AudioStreamGenerator.new()
	generator.mix_rate = _sample_rate
	generator.buffer_length = VOICE_GEN_BUFFER
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = generator
	add_child(player)
	player.play()
	var speaker: Dictionary = {
		"player": player,
		"playback": player.get_stream_playback(),
		"queue": PackedFloat32Array(),
		"last_ms": Time.get_ticks_msec(),
		"primed": false,
	}
	_speakers[peer_id] = speaker
	return speaker

func _expire_silent_speakers() -> void:
	var now: int = Time.get_ticks_msec()
	for peer_id: int in _speakers:
		var speaker: Dictionary = _speakers[peer_id]
		if _talking.get(peer_id, false) and speaker.queue.is_empty() \
				and now - speaker.last_ms > SILENCE_TIMEOUT_MS:
			_set_talking(peer_id, false)
			speaker.primed = false   # Re-prime the cushion for the next utterance.

func stop_all() -> void:
	if _recording:
		_set_recording(false)
	for peer_id: int in _speakers:
		_speakers[peer_id].player.queue_free()
	_speakers.clear()
	_talking.clear()
	_dbg_seen_recv.clear()
	_dbg_seen_play.clear()
	_dbg_recv_from.clear()
	_log("=== stop_all (left session) ===")

func _in_session() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer)
