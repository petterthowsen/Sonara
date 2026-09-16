#!/usr/bin/env bash
# Fetch lucide icons into Godot/assets/icons, normalised to the project convention
# (no lucide class attr, no license comment, stroke="#ffffff").
set -uo pipefail
cd "$(dirname "$0")"

names=(
  # window controls
  maximize minimize
  # file operations
  file file-plus file-down file-up file-text
  # undo / redo
  undo redo undo-2 redo-2 rotate-ccw rotate-cw
  # knob / adjust / parameter
  sliders-horizontal sliders-vertical gauge circle-gauge settings-2 circle-dot-dashed
  # search / inspect / view / zoom
  eye eye-off zoom-in zoom-out scan-search search-check scan-eye
  # time
  history
  # popup / auxiliary window
  app-window app-window-mac external-link picture-in-picture picture-in-picture-2
  panel-top-open square-arrow-out-up-right square-arrow-out-down-right
  monitor-up gallery-horizontal-end copy-plus
)

for n in "${names[@]}"; do
  out="$n.svg"
  if [[ -f $out ]]; then
    echo "skip   $out (exists)"
    continue
  fi
  body=$(curl -sSL --max-time 25 "https://unpkg.com/lucide-static/icons/$n.svg")
  if [[ $body != *"<svg"* || $body == *"Cannot find"* ]]; then
    echo "FAIL   $n"
    continue
  fi
  # strip license comment, class attr and inner <g> wrapper, force white stroke
  printf '%s\n' "$body" \
    | sed -e '/@license lucide-static/d' \
          -e '/^  class="lucide/d' \
          -e 's/stroke="currentColor"/stroke="#ffffff"/' \
    > "$out"
  echo "wrote  $out"
done
