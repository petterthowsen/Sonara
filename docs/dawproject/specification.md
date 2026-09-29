# DAWproject 1.0 specification

A condensed copy of the DAWproject open exchange format, for implementing import and export in
Sonara. Source: <https://github.com/bitwig/dawproject> at commit `ee4dcdd` (2025-07-12), MIT
licensed, © Bitwig. The format is at version 1.0 and declared stable.

The upstream prose reference (`Reference.html`) is generated from the Javadoc on the Java DOM
classes. This document merges that Javadoc with the XSD. The full schemas are reproduced
verbatim in the appendix; when this summary and the XSD disagree, the XSD wins.

## Purpose and scope

DAWproject moves user data (audio, notes, automation, plug-in state and the track and routing
structure around them) between DAWs in a single file.

Goals:

- Package all user data of a song in one file: audio, note, note-expression and automation
  timelines, audio data (embedded or referenced), and plug-in states (always embedded).
- Preserve as much user data as possible.
- Let the exporter describe its own track and timeline structure as is. The **importer** decides
  how far to flatten it.
- Simple, open, language-agnostic (plain ZIP and XML).

Non-goals: being a native DAW format, optimal performance, storing low-level MIDI events (it uses
higher-level abstractions instead), and storing non-session data such as view settings or
preferences.

Supported by Bitwig Studio 5.0.9, Studio One 6.5, Cubase 14, Cubasis 3.7.1, VST Live 2.2 and
n-Track Studio 10.2.2. Converters: DawVert (many formats), ProjectConverter (Reaper).

## Container

| Property | Value |
|---|---|
| Extension | `.dawproject` |
| Container | ZIP |
| Required entries | `project.xml` (root `<Project>`), `metadata.xml` (root `<MetaData>`) |
| Encoding | UTF-8 XML |
| Other entries | Any directory layout the exporter chooses, for audio files and plug-in states (e.g. `audio/…`, `plugins/…`) |

### File references (`FileReference`)

Used by `<File>` (media) and `<State>` (device state).

| Attribute | Type | Meaning |
|---|---|---|
| `path` (required) | string | Path inside the ZIP container; or, with `external="true"`, relative to the `.dawproject` file; or an absolute path when external and it starts with `/` or a Windows drive letter |
| `external` | bool, default `false` | The file lives outside the container |

Device `State` files **must** be embedded (`external=false`). Audio may be embedded or external.

## Common base types

Most elements inherit these attributes.

- **Nameable**: `name`, `color` (HTML `#rrggbb`), `comment`.
- **Referenceable** (extends Nameable): `id` (`xs:ID`, unique in the document). Other elements
  point at it with `xs:IDREF` attributes (`destination`, `track`, `parameter`, `reference`).
- **Lane** (abstract, extends Referenceable): base of `Track` and `Channel`.
- **Timeline** (abstract, extends Referenceable):
  - `track` (IDREF to a `Track`). When present, the timeline is local to (scoped to) that track.
  - `timeUnit`: `beats` or `seconds`. It is inherited by nested timelines. When neither this nor
    any parent scope sets it, it is `beats`.

`beats` always means **quarter notes**, regardless of time signature.

## Document structure

```
<Project version="1.0">
  <Application name=".." version=".."/>      required
  <Transport>                                optional
    <Tempo/>          RealParameter, unit="bpm"
    <TimeSignature/>  TimeSignatureParameter
  </Transport>
  <Structure>                                optional; list of Track | Channel
  <Arrangement>                              optional
    <Lanes>                  root timeline
    <Markers>                cue markers
    <TempoAutomation>        Points
    <TimeSignatureAutomation> Points
  </Arrangement>
  <Scenes>                                   optional; list of Scene (clip launcher)
</Project>
```

## Parameters

Parameters hold a value and are **automation targets** (they need an `id` to be targeted). All
extend `Parameter`, which adds `parameterID` (int): the plug-in's own parameter ID (VST2 index,
VST3 ParamID; for CLAP, the `clap_id`).

| Element | Attributes | Notes |
|---|---|---|
| `RealParameter` | `value`, `min`, `max` (double, may be `inf`/`-inf`), `unit` (required) | Uses real units, not normalized ranges, so values and automation transfer between hosts |
| `BoolParameter` | `value` (bool) | |
| `IntegerParameter` | `value`, `min`, `max` (int, inclusive) | |
| `EnumParameter` | `value` (index), `count` (required), `labels` (space-separated list) | `value` in `[0, count-1]` |
| `TimeSignatureParameter` | `numerator`, `denominator` (required) | |

**Unit** enum: `linear`, `normalized` (0–1), `percent` (0–100), `decibel`, `hertz`, `semitones`,
`seconds`, `beats` (quarter notes), `bpm`.

Conventions seen in exporters (Bitwig): channel `Volume` is `unit="linear"`, min 0, max 2 (1.0 =
0 dB); `Pan` is `unit="normalized"`, 0.5 = centre; `Tempo` is `unit="bpm"`.

## Structure: tracks and channels

### `Track` (sequencer track; extends Lane)

| Member | Meaning |
|---|---|
| `@contentType` | Space-separated list of `audio`, `automation`, `notes`, `video`, `markers`, `tracks`. What may be placed on the track. `tracks` marks a folder or group track |
| `@loaded` | Whether the track is loaded/active |
| `<Channel>` (0..1) | The mixer channel this track outputs to |
| `<Track>` (0..n) | Child tracks, for folder/group tracks (`contentType="tracks"`) |

Tracks and channels can also appear as top-level siblings in `<Structure>`. The master is a
`Track` whose channel has `role="master"`.

### `Channel` (mixer channel; extends Lane)

