// waveform.gdshader
// Draws an audio waveform from WaveformData peak textures, one pixel column at a time.
// Each column covers source frames [start_frame + x*fpp, start_frame + (x+1)*fpp). The shader
// picks the level whose block size is at most fpp, reduces the 1-3 blocks under the column
// (min of mins, max of maxes, RMS of RMS), applies gain/fade/scale and shades the column.
// Frame positions are absolute in the file, so scrolling and trimming never shimmer.
//
// Below the base block size (fpp < base_block), columns inside the loaded raw-sample window
// draw the samples themselves: a line through the sample points, plus dots when zoomed in far
// enough. Columns outside it fall back to the (stepped) base level until the samples arrive.
//
// The quad covers only the visible slice of the view: `rect_size` is the slice's size and
// `frame0` the source frame at its left edge. That keeps every position small enough for
// float precision even when the view is millions of pixels wide at deep zoom.
shader_type canvas_item;
render_mode unshaded;

const int MAX_LEVELS = 24;
const int MAX_FETCHES = 8;

// Plane A: (min, max, rms). Plane B: (low, mid, high) band RMS. _l = first channel, _r = second.
uniform sampler2D plane_a_l : filter_nearest, repeat_disable;
uniform sampler2D plane_b_l : filter_nearest, repeat_disable;
uniform sampler2D plane_a_r : filter_nearest, repeat_disable;
uniform sampler2D plane_b_r : filter_nearest, repeat_disable;

uniform int channels = 1;
uniform int levels = 1;
uniform int tex_width = 4096;
uniform int level_rows[24];
uniform int level_blocks[24];
uniform float base_block = 64.0;
uniform float total_frames = 0.0;

uniform vec2 rect_size = vec2(1.0);
uniform float frame0 = 0.0;
uniform float frames_per_pixel = 64.0;
// Fades are measured from the view's left edge: frames from there to this slice, and the
// view's full length in frames.
uniform float fade_rel0 = 0.0;
uniform float view_frames = 0.0;

// Raw samples: R32F, row width `samples_row`, chunk-major rows (chunk * samples_channels + ch).
uniform sampler2D samples_tex : filter_nearest, repeat_disable;
uniform int samples_channels = 0; // 0 = no samples loaded
uniform int samples_row = 4096;
uniform float samples_len = 0.0;  // frames in the window
// Frame at this slice's left edge, relative to the window start (precise, unlike frame0).
uniform float samples_rel0 = 0.0;

uniform float gain = 1.0;
uniform float fade_in_frames = 0.0;
uniform float fade_out_frames = 0.0;
// Fade shape exponent: 1 = linear, >1 slow start, <1 fast start.
uniform float fade_curve = 1.0;

uniform int channel_mode = 0; // 0 = split, 1 = mono sum
uniform int style = 1;        // 0 = peaks, 1 = peaks + RMS
uniform int color_mode = 0;   // 0 = clip colour, 1 = spectral
uniform int amp_scale = 0;    // 0 = linear, 1 = dB
uniform vec4 color : source_color = vec4(0.35, 0.7, 0.95, 1.0);
// Opacity of the peak region relative to the RMS region in peaks + RMS style.
uniform float peak_alpha = 0.45;

varying vec2 local_pos;

void vertex() {
	local_pos = UV * rect_size;
}

// Per-column reduction of one channel.
struct Col {
	float mn;
	float mx;
	float ms;   // mean square
	vec3 bands; // mean squares
};

ivec2 texel_of(int level, int block) {
	return ivec2(block % tex_width, level_rows[level] + block / tex_width);
}

void reduce(sampler2D pa, sampler2D pb, int level, int b0, int b1, inout Col c, inout int n) {
	int step_b = max(1, (b1 - b0 + MAX_FETCHES) / MAX_FETCHES);
	for (int i = 0; i < MAX_FETCHES; i++) {
		int b = b0 + i * step_b;
		if (b > b1) {
			break;
		}
		ivec2 t = texel_of(level, b);
		vec3 a = texelFetch(pa, t, 0).rgb;
		c.mn = min(c.mn, a.r);
		c.mx = max(c.mx, a.g);
		c.ms += a.b * a.b;
		if (color_mode == 1) {
			vec3 bb = texelFetch(pb, t, 0).rgb;
			c.bands += bb * bb;
		}
		n++;
	}
}

