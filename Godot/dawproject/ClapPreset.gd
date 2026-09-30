class_name ClapPreset extends RefCounted

## The `.clap-preset` container DAWproject uses for CLAP plugin state:
## `"clap"`, a big-endian u32 length, the CLAP id, then the plugin's raw state stream.

const MAGIC: PackedByteArray = [0x63, 0x6c, 0x61, 0x70]  # "clap"


static func wrap(clap_id: String, state: PackedByteArray) -> PackedByteArray:
	var id_bytes := clap_id.to_utf8_buffer()
	var out := PackedByteArray()
	out.append_array(MAGIC)
	var len_bytes := PackedByteArray([0, 0, 0, 0])
	len_bytes.encode_u32(0, id_bytes.size())
	# encode_u32 is little-endian; reverse for the big-endian header
	len_bytes.reverse()
	out.append_array(len_bytes)
	out.append_array(id_bytes)
	out.append_array(state)
	return out


## `{ok: true, clap_id, state}` or `{ok: false, error}`.
static func unwrap(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 8 or bytes.slice(0, 4) != MAGIC:
		return {"ok": false, "error": "not a .clap-preset file (missing 'clap' header)"}
	var id_len: int = (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7]
	if id_len < 0 or 8 + id_len > bytes.size():
		return {"ok": false, "error": ".clap-preset header names an id longer than the file"}
	return {
		"ok": true,
		"clap_id": bytes.slice(8, 8 + id_len).get_string_from_utf8(),
		"state": bytes.slice(8 + id_len),
	}