| Member | Meaning |
|---|---|
| `@role` | `regular` (default), `master`, `effect` (FX return), `submix` (group), `vca` |
| `@audioChannels` | 1 = mono, 2 = stereo (default 2), … |
| `@solo` | bool |
| `@destination` | IDREF to the output `Channel` (output routing) |
| `<Devices>` | Ordered list of devices and plug-ins (see below) |
| `<Mute>` | BoolParameter |
| `<Pan>` | RealParameter (pan/balance) |
| `<Volume>` | RealParameter |
| `<Sends>` | List of `<Send>` |

### `Send` (extends Referenceable)

| Member | Meaning |
|---|---|
| `<Volume>` (required) | RealParameter, send level |
| `<Pan>` | RealParameter |
| `<Enable>` | BoolParameter |
| `@destination` | IDREF to the target `Channel` |
| `@type` | `pre` or `post` (default `post`) fader |

## Devices

All devices extend `Device` (Referenceable).

| Member | Meaning |
|---|---|
| `@deviceRole` (required) | `instrument`, `noteFX`, `audioFX`, `analyzer` |
| `@deviceName` (required) | Display name of the device/plug-in |
| `@deviceID` | Unique plug-in ID. VST3: canonical UUID text (8-4-4-4-12, no braces). VST2: unsigned decimal integer. CLAP: the text ID as is (e.g. `org.surge-synth-team.surge-xt`) |
| `@deviceVendor` | Vendor name |
| `@loaded` | Loaded/active (default `true`) |
| `<Enabled>` | BoolParameter; false = bypassed |
| `<State>` | FileReference to the device state in its **native** format; must be embedded |
| `<Parameters>` | Parameters that are automated. Required so automation has an `id` to target. Built-in device parameters that already exist as named children must not be repeated here |

### Plug-in formats (extend abstract `Plugin`, which adds `@pluginVersion`)

| Element | State file format |
|---|---|
| `ClapPlugin` | `.clap-preset` |
| `Vst3Plugin` | `.vstpreset` |
| `Vst2Plugin` | FXB or FXP |
| `AuPlugin` | (unspecified; Apple AU) |

### Built-in devices

`BuiltinDevice` is a vendor-native device (identified by `deviceID`/`deviceName`, state in
`<State>`). Four **generic** built-ins extend it with standardized parameters, so they can be
rebuilt with any host's native processors:

- **`Equalizer`**: `<Band>` × n, `<InputGain>` (dB), `<OutputGain>` (dB).
  - `Band`: `@type` (required: `highPass`, `lowPass`, `bandPass`, `highShelf`, `lowShelf`,
    `bell`, `notch`), `@order` (band index), `<Freq>` (required), `<Gain>`, `<Q>`, `<Enabled>`.
- **`Compressor`**: `<Threshold>` (dB), `<Ratio>` (percent 0–100), `<Attack>` (s), `<Release>` (s),
  `<InputGain>` (dB), `<OutputGain>` (dB, makeup), `<AutoMakeup>` (bool).
- **`NoiseGate`**: `<Threshold>` (dB), `<Ratio>` (percent 0–100), `<Attack>` (s), `<Release>` (s),
  `<Range>` (dB, max gain reduction, `-inf`..0).
- **`Limiter`**: `<Threshold>` (dB), `<InputGain>` (dB), `<OutputGain>` (dB), `<Attack>` (s),
  `<Release>` (s).

`Device` itself may also be used directly as a generic element.

## Timelines

A timeline is any element extending `Timeline`. The content choice everywhere a timeline is
expected is: `Timeline`, `Lanes`, `Notes`, `Clips`, `ClipSlot`, `markers`, `Warps`, `Audio`,
`Video`, `Points`.

### `Lanes`

The main layering element: holds any number of parallel timelines. Usually the arrangement's
root `Lanes` contains one `Lanes` per track (`track="…"`), which then holds that track's clip,
note, audio and automation timelines.

### `Clips` and `Clip`

`Clips` is a timeline of `<Clip>` elements positioned by their `time` and `duration` in the
`Clips` element's time unit.

A `Clip` (Nameable, **not** Referenceable) is a clipped view onto a content timeline. It holds
either one child timeline or a `reference` to a timeline elsewhere (linked/alias clips), never
both.