float to_scale(float v) {
	if (amp_scale == 1) {
		float a = abs(v);
		if (a < 1e-6) {
			return 0.0;
		}
		float db = 20.0 * log(a) / log(10.0);
		return sign(v) * clamp((db + 60.0) / 60.0, 0.0, 1.0);
	}
	return v;
}

// Gain envelope at `rel` frames from the view's left edge.
float fade_at(float rel) {
	float g = 1.0;
	if (fade_in_frames > 0.0) {
		g *= pow(clamp(rel / fade_in_frames, 0.0, 1.0), fade_curve);
	}
	if (fade_out_frames > 0.0) {
		float end_rel = view_frames - rel;
		g *= pow(clamp(end_rel / fade_out_frames, 0.0, 1.0), fade_curve);
	}
	return g;
}

vec3 shade(vec3 bands_ms, float inv_n) {
	if (color_mode != 1) {
		return color.rgb;
	}
	vec3 bands = sqrt(bands_ms * inv_n);
	float peak = max(max(bands.r, bands.g), max(bands.b, 1e-6));
	vec3 spec = bands / peak;
	// Match the clip colour's brightness so spectral clips sit with the rest.
	vec3 lw = vec3(0.2126, 0.7152, 0.0722);
	float lum = max(dot(color.rgb, lw), 0.25);
	spec *= lum / max(dot(spec, lw), 1e-3);
	return mix(clamp(spec, 0.0, 1.0), vec3(lum), 0.15);
}

// Pixel-space coverage of [top, bottom] with a one-pixel soft edge.
float span_cov(float py, float top, float bottom) {
	return clamp(min(py - top, bottom - py) + 0.5, 0.0, 1.0);
}

float raw_at(int ch, int i) {
	i = clamp(i, 0, int(samples_len) - 1);
	return texelFetch(samples_tex, ivec2(i % samples_row, (i / samples_row) * samples_channels + ch), 0).r;
}

// Displayed sample value at window-relative frame `i` for this row: one channel, or the mean.
float raw_value(int i, int ch, bool mono) {
	return mono ? 0.5 * (raw_at(0, i) + raw_at(1, i)) : raw_at(ch, i);
}

// The line through the sample points (sample i sits at the centre of its frame, i + 0.5),
// evaluated at window-relative position r.
float raw_line(float r, int ch, bool mono) {
	float p = r - 0.5;
	float fl = floor(p);
	int i = int(fl);
	return mix(raw_value(i, ch, mono), raw_value(i + 1, ch, mono), p - fl);
}

// The envelope path: reduce the peak blocks under column x.
void peaks_column(float x, float fpp, int rows, bool right, float centre, float half_h, float py, inout vec4 out_color) {
	float f0 = floor(frame0 + x * fpp);
	float f1 = max(floor(frame0 + (x + 1.0) * fpp), f0 + 1.0);
	f1 = min(f1, total_frames);

	if (f0 >= 0.0 && f0 < total_frames && levels > 0) {
		// Level with block size <= fpp, so one column spans 1-3 blocks.
		int level = clamp(int(floor(log2(fpp / base_block))), 0, levels - 1);
		float bs = base_block * exp2(float(level));
		int last = level_blocks[level] - 1;
		int b0 = clamp(int(floor(f0 / bs)), 0, last);
		int b1 = clamp(int(floor((f1 - 1.0) / bs)), b0, last);

		Col c = Col(1e9, -1e9, 0.0, vec3(0.0));
		int n = 0;
		if (rows == 1 || !right) {
			reduce(plane_a_l, plane_b_l, level, b0, b1, c, n);
		}
		if (channels > 1 && (rows == 1 || right)) {
			reduce(plane_a_r, plane_b_r, level, b0, b1, c, n);
		}
		float inv_n = 1.0 / float(max(n, 1));
		float g = gain * fade_at(fade_rel0 + (x + 0.5) * fpp);
		float mx = to_scale(c.mx * g);
		float mn = to_scale(c.mn * g);
		float rms = to_scale(sqrt(c.ms * inv_n) * g);
		vec3 rgb = shade(c.bands, inv_n);

		// At least 1 px tall.
		float top = centre - mx * half_h;
		float bottom = centre - mn * half_h;
		if (bottom - top < 1.0) {
			float mid = 0.5 * (top + bottom);
			top = mid - 0.5;
			bottom = mid + 0.5;
		}
		float cov = span_cov(py, top, bottom);
		float alpha = cov;
		if (style == 1) {
			float r_cov = span_cov(py, centre - rms * half_h, centre + rms * half_h);
			alpha = max(cov * peak_alpha, r_cov * cov);
		}
		out_color = vec4(rgb, color.a * alpha);
	}
}

