class_name SendConfig extends RefCounted

# Send routing
var target_channel_id: int = -1  # Index into Project.channels array
var name: String = "Send"        # Display name

# Send parameters
var amount: float = -12.0  # dB (send level)
var pre_fader: bool = false  # Pre/post fader send
var muted: bool = false

# Serialize to JSON
func to_json() -> Dictionary:
	return {
		"target_channel_id": target_channel_id,
		"name": name,
		"amount": amount,
		"pre_fader": pre_fader,
		"muted": muted
	}

# Deserialize from JSON
static func from_json(data: Dictionary) -> SendConfig:
	var send = SendConfig.new()
	send.target_channel_id = data.get("target_channel_id", -1)
	send.name = data.get("name", "Send")
	send.amount = data.get("amount", -12.0)
	send.pre_fader = data.get("pre_fader", false)
	send.muted = data.get("muted", false)
	return send