| Attribute | Meaning |
|---|---|
| `time` (required) | Start on the parent timeline (parent's time unit) |
| `duration` | Length on the parent timeline. If omitted, infer from `playStop - playStart` (useful when parent and content units differ) |
| `contentTimeUnit` | Unit of the inner scope. Applies to content, `playStart`, `playStop`, `loopStart`, `loopEnd`; **not** to `time`/`duration` |
| `playStart` | Content time where playback starts (left trim / offset) |
| `playStop` | Content time where playback stops |
| `loopStart`, `loopEnd` | Loop region in content time. Loop is active when present |
| `fadeTimeUnit` | Unit of the fade times |
| `fadeInTime`, `fadeOutTime` | Fade lengths. A **negative** `fadeInTime` makes a crossfade: the clip starts at `time - abs(fadeInTime)` |
| `enable` | Played back (default `true`); false = muted clip |
| `reference` | IDREF to a content timeline (alias clip) |

Clips nest: Bitwig writes an arrangement `Clips` whose `Clip` contains another `Clips` of audio
events (see the example below). Importers may flatten this.

### `Notes` and `Note`

`Notes` is a timeline of `<Note>`.

| Attribute | Meaning |
|---|---|
| `time`, `duration` (required) | In the parent timeline's unit |
| `key` (required) | MIDI key 0–127 |
| `channel` (required in XSD) | MIDI channel 0–15 |
| `vel` | Note-on velocity, **normalized 0–1** |
| `rel` | Note-off (release) velocity, normalized 0–1 |

A `Note` may contain one child timeline (typically `Points` or `Lanes` of `Points`) holding
**per-note expressions** (see the expression targets below).

### Audio and video: `Audio`, `Video`, `MediaFile`

`Audio` (extends MediaFile extends Timeline) is the whole file as a timeline; trimming is done by
wrapping it in a `Clip`. Its `timeUnit` should always be `seconds`.

| Member | Meaning |
|---|---|
| `<File>` (required) | FileReference |
| `@duration` (required) | Length of the file in seconds (as stored; not a playback parameter) |
| `@sampleRate` (required) | Sample rate of the file |
| `@channels` (required) | 1 = mono, 2 = stereo, … |
| `@algorithm` | Vendor-specific stretch algorithm name |

`Video` has the same shape; `sampleRate`, `channels` and `algorithm` describe its audio track.

### `Warps` and `Warp` (time-stretching)

`Warps` maps the time of its content onto the outer timeline. Typical use is an audio file
(`contentTimeUnit="seconds"`) placed on a beats timeline (`timeUnit="beats"`).

- `@contentTimeUnit` (required): unit of the content and of `contentTime`.
- One content timeline child, then two or more `<Warp time=".." contentTime=".."/>` events.
- Between events, time is **linearly interpolated**. A fixed speed needs two events: `(0, 0)` and
  `(beats length, file length in seconds)`.

```xml
<Clip time="0" duration="8">
  <Warps contentTimeUnit="seconds" timeUnit="beats">
    <Audio channels="1" duration="4.657" sampleRate="44100">
      <File path="samples/dummy.wav"/>
    </Audio>
    <Warp time="0" contentTime="0"/>
    <Warp time="8" contentTime="4.657"/>
  </Warps>
</Clip>
```

### Markers

`Markers` (timeline) contains one or more `<Marker time=".." name=".." color=".."/>`. Markers
are points in time; there is no duration or range.

### `Points` (automation and expression)

A timeline of automation points aimed at one target.

| Member | Meaning |
|---|---|
| `<Target>` (required) | AutomationTarget, see below |
| `@unit` | Unit of `RealPoint` values; should be given when real points are used |
| points | All of the same type, matching the target |

Point types (all have `time`, in the timeline's unit):

| Element | Value |
|---|---|
| `RealPoint` | `value` (double), `interpolation` = `hold` or `linear` for the segment **starting** at this point; default `hold` |
| `BoolPoint` | `value` (bool) |
| `IntegerPoint` | `value` (int) |
| `EnumPoint` | `value` (int index) |
| `TimeSignaturePoint` | `numerator`, `denominator` |

There are no curve shapes beyond `hold` and `linear`.

**AutomationTarget** points either at a parameter or at an expression:

| Attribute | Meaning |
|---|---|
| `parameter` | IDREF to any Parameter (channel Volume/Pan/Mute, a Send's Volume, a device parameter, Tempo…) |
| `expression` | `gain`, `pan`, `transpose`, `timbre`, `formant`, `pressure` (per-note/MPE-style), `channelController`, `channelPressure`, `polyPressure`, `pitchBend`, `programChange` (MIDI) |
| `channel` | MIDI channel |
| `key` | MIDI key, for `polyPressure` |
| `controller` | CC number (0-based), for `channelController` |

Placement:

- **Track automation**: a `Points` directly in the track's `Lanes` (or with `track="…"`).
- **Clip automation**: `Points` as the content of a `Clip`, for example MIDI CC1 or pitch bend
  in a clip. Upstream tests generate both variants.
- **Per-note expression**: `Points` inside a `Note`, times relative to the note.
- **Tempo and time signature**: `Arrangement/TempoAutomation` (`RealPoint`s, bpm; this defines
  the beats↔seconds conversion at the root) and `Arrangement/TimeSignatureAutomation`
  (`TimeSignaturePoint`s).

## Clip launcher: `Scene` and `ClipSlot`

`Project/Scenes` holds `Scene` elements (Referenceable). Each has one content timeline, usually:

```xml
<Scene>
  <Lanes>
    <ClipSlot track="...">
      <Clip>...</Clip>
    </ClipSlot>
  </Lanes>
</Scene>
```

`ClipSlot` (Timeline, bound to a track) contains 0..1 `Clip`. `@hasStop`: launching an empty slot
stops that track.

## `metadata.xml`

`<MetaData>` with optional string elements: `Title`, `Artist`, `Album`, `OriginalArtist`,
`Composer`, `Songwriter`, `Producer`, `Arranger`, `Year`, `Genre`, `Copyright`, `Website`,
`Comment`.

## Example: `project.xml` from Bitwig Studio 5.0

One instrument track (Surge XT, CLAP), one audio track and the master. The audio clip nests a
`Clips` timeline of audio events, warped from seconds onto beats.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Project version="1.0">
  <Application name="Bitwig Studio" version="5.0"/>
  <Transport>
    <Tempo max="666.000000" min="20.000000" unit="bpm" value="149.000000" id="id0" name="Tempo"/>
    <TimeSignature denominator="4" numerator="4" id="id1"/>
  </Transport>
  <Structure>
    <Track contentType="notes" loaded="true" id="id2" name="Bass" color="#a2eabf">
      <Channel audioChannels="2" destination="id15" role="regular" solo="false" id="id3">
        <Devices>
          <ClapPlugin deviceID="org.surge-synth-team.surge-xt" deviceName="Surge XT" deviceRole="instrument" loaded="true" id="id7" name="Surge XT">
            <Parameters/>
            <Enabled value="true" id="id8" name="On/Off"/>
            <State path="plugins/d19b1f6e-bbb6-42fe-a6c9-54b41d97a05d.clap-preset"/>
          </ClapPlugin>
        </Devices>
        <Mute value="false" id="id6" name="Mute"/>
        <Pan max="1.000000" min="0.000000" unit="normalized" value="0.500000" id="id5" name="Pan"/>
        <Volume max="2.000000" min="0.000000" unit="linear" value="0.659140" id="id4" name="Volume"/>
      </Channel>
    </Track>
    <Track contentType="audio" loaded="true" id="id9" name="Drumloop" color="#b53bba">
      <Channel audioChannels="2" destination="id15" role="regular" solo="false" id="id10">
        <Mute value="false" id="id13" name="Mute"/>
        <Pan max="1.000000" min="0.000000" unit="normalized" value="0.500000" id="id12" name="Pan"/>
        <Volume max="2.000000" min="0.000000" unit="linear" value="0.177125" id="id11" name="Volume"/>
      </Channel>
    </Track>
    <Track contentType="audio notes" loaded="true" id="id14" name="Master">
      <Channel audioChannels="2" role="master" solo="false" id="id15">
        <Mute value="false" id="id18" name="Mute"/>
        <Pan max="1.000000" min="0.000000" unit="normalized" value="0.500000" id="id17" name="Pan"/>
        <Volume max="2.000000" min="0.000000" unit="linear" value="1.000000" id="id16" name="Volume"/>
      </Channel>
    </Track>
  </Structure>
  <Arrangement id="id19">
    <Lanes timeUnit="beats" id="id20">
      <Lanes track="id2" id="id21">
        <Clips id="id22">
          <Clip time="0.0" duration="8.0" playStart="0.0">
            <Notes id="id23">
              <Note time="0.000000" duration="0.250000" channel="0" key="65" vel="0.787402" rel="0.787402"/>
              <Note time="1.000000" duration="0.250000" channel="0" key="65" vel="0.787402" rel="0.787402"/>
              <Note time="1.500000" duration="2.500000" channel="0" key="53" vel="0.787402" rel="0.787402"/>
              <!-- remaining notes trimmed -->
            </Notes>
          </Clip>
        </Clips>
      </Lanes>
      <Lanes track="id9" id="id24">
        <Clips id="id25">
          <Clip time="0.0" duration="8.00003433227539" playStart="0.0" loopStart="0.0" loopEnd="8.00003433227539" fadeTimeUnit="beats" fadeInTime="0.0" fadeOutTime="0.0" name="Drumfunk3 170bpm">
            <Clips id="id26">
              <Clip time="0.0" duration="8.00003433227539" contentTimeUnit="beats" playStart="0.0" fadeTimeUnit="beats" fadeInTime="0.0" fadeOutTime="0.0">
                <Warps contentTimeUnit="seconds" timeUnit="beats" id="id28">
                  <Audio algorithm="stretch" channels="2" duration="2.823541666666667" sampleRate="48000" id="id27">
                    <File path="audio/Drumfunk3 170bpm.wav"/>
                  </Audio>
                  <Warp time="0.0" contentTime="0.0"/>
                  <Warp time="8.00003433227539" contentTime="2.823541666666667"/>
                </Warps>
              </Clip>
            </Clips>
          </Clip>
        </Clips>
      </Lanes>
      <Lanes track="id14" id="id29">
        <Clips id="id30"/>
      </Lanes>
    </Lanes>
  </Arrangement>
  <Scenes/>
</Project>
```

## Implementation notes

- IDs are document-scoped `xs:ID` strings (Bitwig uses `id0`, `id1`, …). Build an ID → element
  map first on import, since IDREFs can point forward.
- Time units can change at every level (`timeUnit` on timelines, `contentTimeUnit` on clips and
  warps). Resolve them recursively; the default is `beats`. Converting `seconds` to beats needs
  the tempo map (`TempoAutomation`, or the static `Transport/Tempo`).
- Automation values use the parameter's real `unit`, not normalized values. Converting to and
  from a normalized range needs the target parameter's `min`/`max` and its curve (e.g. dB vs
  linear gain).
- Element order inside `Referenceable` subclasses is alphabetical in the Java DOM
  (`@XmlAccessorOrder(ALPHABETICAL)`), which is why Bitwig writes `Mute`, `Pan`, `Volume` in that
  order. The XSD sequences follow that order; a strict validator will enforce it.
- The upstream `test-data/` and `DawProjectTest.java` generate reference files (cue markers,
  clips, audio with warps, notes, automation, alias clips, plug-ins, MIDI CC1 and pitch-bend
  automation both on tracks and in clips). They are good import test fixtures.

## Appendix A: `Project.xsd` (verbatim)

```xml
<?xml version="1.0" standalone="yes"?>
<xs:schema version="1.0" xmlns:xs="http://www.w3.org/2001/XMLSchema">

  <xs:element name="Arrangement" type="arrangement"/>
  <xs:element name="AuPlugin" type="auPlugin"/>
  <xs:element name="Audio" type="audio"/>
  <xs:element name="BoolParameter" type="boolParameter"/>
  <xs:element name="BoolPoint" type="boolPoint"/>
  <xs:element name="BuiltinDevice" type="builtinDevice"/>
  <xs:element name="Channel" type="channel"/>
  <xs:element name="ClapPlugin" type="clapPlugin"/>
  <xs:element name="Clip" type="clip"/>
  <xs:element name="ClipSlot" type="clipSlot"/>
  <xs:element name="Clips" type="clips"/>
  <xs:element name="Compressor" type="compressor"/>
  <xs:element name="Device" type="device"/>
  <xs:element name="EnumParameter" type="enumParameter"/>
  <xs:element name="EnumPoint" type="enumPoint"/>
  <xs:element name="Equalizer" type="equalizer"/>
  <xs:element name="IntegerParameter" type="integerParameter"/>
  <xs:element name="IntegerPoint" type="integerPoint"/>
  <xs:element name="Lanes" type="lanes"/>
  <xs:element name="Limiter" type="limiter"/>
  <xs:element name="Marker" type="marker"/>
  <xs:element name="NoiseGate" type="noiseGate"/>
  <xs:element name="Note" type="note"/>
  <xs:element name="Notes" type="notes"/>
  <xs:element name="Point" type="point"/>
  <xs:element name="Points" type="points"/>
  <xs:element name="Project" type="project"/>
  <xs:element name="RealParameter" type="realParameter"/>
  <xs:element name="RealPoint" type="realPoint"/>
  <xs:element name="Scene" type="scene"/>
  <xs:element name="TimeSignatureParameter" type="timeSignatureParameter"/>
  <xs:element name="TimeSignaturePoint" type="timeSignaturePoint"/>
  <xs:element name="Timeline" type="timeline"/>
  <xs:element name="Track" type="track"/>
  <xs:element name="Video" type="video"/>
  <xs:element name="Vst2Plugin" type="vst2Plugin"/>
  <xs:element name="Vst3Plugin" type="vst3Plugin"/>
  <xs:element name="Warp" type="warp"/>
  <xs:element name="Warps" type="warps"/>
  <xs:element name="markers" type="markers"/>
  <xs:element name="parameter" type="parameter"/>

  <xs:complexType name="project">
    <xs:sequence>
      <xs:element name="Application" type="application"/>
      <xs:element name="Transport" type="transport" minOccurs="0"/>
      <xs:element name="Structure" minOccurs="0">
        <xs:complexType>
          <xs:sequence>
            <xs:choice minOccurs="0" maxOccurs="unbounded">
              <xs:element ref="Track"/>
              <xs:element ref="Channel"/>
            </xs:choice>
          </xs:sequence>
        </xs:complexType>
      </xs:element>
      <xs:element ref="Arrangement" minOccurs="0"/>
      <xs:element name="Scenes" minOccurs="0">
        <xs:complexType>
          <xs:sequence>
            <xs:element ref="Scene" minOccurs="0" maxOccurs="unbounded"/>
          </xs:sequence>
        </xs:complexType>
      </xs:element>
    </xs:sequence>
    <xs:attribute name="version" type="xs:string" use="required"/>
  </xs:complexType>

  <xs:complexType name="application">
    <xs:sequence/>
    <xs:attribute name="name" type="xs:string" use="required"/>
    <xs:attribute name="version" type="xs:string" use="required"/>
  </xs:complexType>

  <xs:complexType name="transport">
    <xs:sequence>
      <xs:element name="Tempo" type="realParameter" minOccurs="0"/>
      <xs:element name="TimeSignature" type="timeSignatureParameter" minOccurs="0"/>
    </xs:sequence>
  </xs:complexType>

  <xs:complexType name="realParameter">
    <xs:complexContent>
      <xs:extension base="parameter">
        <xs:sequence/>
        <xs:attribute name="max" type="xs:string"/>
        <xs:attribute name="min" type="xs:string"/>
        <xs:attribute name="unit" type="unit" use="required"/>
        <xs:attribute name="value" type="xs:string"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="parameter" abstract="true">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:sequence/>
        <xs:attribute name="parameterID" type="xs:int"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="referenceable" abstract="true">
    <xs:complexContent>
      <xs:extension base="nameable">
        <xs:sequence/>
        <xs:attribute name="id" type="xs:ID"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="nameable" abstract="true">
    <xs:sequence/>
    <xs:attribute name="name" type="xs:string"/>
    <xs:attribute name="color" type="xs:string"/>
    <xs:attribute name="comment" type="xs:string"/>
  </xs:complexType>

  <xs:complexType name="boolParameter">
    <xs:complexContent>
      <xs:extension base="parameter">
        <xs:sequence/>
        <xs:attribute name="value" type="xs:boolean"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="integerParameter">
    <xs:complexContent>
      <xs:extension base="parameter">
        <xs:sequence/>
        <xs:attribute name="max" type="xs:int"/>
        <xs:attribute name="min" type="xs:int"/>
        <xs:attribute name="value" type="xs:int"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="enumParameter">
    <xs:complexContent>
      <xs:extension base="parameter">
        <xs:sequence/>
        <xs:attribute name="count" type="xs:int" use="required"/>
        <xs:attribute name="labels">
          <xs:simpleType>
            <xs:list itemType="xs:string"/>
          </xs:simpleType>
        </xs:attribute>
        <xs:attribute name="value" type="xs:int"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="timeSignatureParameter">
    <xs:complexContent>
      <xs:extension base="parameter">
        <xs:sequence/>
        <xs:attribute name="denominator" type="xs:int" use="required"/>
        <xs:attribute name="numerator" type="xs:int" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="lane" abstract="true">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:sequence/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="arrangement">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:sequence>
          <xs:element ref="Lanes" minOccurs="0"/>
          <xs:element name="Markers" type="markers" minOccurs="0"/>
          <xs:element name="TempoAutomation" type="points" minOccurs="0"/>
          <xs:element name="TimeSignatureAutomation" type="points" minOccurs="0"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="lanes">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:choice minOccurs="0" maxOccurs="unbounded">
            <xs:element ref="Timeline"/>
            <xs:element ref="Lanes"/>
            <xs:element ref="Notes"/>
            <xs:element ref="Clips"/>
            <xs:element ref="ClipSlot"/>
            <xs:element ref="markers"/>
            <xs:element ref="Warps"/>
            <xs:element ref="Audio"/>
            <xs:element ref="Video"/>
            <xs:element ref="Points"/>
          </xs:choice>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="timeline" abstract="true">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:sequence/>
        <xs:attribute name="timeUnit" type="timeUnit"/>
        <xs:attribute name="track" type="xs:IDREF"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="track">
    <xs:complexContent>
      <xs:extension base="lane">
        <xs:sequence>
          <xs:element ref="Channel" minOccurs="0"/>
          <xs:element ref="Track" minOccurs="0" maxOccurs="unbounded"/>
        </xs:sequence>
        <xs:attribute name="contentType">
          <xs:simpleType>
            <xs:list itemType="contentType"/>
          </xs:simpleType>
        </xs:attribute>
        <xs:attribute name="loaded" type="xs:boolean"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="channel">
    <xs:complexContent>
      <xs:extension base="lane">
        <xs:sequence>
          <xs:element name="Devices" minOccurs="0">
            <xs:complexType>
              <xs:sequence>
                <xs:choice minOccurs="0" maxOccurs="unbounded">
                  <xs:element ref="Device"/>
                  <xs:element ref="Vst2Plugin"/>
                  <xs:element ref="Vst3Plugin"/>
                  <xs:element ref="ClapPlugin"/>
                  <xs:element ref="BuiltinDevice"/>
                  <xs:element ref="Equalizer"/>
                  <xs:element ref="Compressor"/>
                  <xs:element ref="NoiseGate"/>
                  <xs:element ref="Limiter"/>
                  <xs:element ref="AuPlugin"/>
                </xs:choice>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
          <xs:element name="Mute" type="boolParameter" minOccurs="0"/>
          <xs:element name="Pan" type="realParameter" minOccurs="0"/>
          <xs:element name="Sends" minOccurs="0">
            <xs:complexType>
              <xs:sequence>
                <xs:element name="Send" type="send" minOccurs="0" maxOccurs="unbounded"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
          <xs:element name="Volume" type="realParameter" minOccurs="0"/>
        </xs:sequence>
        <xs:attribute name="audioChannels" type="xs:int"/>
        <xs:attribute name="destination" type="xs:IDREF"/>
        <xs:attribute name="role" type="mixerRole"/>
        <xs:attribute name="solo" type="xs:boolean"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="device">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:sequence>
          <xs:element name="Parameters" minOccurs="0">
            <xs:complexType>
              <xs:sequence>
                <xs:choice minOccurs="0" maxOccurs="unbounded">
                  <xs:element ref="parameter"/>
                  <xs:element ref="RealParameter"/>
                  <xs:element ref="BoolParameter"/>
                  <xs:element ref="IntegerParameter"/>
                  <xs:element ref="EnumParameter"/>
                  <xs:element ref="TimeSignatureParameter"/>
                </xs:choice>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
          <xs:element name="Enabled" type="boolParameter" minOccurs="0"/>
          <xs:element name="State" type="fileReference" minOccurs="0"/>
        </xs:sequence>
        <xs:attribute name="deviceID" type="xs:string"/>
        <xs:attribute name="deviceName" type="xs:string" use="required"/>
        <xs:attribute name="deviceRole" type="deviceRole" use="required"/>
        <xs:attribute name="deviceVendor" type="xs:string"/>
        <xs:attribute name="loaded" type="xs:boolean"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="fileReference">
    <xs:sequence/>
    <xs:attribute name="path" type="xs:string" use="required"/>
    <xs:attribute name="external" type="xs:boolean"/>
  </xs:complexType>

  <xs:complexType name="vst2Plugin">
    <xs:complexContent>
      <xs:extension base="plugin">
        <xs:sequence/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="plugin" abstract="true">
    <xs:complexContent>
      <xs:extension base="device">
        <xs:sequence/>
        <xs:attribute name="pluginVersion" type="xs:string"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="vst3Plugin">
    <xs:complexContent>
      <xs:extension base="plugin">
        <xs:sequence/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="clapPlugin">
    <xs:complexContent>
      <xs:extension base="plugin">
        <xs:sequence/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="builtinDevice">
    <xs:complexContent>
      <xs:extension base="device">
        <xs:sequence/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="equalizer">
    <xs:complexContent>
      <xs:extension base="builtinDevice">
        <xs:sequence>
          <xs:element name="Band" type="eqBand" minOccurs="0" maxOccurs="unbounded"/>
          <xs:element name="InputGain" type="realParameter" minOccurs="0"/>
          <xs:element name="OutputGain" type="realParameter" minOccurs="0"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="eqBand">
    <xs:sequence>
      <xs:element name="Freq" type="realParameter"/>
      <xs:element name="Gain" type="realParameter" minOccurs="0"/>
      <xs:element name="Q" type="realParameter" minOccurs="0"/>
      <xs:element name="Enabled" type="boolParameter" minOccurs="0"/>
    </xs:sequence>
    <xs:attribute name="type" type="eqBandType" use="required"/>
    <xs:attribute name="order" type="xs:int"/>
  </xs:complexType>

  <xs:complexType name="compressor">
    <xs:complexContent>
      <xs:extension base="builtinDevice">
        <xs:sequence>
          <xs:element name="Attack" type="realParameter" minOccurs="0"/>
          <xs:element name="AutoMakeup" type="boolParameter" minOccurs="0"/>
          <xs:element name="InputGain" type="realParameter" minOccurs="0"/>
          <xs:element name="OutputGain" type="realParameter" minOccurs="0"/>
          <xs:element name="Ratio" type="realParameter" minOccurs="0"/>
          <xs:element name="Release" type="realParameter" minOccurs="0"/>
          <xs:element name="Threshold" type="realParameter" minOccurs="0"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="noiseGate">
    <xs:complexContent>
      <xs:extension base="builtinDevice">
        <xs:sequence>
          <xs:element name="Attack" type="realParameter" minOccurs="0"/>
          <xs:element name="Range" type="realParameter" minOccurs="0"/>
          <xs:element name="Ratio" type="realParameter" minOccurs="0"/>
          <xs:element name="Release" type="realParameter" minOccurs="0"/>
          <xs:element name="Threshold" type="realParameter" minOccurs="0"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="limiter">
    <xs:complexContent>
      <xs:extension base="builtinDevice">
        <xs:sequence>
          <xs:element name="Attack" type="realParameter" minOccurs="0"/>
          <xs:element name="InputGain" type="realParameter" minOccurs="0"/>
          <xs:element name="OutputGain" type="realParameter" minOccurs="0"/>
          <xs:element name="Release" type="realParameter" minOccurs="0"/>
          <xs:element name="Threshold" type="realParameter" minOccurs="0"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="auPlugin">
    <xs:complexContent>
      <xs:extension base="plugin">
        <xs:sequence/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="send">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:sequence>
          <xs:element name="Enable" type="boolParameter" minOccurs="0"/>
          <xs:element name="Pan" type="realParameter" minOccurs="0"/>
          <xs:element name="Volume" type="realParameter"/>
        </xs:sequence>
        <xs:attribute name="destination" type="xs:IDREF"/>
        <xs:attribute name="type" type="sendType"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="note" final="extension restriction">
    <xs:sequence>
      <xs:choice minOccurs="0">
        <xs:element ref="Timeline"/>
        <xs:element ref="Lanes"/>
        <xs:element ref="Notes"/>
        <xs:element ref="Clips"/>
        <xs:element ref="ClipSlot"/>
        <xs:element ref="markers"/>
        <xs:element ref="Warps"/>
        <xs:element ref="Audio"/>
        <xs:element ref="Video"/>
        <xs:element ref="Points"/>
      </xs:choice>
    </xs:sequence>
    <xs:attribute name="time" type="xs:string" use="required"/>
    <xs:attribute name="duration" type="xs:string" use="required"/>
    <xs:attribute name="channel" type="xs:int" use="required"/>
    <xs:attribute name="key" type="xs:int" use="required"/>
    <xs:attribute name="vel" type="xs:string"/>
    <xs:attribute name="rel" type="xs:string"/>
  </xs:complexType>

  <xs:complexType name="notes">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:element ref="Note" minOccurs="0" maxOccurs="unbounded"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="clip">
    <xs:complexContent>
      <xs:extension base="nameable">
        <xs:sequence>
          <xs:choice minOccurs="0">
            <xs:element ref="Timeline"/>
            <xs:element ref="Lanes"/>
            <xs:element ref="Notes"/>
            <xs:element ref="Clips"/>
            <xs:element ref="ClipSlot"/>
            <xs:element ref="markers"/>
            <xs:element ref="Warps"/>
            <xs:element ref="Audio"/>
            <xs:element ref="Video"/>
            <xs:element ref="Points"/>
          </xs:choice>
        </xs:sequence>
        <xs:attribute name="time" type="xs:double" use="required"/>
        <xs:attribute name="duration" type="xs:double"/>
        <xs:attribute name="contentTimeUnit" type="timeUnit"/>
        <xs:attribute name="playStart" type="xs:double"/>
        <xs:attribute name="playStop" type="xs:double"/>
        <xs:attribute name="loopStart" type="xs:double"/>
        <xs:attribute name="loopEnd" type="xs:double"/>
        <xs:attribute name="fadeTimeUnit" type="timeUnit"/>
        <xs:attribute name="fadeInTime" type="xs:double"/>
        <xs:attribute name="fadeOutTime" type="xs:double"/>
        <xs:attribute name="enable" type="xs:boolean"/>
        <xs:attribute name="reference" type="xs:IDREF"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="clips">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:element ref="Clip" minOccurs="0" maxOccurs="unbounded"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="clipSlot">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:element ref="Clip" minOccurs="0"/>
        </xs:sequence>
        <xs:attribute name="hasStop" type="xs:boolean"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="marker">
    <xs:complexContent>
      <xs:extension base="nameable">
        <xs:sequence/>
        <xs:attribute name="time" type="xs:double" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="markers">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:element ref="Marker" maxOccurs="unbounded"/>
        </xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="warps">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:choice>
            <xs:element ref="Timeline"/>
            <xs:element ref="Lanes"/>
            <xs:element ref="Notes"/>
            <xs:element ref="Clips"/>
            <xs:element ref="ClipSlot"/>
            <xs:element ref="markers"/>
            <xs:element ref="Warps"/>
            <xs:element ref="Audio"/>
            <xs:element ref="Video"/>
            <xs:element ref="Points"/>
          </xs:choice>
          <xs:element ref="Warp" maxOccurs="unbounded"/>
        </xs:sequence>
        <xs:attribute name="contentTimeUnit" type="timeUnit" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="warp">
    <xs:sequence/>
    <xs:attribute name="time" type="xs:double" use="required"/>
    <xs:attribute name="contentTime" type="xs:double" use="required"/>
  </xs:complexType>

  <xs:complexType name="audio">
    <xs:complexContent>
      <xs:extension base="mediaFile">
        <xs:sequence/>
        <xs:attribute name="algorithm" type="xs:string"/>
        <xs:attribute name="channels" type="xs:int" use="required"/>
        <xs:attribute name="sampleRate" type="xs:int" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="mediaFile">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:element name="File" type="fileReference"/>
        </xs:sequence>
        <xs:attribute name="duration" type="xs:double" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="video">
    <xs:complexContent>
      <xs:extension base="mediaFile">
        <xs:sequence/>
        <xs:attribute name="algorithm" type="xs:string"/>
        <xs:attribute name="channels" type="xs:int" use="required"/>
        <xs:attribute name="sampleRate" type="xs:int" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="point" abstract="true">
    <xs:sequence/>
    <xs:attribute name="time" type="xs:string" use="required"/>
  </xs:complexType>

  <xs:complexType name="realPoint">
    <xs:complexContent>
      <xs:extension base="point">
        <xs:sequence/>
        <xs:attribute name="value" type="xs:string" use="required"/>
        <xs:attribute name="interpolation" type="interpolation"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="enumPoint">
    <xs:complexContent>
      <xs:extension base="point">
        <xs:sequence/>
        <xs:attribute name="value" type="xs:int" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="boolPoint">
    <xs:complexContent>
      <xs:extension base="point">
        <xs:sequence/>
        <xs:attribute name="value" type="xs:boolean" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="integerPoint">
    <xs:complexContent>
      <xs:extension base="point">
        <xs:sequence/>
        <xs:attribute name="value" type="xs:int" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="timeSignaturePoint">
    <xs:complexContent>
      <xs:extension base="point">
        <xs:sequence/>
        <xs:attribute name="numerator" type="xs:int" use="required"/>
        <xs:attribute name="denominator" type="xs:int" use="required"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="points">
    <xs:complexContent>
      <xs:extension base="timeline">
        <xs:sequence>
          <xs:element name="Target" type="automationTarget"/>
          <xs:choice minOccurs="0" maxOccurs="unbounded">
            <xs:element ref="Point"/>
            <xs:element ref="RealPoint"/>
            <xs:element ref="EnumPoint"/>
            <xs:element ref="BoolPoint"/>
            <xs:element ref="IntegerPoint"/>
            <xs:element ref="TimeSignaturePoint"/>
          </xs:choice>
        </xs:sequence>
        <xs:attribute name="unit" type="unit"/>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:complexType name="automationTarget">
    <xs:sequence/>
    <xs:attribute name="parameter" type="xs:IDREF"/>
    <xs:attribute name="expression" type="expressionType"/>
    <xs:attribute name="channel" type="xs:int"/>
    <xs:attribute name="key" type="xs:int"/>
    <xs:attribute name="controller" type="xs:int"/>
  </xs:complexType>

  <xs:complexType name="scene">
    <xs:complexContent>
      <xs:extension base="referenceable">
        <xs:choice>
          <xs:element ref="Timeline"/>
          <xs:element ref="Lanes"/>
          <xs:element ref="Notes"/>
          <xs:element ref="Clips"/>
          <xs:element ref="ClipSlot"/>
          <xs:element ref="markers"/>
          <xs:element ref="Warps"/>
          <xs:element ref="Audio"/>
          <xs:element ref="Video"/>
          <xs:element ref="Points"/>
        </xs:choice>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>

  <xs:simpleType name="unit">
    <xs:restriction base="xs:string">
      <xs:enumeration value="linear"/>
      <xs:enumeration value="normalized"/>
      <xs:enumeration value="percent"/>
      <xs:enumeration value="decibel"/>
      <xs:enumeration value="hertz"/>
      <xs:enumeration value="semitones"/>
      <xs:enumeration value="seconds"/>
      <xs:enumeration value="beats"/>
      <xs:enumeration value="bpm"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="timeUnit">
    <xs:restriction base="xs:string">
      <xs:enumeration value="beats"/>
      <xs:enumeration value="seconds"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="deviceRole">
    <xs:restriction base="xs:string">
      <xs:enumeration value="instrument"/>
      <xs:enumeration value="noteFX"/>
      <xs:enumeration value="audioFX"/>
      <xs:enumeration value="analyzer"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="eqBandType">
    <xs:restriction base="xs:string">
      <xs:enumeration value="highPass"/>
      <xs:enumeration value="lowPass"/>
      <xs:enumeration value="bandPass"/>
      <xs:enumeration value="highShelf"/>
      <xs:enumeration value="lowShelf"/>
      <xs:enumeration value="bell"/>
      <xs:enumeration value="notch"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="mixerRole">
    <xs:restriction base="xs:string">
      <xs:enumeration value="regular"/>
      <xs:enumeration value="master"/>
      <xs:enumeration value="effect"/>
      <xs:enumeration value="submix"/>
      <xs:enumeration value="vca"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="sendType">
    <xs:restriction base="xs:string">
      <xs:enumeration value="pre"/>
      <xs:enumeration value="post"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="contentType">
    <xs:restriction base="xs:string">
      <xs:enumeration value="audio"/>
      <xs:enumeration value="automation"/>
      <xs:enumeration value="notes"/>
      <xs:enumeration value="video"/>
      <xs:enumeration value="markers"/>
      <xs:enumeration value="tracks"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="interpolation">
    <xs:restriction base="xs:string">
      <xs:enumeration value="hold"/>
      <xs:enumeration value="linear"/>
    </xs:restriction>
  </xs:simpleType>

  <xs:simpleType name="expressionType">
    <xs:restriction base="xs:string">
      <xs:enumeration value="gain"/>
      <xs:enumeration value="pan"/>
      <xs:enumeration value="transpose"/>
      <xs:enumeration value="timbre"/>
      <xs:enumeration value="formant"/>
      <xs:enumeration value="pressure"/>
      <xs:enumeration value="channelController"/>
      <xs:enumeration value="channelPressure"/>
      <xs:enumeration value="polyPressure"/>
      <xs:enumeration value="pitchBend"/>
      <xs:enumeration value="programChange"/>
    </xs:restriction>
  </xs:simpleType>
</xs:schema>
```

## Appendix B: `MetaData.xsd` (verbatim)

```xml
<?xml version="1.0" standalone="yes"?>
<xs:schema version="1.0" xmlns:xs="http://www.w3.org/2001/XMLSchema">

  <xs:element name="MetaData" type="metaData"/>

  <xs:complexType name="metaData">
    <xs:sequence>
      <xs:element name="Title" type="xs:string" minOccurs="0"/>
      <xs:element name="Artist" type="xs:string" minOccurs="0"/>
      <xs:element name="Album" type="xs:string" minOccurs="0"/>
      <xs:element name="OriginalArtist" type="xs:string" minOccurs="0"/>
      <xs:element name="Composer" type="xs:string" minOccurs="0"/>
      <xs:element name="Songwriter" type="xs:string" minOccurs="0"/>
      <xs:element name="Producer" type="xs:string" minOccurs="0"/>
      <xs:element name="Arranger" type="xs:string" minOccurs="0"/>
      <xs:element name="Year" type="xs:string" minOccurs="0"/>
      <xs:element name="Genre" type="xs:string" minOccurs="0"/>
      <xs:element name="Copyright" type="xs:string" minOccurs="0"/>
      <xs:element name="Website" type="xs:string" minOccurs="0"/>
      <xs:element name="Comment" type="xs:string" minOccurs="0"/>
    </xs:sequence>
  </xs:complexType>
</xs:schema>
```