void fragment() {
	COLOR = vec4(0.0);
	float x = floor(local_pos.x);
	float fpp = max(frames_per_pixel, 1e-4);

	// Rows: two for split stereo, else one.
	int rows = (channel_mode == 0 && channels > 1) ? 2 : 1;
	float row_h = rect_size.y / float(rows);
	int row = min(int(local_pos.y / row_h), rows - 1);
	float centre = (float(row) + 0.5) * row_h;
	float half_h = max(row_h * 0.5 - 1.0, 0.5);
	bool right = rows == 2 && row == 1;
	float py = local_pos.y;

	// Raw samples: the column spans window-relative positions [ra, rb].
	float ra = samples_rel0 + x * fpp;
	float rb = ra + fpp;
	bool raw = fpp < base_block && samples_channels > 0 && ra >= 0.0 && rb <= samples_len;
	if (raw) {
		bool mono = rows == 1 && samples_channels > 1;
		int ch = (right && samples_channels > 1) ? 1 : 0;
		float lo = min(raw_line(ra, ch, mono), raw_line(rb, ch, mono));
		float hi = max(raw_line(ra, ch, mono), raw_line(rb, ch, mono));
		// Sample points strictly inside the column (at most ceil(fpp) < 65).
		int i0 = int(floor(ra - 0.5)) + 1;
		for (int k = 0; k < 66; k++) {
			int i = i0 + k;
			if (float(i) + 0.5 >= rb) {
				break;
			}
			float v = raw_value(i, ch, mono);
			lo = min(lo, v);
			hi = max(hi, v);
		}
		float rel = fade_rel0 + (x + 0.5) * fpp;
		float g = gain * fade_at(rel);
		float top = centre - to_scale(hi * g) * half_h - 0.75;
		float bottom = centre - to_scale(lo * g) * half_h + 0.75;
		float alpha = span_cov(py, top, bottom);
		// Dots on the sample points once they are at least 4 px apart.
		if (fpp < 0.25) {
			float pos = (ra + 0.5 * fpp) - 0.5;
			int i = int(floor(pos + 0.5));
			float dx = ((float(i) + 0.5) - (ra + 0.5 * fpp)) / fpp;
			float dy = py - (centre - to_scale(raw_value(i, ch, mono) * g) * half_h);
			float d = length(vec2(dx, dy));
			alpha = max(alpha, clamp(2.5 - d, 0.0, 1.0));
		}
		vec3 bands = vec3(0.0);
		float n = 0.0;
		if (color_mode == 1) {
			// Colour from the base-level band energies of the block under the column.
			int b = clamp(int(floor((frame0 + (x + 0.5) * fpp) / base_block)), 0, level_blocks[0] - 1);
			ivec2 t = texel_of(0, b);
			if (!right || rows == 1) {
				vec3 bb = texelFetch(plane_b_l, t, 0).rgb;
				bands += bb * bb;
				n += 1.0;
			}
			if (channels > 1 && (rows == 1 || right)) {
				vec3 bb = texelFetch(plane_b_r, t, 0).rgb;
				bands += bb * bb;
				n += 1.0;
			}
		}
		COLOR = vec4(shade(bands, 1.0 / max(n, 1.0)), color.a * alpha);
	} else {
		peaks_column(x, fpp, rows, right, centre, half_h, py, COLOR);
	}
}
