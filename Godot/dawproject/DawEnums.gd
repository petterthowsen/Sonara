class_name DawEnums extends RefCounted

## Integer mirrors of the model enums the DAWproject code reads. The importer and exporter take
## model objects as plain `Object`s and compare against these, so their scripts compile without
## `Track`/`Channel`/`Project` (which name autoloads and so can't compile in a headless test
## until the tree is up). `test_dawproject_units.gd` checks every value against the real enum.

# Track.TrackType
const TRACK_AUDIO := 0
const TRACK_INSTRUMENT := 1
const TRACK_FOLDER := 2
const TRACK_GROUP := 3

# Channel.ChannelType
const CHANNEL_INSTRUMENT := 0
const CHANNEL_AUDIO := 1
const CHANNEL_BUS := 2
const CHANNEL_GROUP := 3

# Channel.PanMode
const PAN_COMBINED := 0
const PAN_DUAL := 1
const PAN_BALANCE := 2
const PAN_MONO := 3

# Clip.ClipType
const CLIP_AUDIO := 0
const CLIP_MIDI := 1

# Device.DeviceType
const DEVICE_BUILTIN := 0
const DEVICE_LV2 := 1
const DEVICE_CLAP := 2

# Device.DeviceCategory
const CATEGORY_INSTRUMENT := 0
const CATEGORY_EFFECT := 1
const CATEGORY_UTILITY := 2

const MASTER_CHANNEL_ID := 1
const HARDWARE_OUTPUT_MIN := 1000
