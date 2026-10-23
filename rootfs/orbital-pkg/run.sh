#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEFAULT_QT_SCALE_FACTOR="2.2"
# Stable by-name links from 70-sirius-input.rules: eventN numbers move when a
# new input device probes, so never hardcode them here.
DEFAULT_TOUCH_INPUT_PATH="/dev/input/sirius-touch"
DEFAULT_POWER_KEY_PATH="/dev/input/sirius-power"
DEFAULT_VOLUME_KEY_PATH="/dev/input/sirius-vol-up,/dev/input/sirius-vol-down"

SCALE_VALUE="${QT_SCALE_FACTOR:-$DEFAULT_QT_SCALE_FACTOR}"
TOUCH_INPUT_PATH="${ORBITAL_TOUCH_INPUT_PATH:-$DEFAULT_TOUCH_INPUT_PATH}"
TOUCH_INHIBIT_PATH="${ORBITAL_TOUCH_INHIBIT_PATH:-}"
POWER_KEY_PATH="${ORBITAL_POWER_KEY_PATH:-$DEFAULT_POWER_KEY_PATH}"
VOLUME_KEY_PATH="${ORBITAL_VOLUME_KEY_PATH:-$DEFAULT_VOLUME_KEY_PATH}"
SCREENSHOT_DIR="${ORBITAL_SCREENSHOT_DIR:-}"
VOLUME_KEY_PATH_EXPLICIT=0

if [[ -n "${ORBITAL_VOLUME_KEY_PATH:-}" ]]; then
    VOLUME_KEY_PATH_EXPLICIT=1
fi

print_usage() {
    cat <<'EOF'
Usage: ./run.sh [options]

Options:
  --scale <value>                Set QT scale factor.
  --touch-input-path <path>      Set the evdev touch input path.
  --touch-inhibit-path <path>    Set the touch inhibit sysfs path.
  --power-key-path <path>        Set the power key input path.
  --volume-key-path <path>       Set the volume key input path.
  --screenshot-dir <path>        Set the screenshot output directory.
  -h, --help                     Show this help message.
EOF
}

require_value() {
    local option_name="$1"
    local option_value="$2"

    if [[ -z "$option_value" ]]; then
        echo "Missing value for ${option_name}" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scale)
            require_value "$1" "$2"
            SCALE_VALUE="$2"
            shift 2
            ;;
        --scale=*)
            SCALE_VALUE="${1#*=}"
            require_value "--scale" "$SCALE_VALUE"
            shift
            ;;
        --touch-input-path)
            require_value "$1" "$2"
            TOUCH_INPUT_PATH="$2"
            shift 2
            ;;
        --touch-input-path=*)
            TOUCH_INPUT_PATH="${1#*=}"
            require_value "--touch-input-path" "$TOUCH_INPUT_PATH"
            shift
            ;;
        --touch-inhibit-path)
            require_value "$1" "$2"
            TOUCH_INHIBIT_PATH="$2"
            shift 2
            ;;
        --touch-inhibit-path=*)
            TOUCH_INHIBIT_PATH="${1#*=}"
            require_value "--touch-inhibit-path" "$TOUCH_INHIBIT_PATH"
            shift
            ;;
        --power-key-path)
            require_value "$1" "$2"
            POWER_KEY_PATH="$2"
            if [[ $VOLUME_KEY_PATH_EXPLICIT -eq 0 ]]; then
                VOLUME_KEY_PATH="$POWER_KEY_PATH"
            fi
            shift 2
            ;;
        --power-key-path=*)
            POWER_KEY_PATH="${1#*=}"
            require_value "--power-key-path" "$POWER_KEY_PATH"
            if [[ $VOLUME_KEY_PATH_EXPLICIT -eq 0 ]]; then
                VOLUME_KEY_PATH="$POWER_KEY_PATH"
            fi
            shift
            ;;
        --volume-key-path)
            require_value "$1" "$2"
            VOLUME_KEY_PATH="$2"
            VOLUME_KEY_PATH_EXPLICIT=1
            shift 2
            ;;
        --volume-key-path=*)
            VOLUME_KEY_PATH="${1#*=}"
            require_value "--volume-key-path" "$VOLUME_KEY_PATH"
            VOLUME_KEY_PATH_EXPLICIT=1
            shift
            ;;
        --screenshot-dir)
            require_value "$1" "$2"
            SCREENSHOT_DIR="$2"
            shift 2
            ;;
        --screenshot-dir=*)
            SCREENSHOT_DIR="${1#*=}"
            require_value "--screenshot-dir" "$SCREENSHOT_DIR"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

# Derive the touch inhibit sysfs node from the touch evdev node (the by-name
# link resolves to eventN), so it follows node renumbering.
if [[ -z "$TOUCH_INHIBIT_PATH" ]]; then
    touch_event="$(basename "$(readlink -f "$TOUCH_INPUT_PATH" 2>/dev/null)")"
    if [[ "$touch_event" == event* ]]; then
        TOUCH_INHIBIT_PATH="/sys/class/input/$touch_event/device/inhibited"
    fi
fi

export QT_SCALE_FACTOR="$SCALE_VALUE"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-eglfs}"
export ORBITAL_TOUCH_INPUT_PATH="$TOUCH_INPUT_PATH"
export ORBITAL_TOUCH_INHIBIT_PATH="$TOUCH_INHIBIT_PATH"
export ORBITAL_POWER_KEY_PATH="$POWER_KEY_PATH"
export ORBITAL_VOLUME_KEY_PATH="$VOLUME_KEY_PATH"
export ORBITAL_SCREENSHOT_DIR="$SCREENSHOT_DIR"
export QT_QPA_GENERIC_PLUGINS="evdevtouch:${ORBITAL_TOUCH_INPUT_PATH}"
RESTART_EXIT_CODE=42
while true; do
    ./Orbital
    EXIT_CODE=$?

    if [ $EXIT_CODE -ne $RESTART_EXIT_CODE ]; then
        break
    fi

    sleep 1
done
