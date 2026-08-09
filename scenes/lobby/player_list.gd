extends PanelContainer
## The lobby roster panel: renders a PlayerCard per player and keeps them in sync
## with NetworkManager (join / leave / ready / ping) and VoiceManager (talking).
## Cards are updated in place, so nothing flickers. Self-contained — drop it
## anywhere you want a live player list.
class_name PlayerListPanel

const PLAYER_CARD: PackedScene = preload("res://scenes/lobby/player_card.tscn")

@onready var _list: VBoxContainer = %PlayerList
@onready var _count_label: Label = %CountLabel

var _cards: Dictionary = {}   # peer_id -> PlayerCard

func _ready() -> void:
	NetworkManager.player_list_changed.connect(_refresh)
	VoiceManager.talking_changed.connect(_on_talking_changed)
	_refresh()

func _refresh() -> void:
	# Drop cards for players who left.
	for id in _cards.keys():
		if not NetworkManager.players.has(id):
			_cards[id].queue_free()
			_cards.erase(id)

	var my_id: int = multiplayer.get_unique_id()
	for peer_id in NetworkManager.players:
		var info: Dictionary = NetworkManager.players[peer_id]
		if _cards.has(peer_id):
			_cards[peer_id].update(info)
		else:
			var card: PlayerCard = PLAYER_CARD.instantiate()
			_list.add_child(card)
			card.setup(peer_id, info, peer_id == my_id, NetworkManager.is_host)
			card.kick_pressed.connect(_on_kick)
			card.set_talking(VoiceManager.is_talking(peer_id))
			_cards[peer_id] = card

	_count_label.text = "%d / %d" % [NetworkManager.players.size(), NetworkManager.MAX_PLAYERS]

func _on_talking_changed(peer_id: int, talking: bool) -> void:
	if _cards.has(peer_id):
		_cards[peer_id].set_talking(talking)

func _on_kick(peer_id: int) -> void:
	NetworkManager.kick(peer_id)
