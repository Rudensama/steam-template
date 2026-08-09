# Steam + LAN Multiplayer Template (Godot 4.7 + GodotSteam)

A ready-to-extend base project with a full front-end flow —
**splash → main menu → play (Online / Local) → lobby → game** — that runs over
**two interchangeable transports** using Godot's high-level `MultiplayerAPI`:

| Transport | How you connect | Use it for |
|-----------|-----------------|------------|
| **Steam** | Host creates a lobby → share the **lobby code** or **Invite Friends** (Steam overlay) | Real online play |
| **LAN**   | Host starts a server → clients **join by IP** | Local testing / LAN parties |

Because everything sits on `MultiplayerAPI`, the **chat, voice, and player-list
code is identical** on both transports. Only the underlying peer differs
(`SteamMultiplayerPeer` vs `ENetMultiplayerPeer`).

## Features

1. **Lobby** with live **player cards** — avatar (Steam avatar or colored
   initial), host/you badges, live talking indicator, ping, ready state, and a
   **per-player color** (auto-assigned an unused one on join, changeable via a
   swatch picker on your own card).
2. **Ready-up** flow: the host's **Start Game** stays disabled until everyone is
   ready, then all peers switch to the game scene together.
3. **Text chat** as **avatar + rounded bubbles** tinted with each sender's color,
   plus **voice chat** (push-to-talk on **V**, or open mic) with a noise gate,
   per-player **mute + volume**, and host **kick**.
4. **Settings overlay** (openable from the menu and in-lobby via **Esc**),
   **saved to disk** (`user://settings.cfg`) — volumes, mic device, mic mode,
   noise-gate threshold with a live level meter, fullscreen, display name.
5. **Steam friend invites** via the overlay; join-by-code for Steam; LAN
   join-by-IP.
6. A **shared dark theme** and a small library of reusable UI scenes to build on.
7. Uses the **GodotSteam** addon only (v4.21 here; `SteamMultiplayerPeer` is built
   into GodotSteam 4.x).

---

## Project layout

```
assets/
  icon.svg
autoload/                # Singletons (see order below)
  steam_manager.gd       # Init Steamworks, pump callbacks, identity, invites    (SteamManager)
  network_manager.gd     # Transport switch, roster, ready-up, kick, ping, chat  (NetworkManager)
  voice_manager.gd       # Steam voice capture + jitter-buffered playback         (VoiceManager)
  game_settings.gd       # Load/save/apply user settings                          (Settings)
scenes/                  # One folder per screen (scene + script + local parts)
  splash/                # Steam status, then Continue -> main menu
  main_menu/             # Play / Settings / Quit
  lobby/                 # lobby.tscn composes:
	player_list.tscn       #   roster of player_card.tscn instances
	player_card.tscn       #   one player row
	chat_panel.tscn        #   chat log + input
  game/                  # Placeholder game scene — YOUR GAME GOES HERE
ui/                      # Shared, screen-agnostic UI
  theme.tres             # Default theme (project-wide via gui/theme/custom)
  overlays/              # play_overlay, settings_overlay (modal CanvasLayers)
  widgets/               # mic_meter, friend_invite_row, friend_invite_panel
steam_appid.txt          # 480 = Spacewar (Valve's public test app)
```

Autoload order (already set in `project.godot`):
`SteamManager → NetworkManager → VoiceManager → Settings`.

---

## First-time setup

1. Open the project in **Godot 4.7**.
2. The **GodotSteam GDExtension** loads automatically from `addons/godotsteam/`.
   If Godot shows extension errors, restart the editor, or re-download the build
   matching your Godot version.
3. Keep **`steam_appid.txt` (containing `480`) next to `project.godot`** and next
   to any exported `.exe`. This lets you test with the public Spacewar app before
   you own a real App ID.
4. The **Steam client must be running and logged in** for Steam lobbies *and*
   voice (voice capture/decoding uses Steam even on LAN). Without it you'll see
   "Steam offline — Local (LAN) play only" and Steam buttons disable.

### When you get your real Steam App ID
- Put your App ID in `steam_appid.txt` **and** in `APP_ID` in
  `autoload/steam_manager.gd`.
- Overlay/invites fully work only for an App ID your account owns (480 works for
  everyone).

---

## How to test

### LAN — do this first (no second account needed) ✅
1. In Godot: **Debug → Run Multiple Instances → 2 instances**, then Play.
2. Instance A → **Play → Local → Host LAN Server**. Note the IP shown in the
   lobby top bar (use `127.0.0.1` for same-PC testing).
3. Instance B → **Play → Local**, type the IP → **Join**.
4. Both land in the lobby: type in chat, hold **V** to talk, ready up. (Two mics
   on one PC will echo — voice is best verified across two machines.)

### Steam — needs two Steam accounts
Steam P2P requires **two different Steam accounts**, each running the game
(two PCs, or one PC + a friend). Same account twice won't work.

- Host → **Play → Online → Host Steam Lobby**. In the lobby, **Invite Friends**
  (Steam overlay) or **Copy Code** and send the number.
- Joiner → **Play → Online**, paste the code → **Join**, or just accept the Steam
  invite (works even if their game is closed — it launches with `+connect_lobby`).

---

## Extending it

- **Your game:** `scenes/game/game.tscn` is where every peer lands when the host
  presses **Start Game**. The peer, roster, voice and chat all persist across the
  scene change (they live on autoloads). Build your world here, or point
  `NetworkManager.GAME_SCENE` at your own scene.
- **Player roster:** `NetworkManager.players` is a
  `peer_id -> {name, steam_id, ready, ping}` dictionary, authoritative on the
  host. Listen to `NetworkManager.player_list_changed`.
- **RPCs / game state:** the peer is a standard Godot `MultiplayerAPI` peer, so
  add `@rpc` functions and `MultiplayerSpawner`/`MultiplayerSynchronizer` nodes
  as usual — they work over both transports unchanged.
- **Reusable UI:** drop `scenes/lobby/player_list.tscn`, `chat_panel.tscn`, or the
  `ui/overlays/*` modals into your own scenes; they wire themselves to the
  autoloads.
- **Voice:** automatic while in a session; tune in Settings. The noise-gate
  threshold has a live meter so you can set it just above your background static.
  Rebind the talk key via the `voice_ptt` action in *Project Settings → Input Map*.
- **Theme:** edit `ui/theme.tres` (or the colors in it) to restyle the whole app.
  Primary/destructive buttons use the `AccentButton` / `DangerButton` variations.
- **Max players / port:** `MAX_PLAYERS` and `DEFAULT_PORT` in
  `autoload/network_manager.gd`.
