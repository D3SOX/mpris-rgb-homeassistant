#!/bin/bash

# Common constants
DEBUG_LOG="/tmp/mpris_rgb_debug.log"

# Function to log with timestamp
log_message() {
  local MSG="$1"
  local TIMESTAMP=$(date "+%H:%M:%S")
  
  # Add timestamps to log output
  echo "[$TIMESTAMP] $MSG"
  
  if [ "$VERBOSE_LOGGING" = "true" ]; then
    echo "[$TIMESTAMP] $MSG" >> "$DEBUG_LOG"
  fi
}

# Helper function for HTTP requests to Home Assistant
send_webhook_request() {
  local RGB="$1"
  local TRANSITION_TIME="${2:-1}"
  
  if [ "$VERBOSE_LOGGING" = "true" ]; then
    log_message "Sending color: $RGB with transition: $TRANSITION_TIME"
  fi
  
  # Prepare the JSON payload
  local JSON="{\"rgb\":\"$RGB\",\"transition\":$TRANSITION_TIME}"
  
  # Send the webhook request
  curl -s -X POST -H "Content-Type: application/json" \
       -d "$JSON" "$WEBHOOK_URL" > /dev/null
  
  return $?
}

# Helper function to load environment variables
load_environment() {
  if [ -f .env ]; then
    # Process .env file line by line to properly handle inline comments
    while IFS= read -r line; do
      # Skip empty lines and comment lines
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      # Extract the variable part before any comment
      var=$(echo "$line" | sed -E 's/[[:space:]]*#.*$//' | xargs)
      # Only export if it's a valid variable assignment
      [[ "$var" =~ ^[A-Za-z0-9_]+=.* ]] && export "$var"
    done < .env
    log_message "Loaded environment variables from .env file"
  else
    log_message "Warning: .env file not found, using default values"
  fi
}

# Helper function to validate required environment variables
validate_requirements() {
  local MISSING_VARS=0
  
  if [ -z "$WEBHOOK_URL" ]; then
    log_message "Error: WEBHOOK_URL not defined in .env file"
    MISSING_VARS=1
  fi

  if [ -z "$MUSIC_DIR" ]; then
    log_message "Error: MUSIC_DIR not defined in .env file"
    MISSING_VARS=1
  fi
  
  if [ $MISSING_VARS -ne 0 ]; then
    exit 1
  fi
}

# Helper function to initialize directories
initialize_directories() {
  # Create temp directory
  mkdir -p "$TEMP_DIR"
  if [ ! -d "$TEMP_DIR" ]; then
    log_message "Error: Failed to create temporary directory $TEMP_DIR"
    exit 1
  fi
  
  # Create BPM cache directory
  mkdir -p "$BPM_CACHE_DIR"
}

# Helper function to extract colors from artwork
extract_colors_from_artwork() {
  local ARTWORK_PATH="$1"
  local NUM_COLORS="$2"
  
  if [ ! -f "$ARTWORK_PATH" ]; then
    log_message "Artwork file not found: $ARTWORK_PATH"
    return 1
  fi
  
  # Method 1: Use ImageMagick to extract dominant colors with increased saturation
  local COLORS=""
  
  # First boost saturation before extracting colors to get more vibrant results
  local ENHANCED_ART="$TEMP_DIR/enhanced_artwork.jpg"
  convert "$ARTWORK_PATH" -modulate 100,150,100 -contrast-stretch 3%x15% "$ENHANCED_ART"
  
  # Extract colors from the enhanced artwork
  COLORS=$(convert "$ENHANCED_ART" -resize 100x100 -define histogram:unique-colors=true \
    -format "%c" histogram:info: | sort -nr | head -n "$NUM_COLORS" | \
    grep -oE '#[0-9A-F]{6}' | tr -d '#' | tr '[:lower:]' '[:upper:]')
  
  # If we couldn't get enough colors, try the second method
  if [ "$(echo "$COLORS" | wc -l)" -lt "$NUM_COLORS" ]; then
    log_message "Method 1 didn't extract enough colors, trying method 2"
    
    # Method 2: Use quantization with higher saturation
    COLORS=$(convert "$ENHANCED_ART" -resize 100x100 -colors "$NUM_COLORS" \
      -unique-colors txt:- | grep -v "^#" | grep -oE '#[0-9A-F]{6}' | \
      tr -d '#' | tr '[:lower:]' '[:upper:]')
  fi
  
  # Check for color diversity and generate additional colors if needed
  if [ "$(echo "$COLORS" | wc -l)" -lt "$NUM_COLORS" ]; then
    COLORS=$(ensure_color_diversity "$COLORS" "$NUM_COLORS")
  fi
  
  # Clean up temp file
  rm -f "$ENHANCED_ART" 2>/dev/null
  
  echo "$COLORS"
}

# Helper function to ensure color diversity
ensure_color_diversity() {
  local COLORS="$1"
  local TARGET_COUNT="$2"
  local RESULT_COLORS="$COLORS"
  
  # For each color we need to add
  while [ "$(echo "$RESULT_COLORS" | wc -l)" -lt "$TARGET_COUNT" ]; do
    # Get the first color as a base
    local BASE_COLOR=$(echo "$COLORS" | head -n 1)
    
    # Generate a contrasting color by inverting
    if [ -n "$BASE_COLOR" ]; then
      local R=$(echo "ibase=16; ${BASE_COLOR:0:2}" | bc)
      local G=$(echo "ibase=16; ${BASE_COLOR:2:2}" | bc)
      local B=$(echo "ibase=16; ${BASE_COLOR:4:2}" | bc)
      
      # Invert and adjust
      R=$((255 - R))
      G=$((255 - G))
      B=$((255 - B))
      
      # Convert back to hex
      local CONTRASTING_COLOR=$(printf "%02X%02x%02X" $R $G $B)
      
      # Add to the result
      RESULT_COLORS="$RESULT_COLORS
$CONTRASTING_COLOR"
    else
      # If no base color, add a default
      RESULT_COLORS="$RESULT_COLORS
FF0000"
    fi
  done
  
  echo "$RESULT_COLORS"
}

# Function to calculate BPM-based delay
calculate_bpm_delay() {
  local BPM="$1"
  local DELAY="$ALTERNATION_DELAY"  # Default
  
  if [ -n "$BPM" ] && [ "$BPM" -gt 0 ]; then
    # Map BPM to a delay between MIN_BPM_DELAY and MAX_BPM_DELAY
    # Higher BPM = faster color changes (smaller delay)
    
    # Clamp BPM to our scale range
    if [ "$BPM" -lt "$BPM_SCALE_MIN" ]; then
      BPM=$BPM_SCALE_MIN
    elif [ "$BPM" -gt "$BPM_SCALE_MAX" ]; then
      BPM=$BPM_SCALE_MAX
    fi
    
    # Calculate normalized position in the BPM range (0.0 to 1.0)
    local BPM_RANGE=$((BPM_SCALE_MAX - BPM_SCALE_MIN))
    local NORMALIZED=$(echo "scale=6; ($BPM - $BPM_SCALE_MIN) / $BPM_RANGE" | bc)
    
    # Invert so higher BPM = smaller delay
    local INVERTED=$(echo "scale=6; 1.0 - $NORMALIZED" | bc)
    
    # Map to delay range
    local DELAY_RANGE=$(echo "scale=6; $MAX_BPM_DELAY - $MIN_BPM_DELAY" | bc)
    DELAY=$(echo "scale=3; $MIN_BPM_DELAY + ($INVERTED * $DELAY_RANGE)" | bc)
    
    log_message "BPM $BPM maps to delay: ${DELAY}s"
  else
    log_message "No valid BPM, using default delay: ${DELAY}s"
  fi
  
  echo "$DELAY"
}

# Load environment and initialize
load_environment

# Configuration variables - use environment variables or defaults
POLL_INTERVAL=${POLL_INTERVAL:-2}  # Main polling interval for checking media players
ALTERNATION_DELAY=${ALTERNATION_DELAY:-1.0}  # Default delay between color alternations (slower by default)
TEMP_DIR=${TEMP_DIR:-"/tmp/mpris_covers"}
BPM_CACHE_DIR=${BPM_CACHE_DIR:-"/tmp/bpm_cache"}  # Directory for caching BPM values
NUM_COLORS=${NUM_COLORS:-3}  # Number of colors to extract. Set to -1 to disable color alternation.
COLOR_INDEX=0  # Track which color to use
COLORS_CACHE=""  # Cache for extracted colors
COLOR_SIMILARITY_THRESHOLD=${COLOR_SIMILARITY_THRESHOLD:-75}  # Threshold for color similarity detection (higher = more diversity)
MIN_BPM_DELAY=${MIN_BPM_DELAY:-0.8}  # Minimum delay between color alternations (800ms - slower)
MAX_BPM_DELAY=${MAX_BPM_DELAY:-3.0}  # Maximum delay between color alternations (3s - much slower)
USE_BPM=${USE_BPM:-true}  # Whether to use BPM for alternation timing
VERBOSE_LOGGING=${VERBOSE_LOGGING:-false}  # Set to false to reduce webhook-related logging
MIN_YEELIGHT_TRANSITION=${MIN_YEELIGHT_TRANSITION:-0.5}  # Minimum transition time for Yeelight W3 bulbs in seconds (increased)
BPM_SCALE_MIN=${BPM_SCALE_MIN:-40}  # Minimum BPM to map to 0% (slowest)
BPM_SCALE_MAX=${BPM_SCALE_MAX:-180}  # Maximum BPM to map to 100% (fastest)
SAFE_MODE=${SAFE_MODE:-true}  # Enable safe mode for bulbs (slower, more reliable)
# How long to wait between color changes when the bulb is in safe mode
SAFE_MODE_WAIT=${SAFE_MODE_WAIT:-0.2}  # Add a small delay between color API calls

# Near the other configuration variables
MIN_COLOR_BRIGHTNESS=${MIN_COLOR_BRIGHTNESS:-25}  # Minimum RGB value to ensure colors are visible on bulb
MIN_COLOR_SATURATION=${MIN_COLOR_SATURATION:-35}  # Minimum saturation percentage to ensure vibrant colors
VIVID_COLOR_BOOST=${VIVID_COLOR_BOOST:-1.3}       # Saturation boost factor for making colors more vivid

# Add these configuration variables
COLOR_DIVERSITY_THRESHOLD=${COLOR_DIVERSITY_THRESHOLD:-50}  # How different colors should be from each other
FORCE_HUE_ROTATION=${FORCE_HUE_ROTATION:-true}             # Force at least one color to have a different hue

# For debugging
log_message "Starting with NUM_COLORS=$NUM_COLORS and COLOR_INDEX=$COLOR_INDEX"
log_message "BPM delay range: ${MIN_BPM_DELAY}s - ${MAX_BPM_DELAY}s, BPM scale: ${BPM_SCALE_MIN} - ${BPM_SCALE_MAX}"
log_message "Safe mode: $SAFE_MODE, Safe mode wait: ${SAFE_MODE_WAIT}s"

# Validate environment variables and initialize directories
validate_requirements
initialize_directories

# Variable to store last track ID
LAST_TRACK_ID=""

# Function to clean track title by removing suffixes like "(Original Mix)"
clean_track_title() {
  local TITLE="$1"
  
  # Remove various common suffixes
  local CLEANED_TITLE=$(echo "$TITLE" | \
    sed -E 's/\s*\(Original Mix\)//gi' | \
    sed -E 's/\s*\(Radio Edit\)//gi' | \
    sed -E 's/\s*\(Extended Mix\)//gi' | \
    sed -E 's/\s*\(Club Mix\)//gi' | \
    sed -E 's/\s*\(Remix\)//gi' | \
    sed -E 's/\s*\([^)]*Remaster[^)]*\)//gi' | \
    sed -E 's/\s*\- [^-]*(Remaster|Version|Edition).*$//gi')
    
  echo "$CLEANED_TITLE"
}

# Function to extract BPM from MP3 file using multiple methods
get_bpm_from_mp3() {
  local MP3_FILE="$1"
  local BPM=0
  
  if [ ! -f "$MP3_FILE" ]; then
    log_message "MP3 file not found: $MP3_FILE"
    echo "$BPM"
    return
  fi
  
  log_message "Attempting to extract BPM from MP3 file: $(basename "$MP3_FILE")"
  
  # Method 1: Try to get BPM from ID3 tags using ffprobe
  log_message "Trying method 1: Extract BPM from ID3 tags"
  local TAG_BPM=$(ffprobe -v error -select_streams a:0 -show_entries format_tags=BPM -of default=noprint_wrappers=1:nokey=1 "$MP3_FILE" 2>/dev/null)
  
  # Check if we got a valid BPM from tags
  if [[ -n "$TAG_BPM" && "$TAG_BPM" != "N/A" ]]; then
    # Convert to integer (take only the number part)
    BPM=$(echo "$TAG_BPM" | grep -o '^[0-9]\+')
    
    if [[ -n "$BPM" && "$BPM" != "0" ]]; then
      log_message "Found BPM in ID3 tags: $BPM"
      echo "$BPM"
      return
    fi
  fi
  
  # Method 2: Use ffmpeg's ebur128 filter to estimate BPM (least accurate method)
  log_message "Trying method 2: ffmpeg ebur128 analysis (low accuracy)"
  if command -v ffmpeg &> /dev/null; then
    # Create temporary file for output
    local TEMP_OUTPUT="$TEMP_DIR/ffmpeg_output_$$.txt"
    
    # Run ffmpeg with ebur128 filter on part of the song
    ffmpeg -i "$MP3_FILE" -t 60 -filter:a ebur128 -f null - 2> "$TEMP_OUTPUT"
    
    # Try to estimate BPM from the momentary loudness measurements
    local MOMENTS=$(grep "Moment" "$TEMP_OUTPUT" | wc -l)
    local DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$MP3_FILE" | cut -d. -f1)
    
    if [[ -n "$MOMENTS" && -n "$DURATION" && "$DURATION" -gt 0 ]]; then
      # Very rough BPM calculation - this is not very accurate
      BPM=$(echo "($MOMENTS / $DURATION) * 15" | bc)
      
      # Bound to a reasonable range
      if [ "$BPM" -lt 60 ]; then BPM=60; fi
      if [ "$BPM" -gt 200 ]; then BPM=200; fi
      
      log_message "Estimated BPM using ffmpeg analysis: $BPM (low accuracy)"
    fi
    
    rm -f "$TEMP_OUTPUT"
  fi
  
  # If all else fails, return the default value
  echo "$BPM"
}

# Function to get track BPM from various sources
get_track_bpm() {
  local TRACK_ID="$1"
  local BPM=0
  local MIN_VALID_BPM=20  # Minimum reasonable BPM for a music track
  
  # Skip if BPM detection is disabled
  if ! $USE_BPM; then
    >&2 log_message "BPM detection disabled by configuration"
    echo "$BPM"
    return
  fi
  
  # Get artist and title for lookup
  local PLAYER_NAME=$(playerctl -l | grep -i "spotify" | head -1)
  local ARTIST=$(playerctl -p "$PLAYER_NAME" metadata artist 2>/dev/null)
  local TITLE=$(playerctl -p "$PLAYER_NAME" metadata title 2>/dev/null)
  local TRACK_URL=$(playerctl -p "$PLAYER_NAME" metadata xesam:url 2>/dev/null)
  
  >&2 log_message "Looking up BPM for track: $ARTIST - $TITLE"
  
  # Check if it's a local file
  local IS_LOCAL_FILE=false
  if [[ -n "$TRACK_URL" && "$TRACK_URL" == *"/local/"* ]]; then
    IS_LOCAL_FILE=true
    >&2 log_message "Detected local file playback"
    
    # Extract artist and title information if needed
    if [[ -z "$ARTIST" && "$TITLE" == *" - "* ]]; then
      # Extract artist and title from the track title itself
      ARTIST=$(echo "$TITLE" | sed 's/ - .*$//')
      TITLE=$(echo "$TITLE" | sed 's/^.*- //')
      >&2 log_message "Extracted artist/title from track name: $ARTIST - $TITLE"
    fi
  fi
  
  # Get current script directory for Python scripts
  SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  
  # Use our get_bpm function for BPM detection
  BPM=$(get_bpm "$TITLE" "$ARTIST" "$TRACK_ID" "$IS_LOCAL_FILE")
  
  # Clean the BPM value to ensure it's just a number
  BPM=$(echo "$BPM" | grep -o '^[0-9.]*$')
  
  # Validate BPM is a number
  if ! [[ "$BPM" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    >&2 log_message "Invalid BPM value returned: '$BPM', defaulting to 0"
    BPM=0
  fi
  
  echo "$BPM"
}

# Function to calculate delay based on BPM
calculate_delay_from_bpm() {
  local BPM="$1"
  local DELAY=$ALTERNATION_DELAY  # Default delay
  
  # Check if BPM is a valid number
  if [[ -n "$BPM" && "$BPM" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Calculate percentage based on BPM range using the helper function
    local BPM_PERCENTAGE=$(calculate_bpm_percentage "$BPM")
    
    # Map percentage to delay range (reverse mapping - higher BPM = lower delay)
    DELAY=$(echo "scale=4; $MAX_BPM_DELAY - ($BPM_PERCENTAGE / 100) * ($MAX_BPM_DELAY - $MIN_BPM_DELAY)" | bc 2>/dev/null || echo "$ALTERNATION_DELAY")
    
    # Validate the result - ensure it's a valid number
    if ! [[ "$DELAY" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      DELAY=$ALTERNATION_DELAY
      >&2 log_message "Invalid delay calculation result, using default: ${DELAY}s"
    else
      # Redirect log message to stderr so it doesn't interfere with the return value
      >&2 log_message "Track BPM: $BPM (${BPM_PERCENTAGE}%), calculated delay: ${DELAY}s"
    fi
  else
    # If BPM is not a valid number, log a warning and use default
    >&2 log_message "Invalid BPM value: '$BPM', using default delay: ${DELAY}s"
  fi
  
  # Format to 2 decimal places and ensure it's a valid number
  FINAL_DELAY=$(printf "%.2f" $DELAY 2>/dev/null || echo "$ALTERNATION_DELAY")
  
  # Return only the delay value, no log messages
  echo "$FINAL_DELAY"
}

# Function to calculate transition time for Yeelight based on BPM
calculate_transition_from_bpm() {
  local BPM="$1"
  local TRANSITION=1.0  # Default transition time
  
  # Check if BPM is a valid number
  if [[ -n "$BPM" && "$BPM" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Calculate percentage based on BPM range using the helper function
    local BPM_PERCENTAGE=$(calculate_bpm_percentage "$BPM")
    
    # Map percentage to transition range (reverse mapping - higher BPM = lower transition)
    TRANSITION=$(echo "scale=2; $MAX_BPM_DELAY - ($BPM_PERCENTAGE / 100) * ($MAX_BPM_DELAY - $MIN_BPM_DELAY)" | bc 2>/dev/null || echo "1.0")
    
    # Validate the result - ensure it's a valid number
    if ! [[ "$TRANSITION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      TRANSITION=1.0
      >&2 log_message "Invalid transition calculation result, using default: ${TRANSITION}s"
    else
      # Store the original transition before any adjustments
      local ORIGINAL_TRANSITION=$TRANSITION
      
      # Ensure transition time is not below minimum
      if [ $(echo "$TRANSITION < $MIN_YEELIGHT_TRANSITION" | bc -l) -eq 1 ]; then
        # Calculate a proportional value between MIN_YEELIGHT_TRANSITION and MIN_YEELIGHT_TRANSITION/2
        # For very low values, use half the minimum, for values close to minimum, use values closer to minimum
        local PROPORTION=$(echo "scale=4; $TRANSITION / $MIN_YEELIGHT_TRANSITION" | bc)
        TRANSITION=$(echo "scale=2; ($MIN_YEELIGHT_TRANSITION / 2) + ($MIN_YEELIGHT_TRANSITION / 2 * $PROPORTION)" | bc)
        >&2 log_message "Adjusted transition time for bulb: ${ORIGINAL_TRANSITION}s → ${TRANSITION}s (safety minimum: ${MIN_YEELIGHT_TRANSITION}s)"
      else
        >&2 log_message "Applied transition time: ${TRANSITION}s (meets minimum requirement)"
      fi
      
      # Redirect log message to stderr so it doesn't interfere with the return value
      >&2 log_message "Track BPM: $BPM (${BPM_PERCENTAGE}%), final transition time: ${TRANSITION}s"
    fi
  else
    # If BPM is not a valid number, log a warning and use default
    >&2 log_message "Invalid BPM value: '$BPM', using default transition: ${TRANSITION}s"
  fi
  
  # Format to 2 decimal places and ensure it's a valid number
  FINAL_TRANSITION=$(printf "%.2f" $TRANSITION 2>/dev/null || echo "1.0")
  
  # Return only the transition value, no log messages
  echo "$FINAL_TRANSITION"
}

# Helper function to calculate BPM percentage (0-100%) within the defined scale
calculate_bpm_percentage() {
  local BPM="$1"
  local BPM_PERCENTAGE=50 # Default to 50 if calculation fails
  
  # Calculate percentage (0-100%) based on where BPM falls in the range
  if (( $(echo "$BPM <= $BPM_SCALE_MIN" | bc -l 2>/dev/null) )); then
    BPM_PERCENTAGE=0
  elif (( $(echo "$BPM >= $BPM_SCALE_MAX" | bc -l 2>/dev/null) )); then
    BPM_PERCENTAGE=100
  else
    # Linear mapping from BPM to percentage
    BPM_PERCENTAGE=$(echo "scale=2; 100 * ($BPM - $BPM_SCALE_MIN) / ($BPM_SCALE_MAX - $BPM_SCALE_MIN)" | bc 2>/dev/null || echo "50")
  fi
  
  echo "$BPM_PERCENTAGE"
}

declare -A LAST_ARTS
# Store last RGB values to avoid sending duplicates
LAST_R=""
LAST_G=""
LAST_B=""
# Track last player/track to reduce logging
LAST_PLAYER=""
LAST_TRACK=""
# First run flag
FIRST_RUN=true
# Last color index used
LAST_COLOR_INDEX=-1
# Track processing timestamp to prevent redundant processing
declare -A TRACK_PROCESS_TIMES
# Minimum seconds between reprocessing the same track
MIN_REPROCESS_TIME=300
# Track the last logged status for each track to avoid duplicate logging
declare -A LAST_LOGGED_STATUS

# Background color alternation process ID
COLOR_ALTERNATION_PID=""

# Track which player the current color alternation is associated with
COLORS_SOURCE_PLAYER=""

# Function to find a local music file based on artist and title
find_music_file() {
  local SEARCH_ARTIST="$1"
  local SEARCH_TITLE="$2"
  local TRACK_TITLE="$3"
  local TITLE_ARTIST="$4"
  local MUSIC_FILE=""
  
  # Try to find using both artist and title
  if [[ -n "$SEARCH_ARTIST" && -n "$SEARCH_TITLE" ]]; then
    SEARCH_PATTERN="*${SEARCH_ARTIST}*${SEARCH_TITLE}*"
    MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "$SEARCH_PATTERN.mp3" | head -n 1)
    
    # If not found, try alternative pattern with spaces
    if [[ -z "$MUSIC_FILE" ]]; then
      ARTIST_TERMS=$(echo "$SEARCH_ARTIST" | tr ' ' '*')
      TITLE_TERMS=$(echo "$SEARCH_TITLE" | tr ' ' '*')
      MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "*${ARTIST_TERMS}*${TITLE_TERMS}*.mp3" | head -n 1)
    fi
    
    # If still not found and we have artist from title, try with that specifically
    if [[ -z "$MUSIC_FILE" && -n "$TITLE_ARTIST" ]]; then
      MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "*${TRACK_TITLE}*.mp3" | head -n 1)
    fi
  fi
  
  # If still not found, try with just the title
  if [[ -z "$MUSIC_FILE" ]]; then
    TITLE_TERMS=$(echo "$SEARCH_TITLE" | tr ' ' '*')
    MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "*${TITLE_TERMS}*.mp3" | head -n 1)
    
    # Last resort - try with the raw track title
    if [[ -z "$MUSIC_FILE" ]]; then
      MUSIC_FILE=$(find "$MUSIC_DIR" -type f -ipath "*$(echo "$TRACK_TITLE" | tr ' ' '*')*.mp3" | head -n 1)
    fi
  fi
  
  # If still not found, try with a more aggressive approach for handling special characters
  if [[ -z "$MUSIC_FILE" ]]; then
    # Create a simplified track title by replacing special characters
    # Replace special Unicode characters with ASCII equivalents
    SIMPLIFIED_TITLE=$(echo "$TRACK_TITLE" | 
      tr '|｜' '**' |  # Replace both normal and fullwidth vertical bars with wildcards
      tr '[]{})(' '******' |  # Replace brackets with wildcards
      tr ':;,.!?' '******')  # Replace punctuation with wildcards
    
    # Try with simplified title pattern
    MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "*$(echo "$SIMPLIFIED_TITLE" | tr ' ' '*')*.mp3" | head -n 1)
    
    # As a last resort, try just the main parts without special chars
    if [[ -z "$MUSIC_FILE" && "$TRACK_TITLE" == *" - "* ]]; then
      # Get parts before and after the hyphen
      PART1=$(echo "$TRACK_TITLE" | cut -d'-' -f1 | tr -d '[:punct:]' | tr -d '[:cntrl:]' | tr ' ' '*')
      PART2=$(echo "$TRACK_TITLE" | cut -d'-' -f2 | tr -d '[:punct:]' | tr -d '[:cntrl:]' | tr ' ' '*')
      
      # Try to find a file containing both parts in any order
      MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "*${PART1}*${PART2}*.mp3" | head -n 1)
      
      # If that fails, try the other way around
      if [[ -z "$MUSIC_FILE" ]]; then
        MUSIC_FILE=$(find "$MUSIC_DIR" -type f -iname "*${PART2}*${PART1}*.mp3" | head -n 1)
      fi
    fi
  fi
  
  echo "$MUSIC_FILE"
}

# Function to extract artwork from a local music file
extract_artwork() {
  local MUSIC_FILE="$1"
  local COVER_PATH="$2"
  local NEW_STATUS="$3"
  local success=false
  local DEBUG_LOG="/tmp/mpris_rgb_debug.log"
  
  echo "$(date '+%H:%M:%S') Extracting artwork from: $MUSIC_FILE" >> "$DEBUG_LOG"
  echo "$(date '+%H:%M:%S') File exists: $([[ -f "$MUSIC_FILE" ]] && echo "yes" || echo "no"), size: $([ -f "$MUSIC_FILE" ] && stat -c "%s" "$MUSIC_FILE" || echo "N/A")" >> "$DEBUG_LOG"
  
  # Create temp directory if it doesn't exist
  mkdir -p "$TEMP_DIR"
  
  # Create temporary files for output and error logging
  local FFMPEG_OUT="/tmp/ffmpeg_out.txt"
  local FFMPEG_ERR="/tmp/ffmpeg_err.txt"
  
  # Extract artwork with ffmpeg - now with verbose output
  echo "$(date '+%H:%M:%S') Running command: ffmpeg -y -i \"$MUSIC_FILE\" -an -vcodec copy \"$COVER_PATH\"" >> "$DEBUG_LOG"
  ffmpeg -y -i "$MUSIC_FILE" -an -vcodec copy "$COVER_PATH" > "$FFMPEG_OUT" 2> "$FFMPEG_ERR"
  
  FFMPEG_EXIT=$?
  echo "$(date '+%H:%M:%S') ffmpeg extraction exit code: $FFMPEG_EXIT" >> "$DEBUG_LOG"
  
  if [ -s "$FFMPEG_ERR" ]; then
    echo "$(date '+%H:%M:%S') ffmpeg stderr output: $(head -n 10 "$FFMPEG_ERR")" >> "$DEBUG_LOG"
  fi
  
  # Check if extraction succeeded
  if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
    echo "$(date '+%H:%M:%S') Successfully extracted artwork from local file" >> "$DEBUG_LOG"
    success=true
  else
    echo "$(date '+%H:%M:%S') First extraction method failed, file exists: $([[ -f "$COVER_PATH" ]] && echo "yes" || echo "no"), size: $([ -f "$COVER_PATH" ] && stat -c "%s" "$COVER_PATH" || echo "N/A")" >> "$DEBUG_LOG"
    
    # Try alternate extraction method using ffmpeg
    echo "$(date '+%H:%M:%S') Trying alternate artwork extraction method" >> "$DEBUG_LOG"
    echo "$(date '+%H:%M:%S') Running command: ffmpeg -y -i \"$MUSIC_FILE\" -an -vf \"scale=500:500\" \"$COVER_PATH\"" >> "$DEBUG_LOG"
    ffmpeg -y -i "$MUSIC_FILE" -an -vf "scale=500:500" "$COVER_PATH" > "$FFMPEG_OUT" 2> "$FFMPEG_ERR"
    
    FFMPEG_EXIT=$?
    echo "$(date '+%H:%M:%S') ffmpeg alternate extraction exit code: $FFMPEG_EXIT" >> "$DEBUG_LOG"
    
    if [ -s "$FFMPEG_ERR" ]; then
      echo "$(date '+%H:%M:%S') ffmpeg stderr output: $(head -n 10 "$FFMPEG_ERR")" >> "$DEBUG_LOG"
    fi
    
    if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
      echo "$(date '+%H:%M:%S') Successfully extracted artwork using alternate method" >> "$DEBUG_LOG"
      success=true
    else
      echo "$(date '+%H:%M:%S') Alternate extraction method failed too, file exists: $([[ -f "$COVER_PATH" ]] && echo "yes" || echo "no"), size: $([ -f "$COVER_PATH" ] && stat -c "%s" "$COVER_PATH" || echo "N/A")" >> "$DEBUG_LOG"
      
      # Try third method - extract using "album art" option
      echo "$(date '+%H:%M:%S') Trying third extraction method with album art" >> "$DEBUG_LOG"
      echo "$(date '+%H:%M:%S') Running command: ffmpeg -y -i \"$MUSIC_FILE\" -an -c:v copy -map 0:v -map_metadata 0 \"$COVER_PATH\"" >> "$DEBUG_LOG"
      ffmpeg -y -i "$MUSIC_FILE" -an -c:v copy -map 0:v -map_metadata 0 "$COVER_PATH" > "$FFMPEG_OUT" 2> "$FFMPEG_ERR"
      
      FFMPEG_EXIT=$?
      echo "$(date '+%H:%M:%S') ffmpeg third extraction exit code: $FFMPEG_EXIT" >> "$DEBUG_LOG"
      
      if [ -s "$FFMPEG_ERR" ]; then
        echo "$(date '+%H:%M:%S') ffmpeg stderr output: $(head -n 10 "$FFMPEG_ERR")" >> "$DEBUG_LOG"
      fi
      
      if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
        echo "$(date '+%H:%M:%S') Successfully extracted artwork using third method" >> "$DEBUG_LOG"
        success=true
      else
        # Try a direct test to see if file has ANY embedded artwork
        echo "$(date '+%H:%M:%S') Running command: ffprobe -v error -select_streams v -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \"$MUSIC_FILE\"" >> "$DEBUG_LOG"
        local HAS_VIDEO=$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$MUSIC_FILE" 2>&1)
        echo "$(date '+%H:%M:%S') ffprobe result for video streams: '$HAS_VIDEO'" >> "$DEBUG_LOG"
        
        if [ -n "$HAS_VIDEO" ]; then
          echo "$(date '+%H:%M:%S') File has video/image stream but extraction failed" >> "$DEBUG_LOG"
        else
          echo "$(date '+%H:%M:%S') File does not appear to have embedded artwork" >> "$DEBUG_LOG"
        fi
        
        echo "$(date '+%H:%M:%S') All extraction methods failed, giving up" >> "$DEBUG_LOG"
      fi
    fi
  fi
  
  echo "$(date '+%H:%M:%S') Extract artwork function returning: $success" >> "$DEBUG_LOG"
  
  echo "$success"
}

# Function to check if a track should be reprocessed
should_reprocess_track() {
  local TRACK_ID="$1"
  local TRACK_TITLE="$2"
  local LOG_ENABLED="${3:-0}"  # Default to no logging (0)
  
  # Create a composite key that includes both ID and title
  local TRACK_KEY="${TRACK_ID}:${TRACK_TITLE}"
  
  # Check if we've processed this track recently
  local LAST_PROCESS_TIME=${TRACK_PROCESS_TIMES[$TRACK_KEY]}
  local CURRENT_TIME=$(date +%s)
  
  if [ -n "$LAST_PROCESS_TIME" ]; then
    local TIME_DIFF=$((CURRENT_TIME - LAST_PROCESS_TIME))
    if [ $TIME_DIFF -lt $MIN_REPROCESS_TIME ]; then
      # Only log if explicitly enabled
      if [ "$LOG_ENABLED" -eq 1 ]; then
        log_message "Skipping reprocessing for \"$TRACK_TITLE\" - processed ${TIME_DIFF}s ago"
      fi
      return 1  # Don't reprocess
    else
      # Only log if explicitly enabled
      if [ "$LOG_ENABLED" -eq 1 ]; then
        log_message "Will reprocess track: time since last processing (${TIME_DIFF}s) >= minimum"
      fi
    fi
  else
    # Only log if explicitly enabled
    if [ "$LOG_ENABLED" -eq 1 ]; then
      log_message "Track was not processed before, will process now"
    fi
  fi
  
  # Update the processing time
  TRACK_PROCESS_TIMES[$TRACK_KEY]=$CURRENT_TIME
  
  return 0  # Should reprocess
}

# Function to ensure a color meets minimum brightness requirements
ensure_minimum_brightness() {
  local R="$1"
  local G="$2"
  local B="$3"
  
  # Calculate average brightness
  local BRIGHTNESS=$(( (R + G + B) / 3 ))
  
  # If brightness is below threshold, scale up all components
  if [ "$BRIGHTNESS" -lt "$MIN_COLOR_BRIGHTNESS" ]; then
    local SCALE_FACTOR=$(echo "scale=2; $MIN_COLOR_BRIGHTNESS / ($BRIGHTNESS + 1)" | bc)
    
    # Scale each component up while preserving color relationships
    R=$(echo "scale=0; $R * $SCALE_FACTOR + 0.5" | bc | awk '{printf "%d", $1}')
    G=$(echo "scale=0; $G * $SCALE_FACTOR + 0.5" | bc | awk '{printf "%d", $1}')
    B=$(echo "scale=0; $B * $SCALE_FACTOR + 0.5" | bc | awk '{printf "%d", $1}')
    
    # Ensure values are capped at 255
    R=$(( R > 255 ? 255 : (R < 0 ? 0 : R) ))
    G=$(( G > 255 ? 255 : (G < 0 ? 0 : G) ))
    B=$(( B > 255 ? 255 : (B < 0 ? 0 : B) ))
    
    # Fix the printf error by using stderr for logging
    log_message "Adjusted dark color to meet minimum brightness (original brightness: $BRIGHTNESS)" >&2
  fi
  
  # Enhance saturation to make colors more vivid
  local MAX_VAL=$(( R > G ? (R > B ? R : B) : (G > B ? G : B) ))
  local MIN_VAL=$(( R < G ? (R < B ? R : B) : (G < B ? G : B) ))
  
  # Calculate the current saturation (0-100%)
  local SATURATION=0
  if [ "$MAX_VAL" -gt 0 ]; then
    SATURATION=$(( 100 * (MAX_VAL - MIN_VAL) / MAX_VAL ))
  fi
  
  # If saturation is below minimum, boost it
  if [ "$SATURATION" -lt "$MIN_COLOR_SATURATION" ] && [ "$MAX_VAL" -gt 0 ]; then
    # Calculate the amount to boost each component
    local DELTA=$(( MAX_VAL - MIN_VAL ))
    
    # Increase the delta to boost saturation
    local BOOSTED_DELTA=$(echo "scale=2; $DELTA * $VIVID_COLOR_BOOST" | bc)
    
    # Apply proportional adjustment to each component
    if [ "$MAX_VAL" -eq "$R" ]; then
      # R is max, adjust G and B down
      G=$(echo "scale=0; $MAX_VAL - ($MAX_VAL - $G) * $VIVID_COLOR_BOOST" | bc | awk '{printf "%d", $1}')
      B=$(echo "scale=0; $MAX_VAL - ($MAX_VAL - $B) * $VIVID_COLOR_BOOST" | bc | awk '{printf "%d", $1}')
    elif [ "$MAX_VAL" -eq "$G" ]; then
      # G is max, adjust R and B down
      R=$(echo "scale=0; $MAX_VAL - ($MAX_VAL - $R) * $VIVID_COLOR_BOOST" | bc | awk '{printf "%d", $1}')
      B=$(echo "scale=0; $MAX_VAL - ($MAX_VAL - $B) * $VIVID_COLOR_BOOST" | bc | awk '{printf "%d", $1}')
    else
      # B is max, adjust R and G down
      R=$(echo "scale=0; $MAX_VAL - ($MAX_VAL - $R) * $VIVID_COLOR_BOOST" | bc | awk '{printf "%d", $1}')
      G=$(echo "scale=0; $MAX_VAL - ($MAX_VAL - $G) * $VIVID_COLOR_BOOST" | bc | awk '{printf "%d", $1}')
    fi
    
    # Ensure all values are in valid range
    R=$(( R > 255 ? 255 : (R < 0 ? 0 : R) ))
    G=$(( G > 255 ? 255 : (G < 0 ? 0 : G) ))
    B=$(( B > 255 ? 255 : (B < 0 ? 0 : B) ))
    
    # Log to stderr to avoid capturing in the function output
    log_message "Boosted color saturation from $SATURATION% (RGB: $1,$2,$3 to RGB: $R,$G,$B)" >&2
  fi
  
  # Return ONLY the RGB values, no logging in the output
  echo "$R,$G,$B"
}

# Function to alternate colors in the background
alternate_colors_background() {
  local DELAY="$1"
  local NEXT_INDEX=0
  local COLORS_ARRAY=("$2" "$3" "$4")
  local NUM_CACHED_COLORS="$5"
  local WEBHOOK="$6"
  local LAST_PLAYER_NAME="$7"
  local LAST_TRACK_NAME="$8"
  local TRANSITION="${9:-1.0}"  # Default transition time if not provided
  
  # Store the source player name globally to check when resuming
  # Extract just the player name without any extra text
  COLORS_SOURCE_PLAYER=$(echo "$LAST_PLAYER_NAME" | sed 's/ (local file)$//' | sed 's/ .*$//')
  
  # Store this in a file to persist between script restarts
  echo "$COLORS_SOURCE_PLAYER" > "/tmp/mpris_rgb_source_player"
  
  log_message "Starting background color alternation with $NUM_CACHED_COLORS colors and delay $DELAY for player: $COLORS_SOURCE_PLAYER"
  
  # Log all colors we're using
  log_message "Using colors for alternation:"
  for ((i=0; i<$NUM_CACHED_COLORS; i++)); do
    IFS=',' read -r CR CG CB <<< "${COLORS_ARRAY[$i]}"
    log_message "   Color $((i+1)): RGB($CR,$CG,$CB) - Hex: #$(printf '%02x%02x%02x' $CR $CG $CB)"
  done
  
  # Validate color values before starting the loop
  for ((i=0; i<$NUM_CACHED_COLORS; i++)); do
    IFS=',' read -r CR CG CB <<< "${COLORS_ARRAY[$i]}"
    
    # Ensure values are in range 0-255
    CR=$(echo "$CR" | grep -o '[0-9]*' | head -1)
    CG=$(echo "$CG" | grep -o '[0-9]*' | head -1)
    CB=$(echo "$CB" | grep -o '[0-9]*' | head -1)
    
    # Set defaults if invalid
    [ -z "$CR" ] && CR=0
    [ -z "$CG" ] && CG=0
    [ -z "$CB" ] && CB=0
    
    # Ensure values are in valid range
    CR=$(( CR > 255 ? 255 : (CR < 0 ? 0 : CR) ))
    CG=$(( CG > 255 ? 255 : (CG < 0 ? 0 : CG) ))
    CB=$(( CB > 255 ? 255 : (CB < 0 ? 0 : CB) ))
    
    # Apply minimum brightness adjustment - capture only the return value
    ADJUSTED_COLOR=$(ensure_minimum_brightness "$CR" "$CG" "$CB")
    
    # Parse the adjusted color values
    IFS=',' read -r NEW_R NEW_G NEW_B <<< "$ADJUSTED_COLOR"
    
    # Validate values again to be safe
    NEW_R=$(echo "$NEW_R" | grep -o '[0-9]*' | head -1)
    NEW_G=$(echo "$NEW_G" | grep -o '[0-9]*' | head -1)
    NEW_B=$(echo "$NEW_B" | grep -o '[0-9]*' | head -1)
    
    # Set defaults if invalid
    [ -z "$NEW_R" ] && NEW_R=30
    [ -z "$NEW_G" ] && NEW_G=30
    [ -z "$NEW_B" ] && NEW_B=30
    
    # Ensure values are in valid range 
    NEW_R=$(( NEW_R > 255 ? 255 : (NEW_R < 0 ? 0 : NEW_R) ))
    NEW_G=$(( NEW_G > 255 ? 255 : (NEW_G < 0 ? 0 : NEW_G) ))
    NEW_B=$(( NEW_B > 255 ? 255 : (NEW_B < 0 ? 0 : NEW_B) ))
    
    # Update the array with the validated values
    COLORS_ARRAY[$i]="$NEW_R,$NEW_G,$NEW_B"
  done
  
  # Log colors after adjustment
  log_message "Colors after brightness adjustment:"
  for ((i=0; i<$NUM_CACHED_COLORS; i++)); do
    IFS=',' read -r CR CG CB <<< "${COLORS_ARRAY[$i]}"
    log_message "   Color $((i+1)): RGB($CR,$CG,$CB) - Hex: #$(printf '%02x%02x%02x' $CR $CG $CB)"
  done
  
  # Make sure transition is a simple numeric value 
  TRANSITION=$(echo "$TRANSITION" | grep -o '[0-9]*\.[0-9]*' | head -1)
  # Set default if invalid
  [ -z "$TRANSITION" ] && TRANSITION=1.0
  
  # Ensure transition time is not below minimum
  if [ $(echo "$TRANSITION < $MIN_YEELIGHT_TRANSITION" | bc -l) -eq 1 ]; then
    # Calculate a proportional value between MIN_YEELIGHT_TRANSITION and MIN_YEELIGHT_TRANSITION/2
    # For very low values, use half the minimum, for values close to minimum, use values closer to minimum
    local PROPORTION=$(echo "scale=4; $TRANSITION / $MIN_YEELIGHT_TRANSITION" | bc)
    local ORIGINAL_TRANSITION=$TRANSITION
    TRANSITION=$(echo "scale=2; ($MIN_YEELIGHT_TRANSITION / 2) + ($MIN_YEELIGHT_TRANSITION / 2 * $PROPORTION)" | bc)
    log_message "Adjusted transition time for bulb: ${ORIGINAL_TRANSITION}s → ${TRANSITION}s (safety minimum: ${MIN_YEELIGHT_TRANSITION}s)"
  else
    log_message "Applied transition time: ${TRANSITION}s (meets minimum requirement)"
  fi
  
  # Store last used color to prevent duplicates
  local LAST_USED_COLOR=""
  local RETRIES=0
  local MAX_RETRIES=3
  
  # Continuously alternate colors at the specified delay
  while true; do
    # Exit if we should stop alternating (NUM_COLORS <= 0)
    if [ -f "/tmp/mpris_rgb_stop_alternation" ]; then
      log_message "Stopping background color alternation"
      rm -f "/tmp/mpris_rgb_stop_alternation"
      exit 0
    fi
    
    # Check if the alternation is paused
    if [ -f "/tmp/mpris_rgb_pause_alternation" ]; then
      # Wait for the pause file to be removed before continuing
      sleep 0.5
      continue
    fi
    
    # Calculate next index
    NEXT_INDEX=$((NEXT_INDEX % NUM_CACHED_COLORS))
    
    # Get color for current index
    IFS=',' read -r R G B <<< "${COLORS_ARRAY[$NEXT_INDEX]}"
    
    # Ensure RGB values are valid integers in range 0-255
    R=$(echo "$R" | grep -o '[0-9]*' | head -1)
    G=$(echo "$G" | grep -o '[0-9]*' | head -1)
    B=$(echo "$B" | grep -o '[0-9]*' | head -1)
    
    # Set defaults if values are invalid
    [ -z "$R" ] && R=0
    [ -z "$G" ] && G=0
    [ -z "$B" ] && B=0
    
    # Ensure values are in valid range
    R=$(( R > 255 ? 255 : R ))
    G=$(( G > 255 ? 255 : G ))
    B=$(( B > 255 ? 255 : B ))
    
    # Check if color is different from last color
    CURRENT_COLOR="$R,$G,$B"
    if [ "$CURRENT_COLOR" = "$LAST_USED_COLOR" ]; then
      # Skip duplicate colors, try next one
      NEXT_INDEX=$((NEXT_INDEX + 1))
      continue
    fi
    
    # Ensure TRANSITION is a valid number - extract just the number part
    # This ensures no log messages get included in the variable
    TRANSITION_NUMBER=$(echo "$TRANSITION" | grep -o '[0-9]*\.[0-9]*' | head -1)
    # Default to 1.0 if extraction fails
    [ -z "$TRANSITION_NUMBER" ] && TRANSITION_NUMBER=1.0
    
    # Format to 2 decimal places
    TRANSITION_FORMATTED=$(printf "%.2f" $TRANSITION_NUMBER)
    
    # Prepare payload with fixed transition time
    PAYLOAD="{\"rgb\": [$R, $G, $B], \"transition\": $TRANSITION_FORMATTED}"
    
    # Send to Home Assistant webhook with reduced logging
    curl -s -X POST \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "$WEBHOOK" > /dev/null 2>/dev/null
    
    RESPONSE_CODE=$?
    if [ $RESPONSE_CODE -ne 0 ]; then
      RETRIES=$((RETRIES + 1))
      if [ $RETRIES -gt $MAX_RETRIES ]; then
        log_message "Multiple errors calling webhook. Response code: $RESPONSE_CODE. Increasing delay."
        DELAY=$(echo "$DELAY * 1.5" | bc)
        RETRIES=0
      fi
    else
      RETRIES=0
      # Store the last used color
      LAST_USED_COLOR="$CURRENT_COLOR"
    fi
    
    # Increment index for next time
    NEXT_INDEX=$((NEXT_INDEX + 1))
    
    # In safe mode, add a small pause between API calls
    if $SAFE_MODE; then
      sleep $SAFE_MODE_WAIT
    fi
    
    # Sleep for the specified delay
    sleep "$DELAY"
  done
}

# Function to pause background color alternation
pause_background_alternation() {
  if [ -n "$COLOR_ALTERNATION_PID" ] && [ ! -f "/tmp/mpris_rgb_pause_alternation" ]; then
    touch "/tmp/mpris_rgb_pause_alternation"
  fi
}

# Function to resume background color alternation
resume_background_alternation() {
  if [ -n "$COLOR_ALTERNATION_PID" ] && [ -f "/tmp/mpris_rgb_pause_alternation" ]; then
    rm -f "/tmp/mpris_rgb_pause_alternation"
  fi
}

# Function to stop background color alternation
stop_background_alternation() {
  if [ -n "$COLOR_ALTERNATION_PID" ]; then
    log_message "Stopping previous color alternation process (PID: $COLOR_ALTERNATION_PID)"
    touch "/tmp/mpris_rgb_stop_alternation"
    # Give it a moment to exit cleanly
    sleep 0.5
    # Force kill if still running
    if kill -0 $COLOR_ALTERNATION_PID 2>/dev/null; then
      kill $COLOR_ALTERNATION_PID 2>/dev/null
    fi
    COLOR_ALTERNATION_PID=""
    # Make sure to remove the stop files
    rm -f "/tmp/mpris_rgb_stop_alternation"
    rm -f "/tmp/mpris_rgb_pause_alternation"
  fi
}

# Ensure clean state at startup
rm -f "/tmp/mpris_rgb_stop_alternation"
rm -f "/tmp/mpris_rgb_pause_alternation"

# Modified process_artwork function to extract and cache all colors at once
process_artwork() {
  local ART_SOURCE="$1"
  local PLAYER_NAME="$2"
  local TRACK_TITLE="$3"
  local TRACK_ID="$4"  # Added parameter for track ID
  local COVER_PATH="$TEMP_DIR/current_cover.jpg"
  local TIMESTAMP=$(date "+%H:%M:%S")
  local CURRENT_DELAY=$ALTERNATION_DELAY  # Default delay
  local DEBUG_LOG="/tmp/mpris_rgb_debug.log"
  
  echo "$(date '+%H:%M:%S') process_artwork called for: \"$TRACK_TITLE\" with art source: $ART_SOURCE" >> "$DEBUG_LOG"
  
  log_message "process_artwork called for: \"$TRACK_TITLE\" with art source: $ART_SOURCE"
  
  log_message "Processing artwork for: $TRACK_TITLE"
  echo "$(date '+%H:%M:%S') Processing artwork for: $TRACK_TITLE" >> "$DEBUG_LOG"
  
  # Stop any existing color alternation
  stop_background_alternation
  
  # Download/copy art to temp location
  if [[ "$ART_SOURCE" == file://* ]]; then
    # Local file
    echo "$(date '+%H:%M:%S') Copying local file ${ART_SOURCE#file://} to $COVER_PATH" >> "$DEBUG_LOG"
    cp "${ART_SOURCE#file://}" "$COVER_PATH"
    if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
      echo "$(date '+%H:%M:%S') Successfully copied local file artwork" >> "$DEBUG_LOG"
    else
      echo "$(date '+%H:%M:%S') Failed to copy local file artwork" >> "$DEBUG_LOG"
    fi
  else
    # Remote URL
    echo "$(date '+%H:%M:%S') Downloading remote artwork from $ART_SOURCE" >> "$DEBUG_LOG"
    curl -s "$ART_SOURCE" -o "$COVER_PATH"
    if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
      echo "$(date '+%H:%M:%S') Successfully downloaded remote artwork" >> "$DEBUG_LOG"
    else
      echo "$(date '+%H:%M:%S') Failed to download remote artwork" >> "$DEBUG_LOG"
    fi
  fi
  
  # Check if the artwork file exists and has content
  if [[ ! -f "$COVER_PATH" || ! -s "$COVER_PATH" ]]; then
    echo "$(date '+%H:%M:%S') ERROR: Artwork file is missing or empty: $COVER_PATH" >> "$DEBUG_LOG"
    log_message "ERROR: Artwork file is missing or empty: $COVER_PATH"
    return
  fi
  
  # Create a temporary directory for processing
  local TEMP_PROCESS_DIR="$TEMP_DIR/process_$$"
  mkdir -p "$TEMP_PROCESS_DIR"
  
  log_message "Extracting colors from artwork..."
  
  # Method 1: Extract the most vibrant colors using advanced processing
  # First, extract a high-contrast, saturated version of the image
  magick "$COVER_PATH" -modulate 100,250,100 -contrast-stretch 3%x15% "$TEMP_PROCESS_DIR/vibrant.jpg"
  
  # Create color swatches from the image
  magick "$TEMP_PROCESS_DIR/vibrant.jpg" -colors 16 -unique-colors "$TEMP_PROCESS_DIR/colors.gif"
  
  # Create a debug image showing the extracted colors
  magick "$TEMP_PROCESS_DIR/colors.gif" -scale 200x50 "$TEMP_PROCESS_DIR/color_palette.png"

  # Save a copy of the processed artwork and palette for debugging
  mkdir -p "$TEMP_DIR/debug"
  cp "$COVER_PATH" "$TEMP_DIR/debug/last_artwork.jpg"
  cp "$TEMP_PROCESS_DIR/vibrant.jpg" "$TEMP_DIR/debug/last_vibrant.jpg"
  cp "$TEMP_PROCESS_DIR/color_palette.png" "$TEMP_DIR/debug/last_palette.png"
  
  log_message "Artwork and palette saved to $TEMP_DIR/debug/ for inspection"
  
  # Sort colors by saturation (highest first)
  # Extract multiple colors directly from the color palette
  declare -a COLORS_ARRAY
  
  # Get vibrant colors directly from the color palette
  log_message "Falling back to color palette extraction"
  log_message "Extracting vibrant colors from artwork..."
  
  # Get up to 16 distinct colors from the palette using a better method
  # First, get raw color output in text format
  magick "$TEMP_PROCESS_DIR/colors.gif" -unique-colors txt: > "$TEMP_PROCESS_DIR/colors.txt"
  echo "$(date '+%H:%M:%S') Generated color txt file with raw colors" >> "$DEBUG_LOG"
  
  # Parse the colors from the text file
  COLOR_INDEX=0
  while IFS= read -r line; do
    # Skip the header line
    if [[ "$line" == \#* ]]; then
      continue
    fi
    
    # Extract hex color from the line
    if [[ "$line" =~ \#([0-9A-Fa-f]{6}) ]]; then
      HEX_COLOR="${BASH_REMATCH[1]}"
      
      # Convert hex to RGB
      R=$((16#${HEX_COLOR:0:2}))
      G=$((16#${HEX_COLOR:2:2}))
      B=$((16#${HEX_COLOR:4:2}))
      
      # Create RGB color string
      COLOR="$R,$G,$B"
      
      echo "$(date '+%H:%M:%S') Extracted color from txt: RGB($R,$G,$B) - Hex: #$HEX_COLOR" >> "$DEBUG_LOG"
      
      # Skip black or very dark colors
      if [[ "$R" -lt 10 && "$G" -lt 10 && "$B" -lt 10 ]]; then
        echo "$(date '+%H:%M:%S') Skipping very dark color" >> "$DEBUG_LOG"
        continue
      fi
      
      # Add to array
      COLORS_ARRAY[$COLOR_INDEX]="$COLOR"
      log_message "Successfully extracted color $COLOR_INDEX: $COLOR"
      
      # Increment index
      COLOR_INDEX=$((COLOR_INDEX + 1))
      
      # Limit to 16 colors
      if [ $COLOR_INDEX -ge 16 ]; then
        break
      fi
    fi
  done < "$TEMP_PROCESS_DIR/colors.txt"
  
  # Debug the final color array
  echo "$(date '+%H:%M:%S') COLORS_ARRAY contains ${#COLORS_ARRAY[@]} colors after parsing" >> "$DEBUG_LOG"
  for ((i=0; i<${#COLORS_ARRAY[@]}; i++)); do
    if [[ -n "${COLORS_ARRAY[$i]}" ]]; then
      echo "$(date '+%H:%M:%S') COLORS_ARRAY[$i] = ${COLORS_ARRAY[$i]}" >> "$DEBUG_LOG"
    fi
  done

  # Try alternative extraction method if no colors were found
  if [[ ${#COLORS_ARRAY[@]} -eq 0 ]]; then
    log_message "Primary color extraction failed, trying alternative method"
    echo "$(date '+%H:%M:%S') Primary color extraction failed, trying alternative method" >> "$DEBUG_LOG"
    
    # Extract dominant colors directly from the cover art
    magick "$COVER_PATH" -scale 50x50 -colors 8 -unique-colors txt: > "$TEMP_PROCESS_DIR/alt_colors.txt"
    
    COLOR_INDEX=0
    while IFS= read -r line; do
      # Skip the header line
      if [[ "$line" == \#* ]]; then
        continue
      fi
      
      # Extract hex color from the line
      if [[ "$line" =~ \#([0-9A-Fa-f]{6}) ]]; then
        HEX_COLOR="${BASH_REMATCH[1]}"
        
        # Convert hex to RGB
        R=$((16#${HEX_COLOR:0:2}))
        G=$((16#${HEX_COLOR:2:2}))
        B=$((16#${HEX_COLOR:4:2}))
        
        # Create RGB color string
        COLOR="$R,$G,$B"
        
        echo "$(date '+%H:%M:%S') Alternative extraction: RGB($R,$G,$B) - Hex: #$HEX_COLOR" >> "$DEBUG_LOG"
        
        # Skip black or very dark colors
        if [[ "$R" -lt 10 && "$G" -lt 10 && "$B" -lt 10 ]]; then
          continue
        fi
        
        # Add to array
        COLORS_ARRAY[$COLOR_INDEX]="$COLOR"
        log_message "Alternative extraction succeeded for color $COLOR_INDEX: $COLOR"
        
        # Increment index
        COLOR_INDEX=$((COLOR_INDEX + 1))
        
        # Limit to 5 colors
        if [ $COLOR_INDEX -ge 5 ]; then
          break
        fi
      fi
    done < "$TEMP_PROCESS_DIR/alt_colors.txt"
  fi
  
  # Calculate color saturation and sort by it
  declare -a SATURATION_ARRAY
  
  log_message "Analyzing color saturation..."
  
  # Calculate saturation for each color
  for ((i=0; i<${#COLORS_ARRAY[@]}; i++)); do
    if [[ -z "${COLORS_ARRAY[$i]}" ]]; then
      SATURATION_ARRAY[$i]=0
      continue
    fi
    
    IFS=',' read -r R G B <<< "${COLORS_ARRAY[$i]}"
    
    # Calculate saturation as the difference between max and min RGB values
    MAX_VAL=$R
    MIN_VAL=$R
    
    if (( G > MAX_VAL )); then MAX_VAL=$G; fi
    if (( B > MAX_VAL )); then MAX_VAL=$B; fi
    if (( G < MIN_VAL )); then MIN_VAL=$G; fi
    if (( B < MIN_VAL )); then MIN_VAL=$B; fi
    
    # Calculate saturation as a percentage
    if (( MAX_VAL > 0 )); then
      SATURATION=$((100 * (MAX_VAL - MIN_VAL) / MAX_VAL))
    else
      SATURATION=0
    fi
    
    SATURATION_ARRAY[$i]=$SATURATION
  done
  
  # Sort colors by saturation (highest first)
  for ((i=0; i<${#COLORS_ARRAY[@]}-1; i++)); do
    for ((j=i+1; j<${#COLORS_ARRAY[@]}; j++)); do
      if [[ -z "${SATURATION_ARRAY[$i]}" || -z "${SATURATION_ARRAY[$j]}" ]]; then
        continue
      fi
      
      if (( ${SATURATION_ARRAY[$i]} < ${SATURATION_ARRAY[$j]} )); then
        # Swap colors
        TEMP_COLOR="${COLORS_ARRAY[$i]}"
        COLORS_ARRAY[$i]="${COLORS_ARRAY[$j]}"
        COLORS_ARRAY[$j]="$TEMP_COLOR"
        
        # Swap saturation values
        TEMP_SAT="${SATURATION_ARRAY[$i]}"
        SATURATION_ARRAY[$i]="${SATURATION_ARRAY[$j]}"
        SATURATION_ARRAY[$j]="$TEMP_SAT"
      fi
    done
  done
  
  # Create final colors array with exactly the required number of colors
  declare -a FINAL_COLORS
  declare -a SELECTED_COLORS
  
  # Use the original colors array to get the most vibrant colors first
  log_message "Selecting diverse color set from extracted colors..."
  
  # Start with the most vibrant color
  if [ ${#COLORS_ARRAY[@]} -gt 0 ] && [ -n "${COLORS_ARRAY[0]}" ]; then
    FINAL_COLORS[0]=${COLORS_ARRAY[0]}
    SELECTED_COLORS[0]=${COLORS_ARRAY[0]}
    log_message "Selected primary color: ${COLORS_ARRAY[0]}"
  else
    # Fallback if no colors were extracted
    FINAL_COLORS[0]="255,0,0"  # Default to red
    SELECTED_COLORS[0]="255,0,0"
    log_message "No colors extracted, using default primary color: 255,0,0"
  fi
  
  # Fill the remaining slots with diverse colors
  COLOR_COUNT=1
  
  # First try to find diverse colors from the extracted palette
  for ((i=1; i<${#COLORS_ARRAY[@]} && COLOR_COUNT<$NUM_COLORS; i++)); do
    if [ -n "${COLORS_ARRAY[$i]}" ]; then
      IFS=',' read -r R G B <<< "${COLORS_ARRAY[$i]}"
      
      # Check if this color is diverse enough from already selected colors
      if ! is_color_too_similar "$R" "$G" "$B" "${SELECTED_COLORS[@]}"; then
        FINAL_COLORS[$COLOR_COUNT]="${COLORS_ARRAY[$i]}"
        SELECTED_COLORS[$COLOR_COUNT]="${COLORS_ARRAY[$i]}"
        log_message "Added diverse color $COLOR_COUNT from palette: ${COLORS_ARRAY[$i]}"
        COLOR_COUNT=$((COLOR_COUNT + 1))
      else
        log_message "Skipped similar color: ${COLORS_ARRAY[$i]}"
      fi
    fi
  done
  
  # If we still need more colors, generate contrasting colors
  if [ $COLOR_COUNT -lt $NUM_COLORS ] && [ -n "${FINAL_COLORS[0]}" ]; then
    log_message "Generating contrasting colors to ensure diversity..."
    IFS=',' read -r BASE_R BASE_G BASE_B <<< "${FINAL_COLORS[0]}"
    
    # Generate contrasting colors using different methods
    for METHOD in 1 2 3 4; do
      if [ $COLOR_COUNT -lt $NUM_COLORS ]; then
        CONTRASTING_COLOR=$(generate_contrasting_color "$BASE_R" "$BASE_G" "$BASE_B" "$METHOD")
        IFS=',' read -r CONTR_R CONTR_G CONTR_B <<< "$CONTRASTING_COLOR"
        
        # Check if this contrasting color is diverse enough
        if ! is_color_too_similar "$CONTR_R" "$CONTR_G" "$CONTR_B" "${SELECTED_COLORS[@]}"; then
          FINAL_COLORS[$COLOR_COUNT]="$CONTRASTING_COLOR"
          SELECTED_COLORS[$COLOR_COUNT]="$CONTRASTING_COLOR"
          log_message "Added generated contrasting color $COLOR_COUNT: $CONTRASTING_COLOR"
          COLOR_COUNT=$((COLOR_COUNT + 1))
        fi
      fi
    done
  fi
  
  # If we STILL need more colors, use color wheel approach as a last resort
  while [ $COLOR_COUNT -lt $NUM_COLORS ]; do
    local HUE=$(( (COLOR_COUNT * 120) % 360 ))  # Space colors evenly around the wheel at 120° intervals
    
    # Convert HSV to RGB (with fixed high saturation and value)
    local H_SECTOR=$(( HUE / 60 ))
    local H_REMAINDER=$(( HUE % 60 ))
    local VAL=255
    local SAT=255
    local CHROMA=$(( (SAT * VAL) / 255 ))
    local X=$(( (CHROMA * (60 - H_REMAINDER)) / 60 ))
    
    # Initialize RGB values
    local R_OUT=0 G_OUT=0 B_OUT=0
    
    # Set RGB based on hue sector
    case $H_SECTOR in
      0) R_OUT=$CHROMA; G_OUT=$X; B_OUT=0 ;;
      1) R_OUT=$X; G_OUT=$CHROMA; B_OUT=0 ;;
      2) R_OUT=0; G_OUT=$CHROMA; B_OUT=$X ;;
      3) R_OUT=0; G_OUT=$X; B_OUT=$CHROMA ;;
      4) R_OUT=$X; G_OUT=0; B_OUT=$CHROMA ;;
      5) R_OUT=$CHROMA; G_OUT=0; B_OUT=$X ;;
    esac
    
    # Final adjustment for value
    local M=$(( VAL - CHROMA ))
    R_OUT=$(( R_OUT + M ))
    G_OUT=$(( G_OUT + M ))
    B_OUT=$(( B_OUT + M ))
    
    # Ensure values are in valid range
    R_OUT=$(( R_OUT > 255 ? 255 : (R_OUT < 0 ? 0 : R_OUT) ))
    G_OUT=$(( G_OUT > 255 ? 255 : (G_OUT < 0 ? 0 : G_OUT) ))
    B_OUT=$(( B_OUT > 255 ? 255 : (B_OUT < 0 ? 0 : B_OUT) ))
    
    WHEEL_COLOR="$R_OUT,$G_OUT,$B_OUT"
    FINAL_COLORS[$COLOR_COUNT]="$WHEEL_COLOR"
    SELECTED_COLORS[$COLOR_COUNT]="$WHEEL_COLOR"
    log_message "Added color wheel color $COLOR_COUNT: $WHEEL_COLOR (hue: $HUE°)"
    COLOR_COUNT=$((COLOR_COUNT + 1))
  done
  
  # Cleanup temp files
  rm -rf "$TEMP_PROCESS_DIR"
  
  # Get the first color to use immediately
  COLOR_INDEX=0
  CURRENT_RGB=${FINAL_COLORS[$COLOR_INDEX]}
  
  # Parse RGB values
  IFS=',' read -r R G B <<< "$CURRENT_RGB"
  
  # Always set the first color immediately
  TIMESTAMP=$(date "+%H:%M:%S")
  log_message "ACTIVE: $PLAYER_NAME - \"$TRACK_TITLE\""
  log_message "Color extracted: R=$R G=$G B=$B (Color index: $COLOR_INDEX)"
  
  # Calculate transition time based on BPM if available
  local TRANSITION_TIME=1.0  # Default transition time
  local TRACK_BPM=0
  
  if $USE_BPM; then
    TRACK_BPM=$(get_track_bpm "$TRACK_ID")
    
    if [ -n "$TRACK_BPM" ] && [ "$TRACK_BPM" != "0" ]; then
      TRANSITION_TIME=$(calculate_transition_from_bpm "$TRACK_BPM")
      log_message "⏱️ Using BPM-based transition time: ${TRANSITION_TIME}s (${TRACK_BPM} BPM)"
    else
      TRANSITION_TIME=1.0
      log_message "No BPM data available, using default transition time: ${TRANSITION_TIME}s"
    fi
  fi
  
  # Make sure TRANSITION_TIME is a simple numeric value
  TRANSITION_NUMBER=$(echo "$TRANSITION_TIME" | grep -o '[0-9]*\.[0-9]*' | head -1)
  # Default to 1.0 if extraction fails
  [ -z "$TRANSITION_NUMBER" ] && TRANSITION_NUMBER=1.0
  
  # Format to 2 decimal places
  TRANSITION_TIME_FORMATTED=$(printf "%.2f" $TRANSITION_NUMBER)
  
  # Prepare payload with fixed transition time
  PAYLOAD="{\"rgb\": [$R, $G, $B], \"transition\": $TRANSITION_TIME_FORMATTED}"
  
  # Add debug logging to track the payload
  log_message "JSON Payload: $PAYLOAD"
  
  # Send to Home Assistant webhook with reduced logging
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$WEBHOOK_URL" > /dev/null 2>/dev/null
  
  RESPONSE_CODE=$?
  if [ $RESPONSE_CODE -ne 0 ]; then
    log_message "Error calling webhook. Response code: $RESPONSE_CODE"
  elif $VERBOSE_LOGGING; then
    log_message "HomeAssistant webhook request successful"
  fi
  
  # Update last RGB values
  LAST_R="$R"
  LAST_G="$G"
  LAST_B="$B"
  LAST_COLOR_INDEX="$COLOR_INDEX"
  
  # Log all extracted colors for debugging
  log_message "Extracted colors:"
  for ((i=0; i<$NUM_COLORS; i++)); do
    IFS=',' read -r R G B <<< "${FINAL_COLORS[$i]}"
    log_message "Color $i: R=$R G=$G B=$B"
  done
  
  # Save all extracted colors to global cache
  COLORS_CACHE=""
  for ((i=0; i<$NUM_COLORS; i++)); do
    if [ $i -gt 0 ]; then
      COLORS_CACHE="$COLORS_CACHE|${FINAL_COLORS[$i]}"
    else
      COLORS_CACHE="${FINAL_COLORS[$i]}"
    fi
  done
  
  # After extracting colors but before applying minimum brightness, ensure diversity
  if [ "$FORCE_HUE_ROTATION" = "true" ]; then
    log_message "Enforcing color diversity with hue rotation..."
    
    # Get the primary color with the highest saturation
    PRIMARY_COLOR="${FINAL_COLORS[0]}"
    
    # Create new diverse colors array
    DIVERSE_COLORS=($(ensure_color_diversity "${FINAL_COLORS[@]}"))
    
    # Replace the colors with the diverse set
    for ((i=0; i<$NUM_COLORS && i<${#DIVERSE_COLORS[@]}; i++)); do
      FINAL_COLORS[$i]="${DIVERSE_COLORS[$i]}"
    done
    
    log_message "Colors after diversity enforcement:"
    for ((i=0; i<$NUM_COLORS; i++)); do
      IFS=',' read -r R G B <<< "${FINAL_COLORS[$i]}"
      log_message "   Color $((i+1)): RGB($R,$G,$B) - Hex: #$(printf '%02x%02x%02x' $R $G $B)"
    done
  fi
  
  # After extracting colors, before starting color alternation, apply minimum brightness
  for ((i=0; i<$NUM_COLORS; i++)); do
    if [ -n "${FINAL_COLORS[$i]}" ]; then
      IFS=',' read -r R G B <<< "${FINAL_COLORS[$i]}"
      
      # Validate numeric values
      R=$(echo "$R" | grep -o '[0-9]*' | head -1)
      G=$(echo "$G" | grep -o '[0-9]*' | head -1)
      B=$(echo "$B" | grep -o '[0-9]*' | head -1)
      
      # Set defaults if invalid
      [ -z "$R" ] && R=30
      [ -z "$G" ] && G=30
      [ -z "$B" ] && B=30
      
      # Apply minimum brightness adjustment - capture only the return value
      ADJUSTED_COLOR=$(ensure_minimum_brightness "$R" "$G" "$B")
      
      # Parse the adjusted color values 
      IFS=',' read -r NEW_R NEW_G NEW_B <<< "$ADJUSTED_COLOR"
      
      # Validate values again
      NEW_R=$(echo "$NEW_R" | grep -o '[0-9]*' | head -1)
      NEW_G=$(echo "$NEW_G" | grep -o '[0-9]*' | head -1)
      NEW_B=$(echo "$NEW_B" | grep -o '[0-9]*' | head -1)
      
      # Set defaults if invalid
      [ -z "$NEW_R" ] && NEW_R=30
      [ -z "$NEW_G" ] && NEW_G=30
      [ -z "$NEW_B" ] && NEW_B=30
      
      # Safe range
      NEW_R=$(( NEW_R > 255 ? 255 : (NEW_R < 30 ? 30 : NEW_R) ))
      NEW_G=$(( NEW_G > 255 ? 255 : (NEW_G < 30 ? 30 : NEW_G) ))
      NEW_B=$(( NEW_B > 255 ? 255 : (NEW_B < 30 ? 30 : NEW_B) ))
      
      FINAL_COLORS[$i]="$NEW_R,$NEW_G,$NEW_B"
    fi
  done
  
  # Log the brightness-adjusted colors
  log_message "Colors after brightness adjustment:"
  for ((i=0; i<$NUM_COLORS; i++)); do
    IFS=',' read -r R G B <<< "${FINAL_COLORS[$i]}"
    log_message "   Color $((i+1)): RGB($R,$G,$B) - Hex: #$(printf '%02x%02x%02x' $R $G $B)"
  done
  
  # Start background color alternation if enabled
  if [ $NUM_COLORS -gt 1 ]; then
    # Get BPM for the track to calculate color alternation timing
    local TRACK_BPM=0
    if $USE_BPM; then
      TRACK_BPM=$(get_track_bpm "$TRACK_ID")
      
      if [ -n "$TRACK_BPM" ] && [ "$TRACK_BPM" != "0" ]; then
        log_message "🎵 Track BPM detected: $TRACK_BPM"
        
        # Calculate delay based on BPM
        CURRENT_DELAY=$(calculate_delay_from_bpm "$TRACK_BPM")
        log_message "⏱️ Using BPM-based delay: ${CURRENT_DELAY}s (${TRACK_BPM} BPM)"
        
        # Calculate transition time based on BPM
        TRANSITION_TIME=$(calculate_transition_from_bpm "$TRACK_BPM")
        log_message "⏱️ Using BPM-based transition time: ${TRANSITION_TIME}s (${TRACK_BPM} BPM)"
      else
        log_message "⚠️ No valid BPM data available, using default delay: ${CURRENT_DELAY}s"
        TRANSITION_TIME=1.0 # Default transition time
      fi
    else
      log_message "ℹ️ BPM detection disabled in configuration, using default delay: ${CURRENT_DELAY}s"
      TRANSITION_TIME=1.0 # Default transition time
    fi
    
    log_message "🎨 Starting background color alternation with ${#FINAL_COLORS[@]} colors"
    
    # Log all colors in a more readable format
    log_message "🎨 Color scheme generated from artwork:"
    for ((i=0; i<$NUM_COLORS; i++)); do
      IFS=',' read -r R G B <<< "${FINAL_COLORS[$i]}"
      log_message "   Color $((i+1)): RGB($R,$G,$B) - Hex: #$(printf '%02x%02x%02x' $R $G $B)"
    done
    
    # Start the background process - skip passing redundant arguments to reduce duplicate logging
    alternate_colors_background "$CURRENT_DELAY" "${FINAL_COLORS[0]}" "${FINAL_COLORS[1]}" "${FINAL_COLORS[2]}" "$NUM_COLORS" "$WEBHOOK_URL" "$PLAYER_NAME" "$TRACK_TITLE" "$TRANSITION_TIME" &
    COLOR_ALTERNATION_PID=$!
    log_message "🔄 Background color alternation started with PID: $COLOR_ALTERNATION_PID (Delay: ${CURRENT_DELAY}s)"
  else
    log_message "ℹ️ Color alternation disabled (NUM_COLORS=$NUM_COLORS)"
  fi
}

# Modified function to check and log Spotify metadata
debug_spotify_metadata() {
  local PLAYER="$1"
  
  if [[ "$PLAYER" != *"spotify"* ]]; then
    return
  fi
  
  log_message "Debugging Spotify metadata:"
  
  # Get all metadata fields for debugging
  playerctl -p "$PLAYER" metadata 2>/dev/null | while read -r line; do
    log_message "Metadata: $line"
  done
}

# Function to get BPM for a track
get_bpm() {
  local TITLE="$1"
  local ARTIST="$2"
  local TRACK_ID="$3"
  local IS_LOCAL_FILE="$4"
  local BPM=0
  
  # Create cache key (artist + title)
  local CACHE_KEY="${ARTIST}-${TITLE}"
  local CACHE_FILE="$BPM_CACHE_DIR/$(echo "$CACHE_KEY" | md5sum | cut -d' ' -f1).bpm"
  
  # Check if we have cached BPM
  if [[ -f "$CACHE_FILE" ]]; then
    BPM=$(cat "$CACHE_FILE" | grep -o '^[0-9.]*$')
    if [[ -n "$BPM" ]]; then
      log_message "Found cached BPM: $BPM for $ARTIST - $TITLE"
      echo "$BPM"
      return
    else
      log_message "Found invalid cached BPM data, will refresh"
    fi
  fi
  
  # If it's a local file, try to extract BPM from the file itself
  if [[ "$IS_LOCAL_FILE" == "true" ]]; then
    log_message "Attempting to get BPM from local file"
    
    # Find the local music file
    local MUSIC_FILE=$(find_music_file "$ARTIST" "$TITLE" "$TITLE" "")
    
    if [[ -n "$MUSIC_FILE" ]]; then
      log_message "Found local music file: $MUSIC_FILE"
      # Extract BPM from the MP3 file
      BPM=$(get_bpm_from_mp3 "$MUSIC_FILE")
      
      if [[ -n "$BPM" && "$BPM" -gt 0 ]]; then
        log_message "Successfully extracted BPM from MP3: $BPM"
        # Save to cache
        mkdir -p "$BPM_CACHE_DIR"
        echo "$BPM" > "$CACHE_FILE"
        echo "$BPM"
        return
      fi
    fi
  fi
  
  # Try to look up BPM online
  log_message "Looking up BPM online for $ARTIST - $TITLE"
  
  # Use our Python script to look up BPM
  local SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  local BPM_LOOKUP_SCRIPT="$SCRIPT_DIR/bpm_web_lookup.py"
  
  if [[ -f "$BPM_LOOKUP_SCRIPT" ]]; then
    # Redirect stderr to /dev/null and capture only the clean number output
    BPM=$("$BPM_LOOKUP_SCRIPT" "$ARTIST" "$TITLE" 2>/dev/null | grep -o '^[0-9.]*$')
    
    if [[ -n "$BPM" && "$BPM" != "BPM not found" ]]; then
      log_message "Found BPM online: $BPM"
      # Save to cache
      mkdir -p "$BPM_CACHE_DIR"
      echo "$BPM" > "$CACHE_FILE"
      echo "$BPM"
      return
    fi
  fi
  
  # If all methods failed, return default
  log_message "Could not determine BPM, using default"
  echo "$BPM"
}

# Function to calculate color distance using a modified Delta E formula
calculate_color_distance() {
  local R1="$1"
  local G1="$2"
  local B1="$3"
  local R2="$4"
  local G2="$5"
  local B2="$6"
  
  # Calculate distance using 3D Euclidean distance
  local DISTANCE=$(echo "scale=0; sqrt( ($R2-$R1)^2 + ($G2-$G1)^2 + ($B2-$B1)^2 )" | bc)
  echo "$DISTANCE"
}

# Function to check if a color is too similar to existing colors
is_color_too_similar() {
  local R="$1"
  local G="$2"
  local B="$3"
  local -a EXISTING_COLORS=("${@:4}")  # All remaining arguments are existing colors
  
  for COLOR in "${EXISTING_COLORS[@]}"; do
    IFS=',' read -r EXIST_R EXIST_G EXIST_B <<< "$COLOR"
    local DISTANCE=$(calculate_color_distance "$R" "$G" "$B" "$EXIST_R" "$EXIST_G" "$EXIST_B")
    
    if [ "$DISTANCE" -lt "$COLOR_SIMILARITY_THRESHOLD" ]; then
      # Color is too similar to an existing one
      >&2 log_message "Color RGB($R,$G,$B) is too similar to RGB($EXIST_R,$EXIST_G,$EXIST_B) - distance: $DISTANCE < threshold: $COLOR_SIMILARITY_THRESHOLD"
      return 0
    fi
  done
  
  # Color is different enough from all existing colors
  return 1
}

# Function to create complementary or contrasting color
generate_contrasting_color() {
  local R="$1"
  local G="$2"
  local B="$3"
  local METHOD="$4"  # 1=complement, 2=rotate hue, 3=rotate another way
  
  case $METHOD in
    1) # Complementary color with increased saturation
       local NEW_R=$((255-R))
       local NEW_G=$((255-G))
       local NEW_B=$((255-B))
       # Boost saturation
       echo "$(ensure_minimum_brightness "$NEW_R" "$NEW_G" "$NEW_B")"
       ;;
    2) # Rotate hue (RGB -> GBR) with increased vibrancy
       echo "$(ensure_minimum_brightness "$G" "$B" "$R")"
       ;;
    3) # Rotate hue another way (RGB -> BRG) with increased vibrancy
       echo "$(ensure_minimum_brightness "$B" "$R" "$G")"
       ;;
    4) # High contrast version
       local NEW_R=$((R < 128 ? 255 : 30))
       local NEW_G=$((G < 128 ? 255 : 30))
       local NEW_B=$((B < 128 ? 255 : 30))
       echo "$(ensure_minimum_brightness "$NEW_R" "$NEW_G" "$NEW_B")"
       ;;
    *) # Default to complementary with increased vibrancy
       local NEW_R=$((255-R))
       local NEW_G=$((255-G))
       local NEW_B=$((255-B))
       echo "$(ensure_minimum_brightness "$NEW_R" "$NEW_G" "$NEW_B")"
       ;;
  esac
}

# Function to send a color to Home Assistant
send_color() {
  local R="$1"
  local G="$2"
  local B="$3"
  local TRANSITION_TIME="${4:-1}"
  
  # Format the RGB color
  local RGB="$R,$G,$B"
  
  # Skip if this is the same color as last time
  if [[ "$R" == "$LAST_R" && "$G" == "$LAST_G" && "$B" == "$LAST_B" ]]; then
    if [ "$VERBOSE_LOGGING" = "true" ]; then
      log_message "Skipping duplicate color: $RGB"
    fi
    return
  fi
  
  # Send the color via webhookoes
  send_webhook_request "$RGB" "$TRANSITION_TIME"
  
  # Save the current RGB values
  LAST_R="$R"
  LAST_G="$G"
  LAST_B="$B"
}

# Add these state tracking variables near the others at the top of the script
LAST_ACTIVE_PLAYER=""
LAST_SOURCE_PLAYER_PLAYING_STATE=""
AUTO_SWITCH_PLAYERS=${AUTO_SWITCH_PLAYERS:-true}  # Add this new configuration variable

# Modify the main loop to reduce redundant log messages
while true; do
  # Get all player metadata
  PLAYERS=$(playerctl -l 2>/dev/null)
  CHANGED_ART=""
  CHANGED_PLAYER=""
  CHANGED_TRACK=""
  SPOTIFY_CHANGED=false
  NEW_STATUS=false
  ARTWORK_UPDATED=false
  CURRENT_PAUSED_STATE=true  # Default to true until we find a playing player
  ACTIVE_SOURCE_PLAYER_PLAYING=false  # Track if the source player is actively playing
  ACTIVE_PLAYER=""  # Track which player is currently active
  
  # Read source player from file if not set in memory
  if [ -z "$COLORS_SOURCE_PLAYER" ] && [ -f "/tmp/mpris_rgb_source_player" ]; then
    COLORS_SOURCE_PLAYER=$(cat "/tmp/mpris_rgb_source_player")
    log_message "Loaded source player from file: $COLORS_SOURCE_PLAYER"
  fi
  
  if $FIRST_RUN; then
    log_message "Checking media players..."
    FIRST_RUN=false
  fi
  
  # First check all players to determine if any are playing
  # This avoids multiple pause/resume operations
  for PLAYER in $PLAYERS; do
    STATUS=$(playerctl -p "$PLAYER" status 2>/dev/null)
    
    if [ "$VERBOSE_LOGGING" = "true" ]; then
      log_message "Checking player: $PLAYER - Status: $STATUS"
    fi
    
    if [[ -n "$STATUS" && "$STATUS" == "Playing" ]]; then
      CURRENT_PAUSED_STATE=false
      ACTIVE_PLAYER="$PLAYER"
      
      # Check if this is the same player that the current colors are from
      # More robust comparison using simple substring check
      if [[ -n "$COLORS_SOURCE_PLAYER" && "$PLAYER" == *"$COLORS_SOURCE_PLAYER"* ]]; then
        ACTIVE_SOURCE_PLAYER_PLAYING=true
      fi
    fi
  done
  
  # Only log player detection when the state changes
  PLAYER_STATE_CHANGED=false
  
  # Check if active player changed
  if [[ "$ACTIVE_PLAYER" != "$LAST_ACTIVE_PLAYER" ]]; then
    PLAYER_STATE_CHANGED=true
    LAST_ACTIVE_PLAYER="$ACTIVE_PLAYER"
  fi
  
  # Check if source player playing state changed
  CURRENT_SOURCE_PLAYER_STATE="$ACTIVE_SOURCE_PLAYER_PLAYING"
  if [[ "$CURRENT_SOURCE_PLAYER_STATE" != "$LAST_SOURCE_PLAYER_PLAYING_STATE" ]]; then
    PLAYER_STATE_CHANGED=true
    LAST_SOURCE_PLAYER_PLAYING_STATE="$CURRENT_SOURCE_PLAYER_STATE"
  fi
  
  # Log player status only when something changes
  if [[ "$PLAYER_STATE_CHANGED" = true && -n "$ACTIVE_PLAYER" ]]; then
    # Check if the active player is in the ignored list
    IS_IGNORED_PLAYER=false
    if [[ "$ACTIVE_PLAYER" == *"haruna"* || 
          "$ACTIVE_PLAYER" == *"vlc"* || 
          "$ACTIVE_PLAYER" == *"mpv"* || 
          "$ACTIVE_PLAYER" == *"celluloid"* || 
          "$ACTIVE_PLAYER" == *"totem"* || 
          "$ACTIVE_PLAYER" == *"kdeconnect"* ]]; then
      IS_IGNORED_PLAYER=true
    fi

    if $ACTIVE_SOURCE_PLAYER_PLAYING; then
      log_message "Source player '$COLORS_SOURCE_PLAYER' is playing - resuming color rotation (matched with '$ACTIVE_PLAYER')"
    elif [[ -n "$COLORS_SOURCE_PLAYER" && "$AUTO_SWITCH_PLAYERS" = "true" && -n "$ACTIVE_PLAYER" && "$IS_IGNORED_PLAYER" = "false" ]]; then
      log_message "Different player '$ACTIVE_PLAYER' is playing - automatically switching to new player"
      # We'll let the normal processing handle the player switch
      # This ensures we get its artwork and process it correctly
    elif [[ -n "$COLORS_SOURCE_PLAYER" ]]; then
      log_message "Different player '$ACTIVE_PLAYER' is playing while colors are from '$COLORS_SOURCE_PLAYER' - keeping colors paused"
    fi
  fi
  
  # Apply pause/resume based on if the source player is playing
  if [ "$CURRENT_PAUSED_STATE" = true ]; then
    # Check if we need to log the pause action
    if [[ "$PLAYER_STATE_CHANGED" = true || "$LAST_SOURCE_PLAYER_PLAYING_STATE" = "true" ]]; then
      log_message "Pausing color alternation (no players playing)"
    fi
    pause_background_alternation
  elif [ "$ACTIVE_SOURCE_PLAYER_PLAYING" = true ]; then
    # Only resume color alternation if the source player is playing
    resume_background_alternation
  elif [[ "$AUTO_SWITCH_PLAYERS" = "true" && -n "$ACTIVE_PLAYER" ]]; then
    # Need to check if this is an ignored player before resetting the source player
    IS_IGNORED_PLAYER=false
    if [[ "$ACTIVE_PLAYER" == *"haruna"* || 
          "$ACTIVE_PLAYER" == *"vlc"* || 
          "$ACTIVE_PLAYER" == *"mpv"* || 
          "$ACTIVE_PLAYER" == *"celluloid"* || 
          "$ACTIVE_PLAYER" == *"totem"* || 
          "$ACTIVE_PLAYER" == *"kdeconnect"* ]]; then
      IS_IGNORED_PLAYER=true
    fi
    
    # Only reset source player and switch if this is not an ignored player
    if [ "$IS_IGNORED_PLAYER" = "false" ]; then
      # If auto-switching is enabled and there's a different active player,
      # we'll reset the source player and process the new active player's artwork in the next cycle
      COLORS_SOURCE_PLAYER=""
      # Remove the file to ensure consistency
      rm -f "/tmp/mpris_rgb_source_player" 2>/dev/null
    fi

    # Only log when state changes
    if [[ "$PLAYER_STATE_CHANGED" = true ]]; then
      log_message "Pausing color alternation (wrong player active)"
    fi
    pause_background_alternation
  fi
  
  # First pass - check if Spotify is playing and has artwork
  for PLAYER in $PLAYERS; do
    if [[ "$PLAYER" == *"spotify"* ]]; then
      # Check if Spotify is playing
      STATUS=$(playerctl -p "$PLAYER" status 2>/dev/null)
      
      # Continue with the rest of the Spotify handling
      if [[ "$STATUS" != "Playing" ]]; then
        continue
      fi
      
      # Set SPOTIFY_CHANGED to true whenever Spotify is playing
      SPOTIFY_CHANGED=true
      
      # Get track ID and other metadata
      ART_URL=$(playerctl -p "$PLAYER" metadata mpris:artUrl 2>/dev/null)
      TRACK_URL=$(playerctl -p "$PLAYER" metadata xesam:url 2>/dev/null)
      
      # Try different methods to get track ID
      TRACK_ID=$(playerctl -p "$PLAYER" metadata mpris:trackid 2>/dev/null)
      if [[ -z "$TRACK_ID" || "$TRACK_ID" != *"spotify"* ]]; then
        # Try extracting from URL if trackid doesn't contain "spotify"
        if [[ -n "$TRACK_URL" && "$TRACK_URL" == *"spotify"* ]]; then
          TRACK_ID=$TRACK_URL
          # Only log if track ID is different from last time
          if [[ "$TRACK_ID" != "$LAST_TRACK_ID" ]]; then
            log_message "Using xesam:url as track ID: $TRACK_ID"
            LAST_TRACK_ID="$TRACK_ID"
          fi
        else
          # Debug metadata to find the right field
          debug_spotify_metadata "$PLAYER"
          log_message "Failed to get valid Spotify track ID"
        fi
      else
        # Only log if track ID is different from last time
        if [[ "$TRACK_ID" != "$LAST_TRACK_ID" ]]; then
          log_message "Found track ID from mpris:trackid: $TRACK_ID"
          LAST_TRACK_ID="$TRACK_ID"
        fi
      fi
      
      TRACK_TITLE=$(playerctl -p "$PLAYER" metadata xesam:title 2>/dev/null)
      LAST_ART="${LAST_ARTS[$PLAYER]}"
      
      # Check if track or player changed to decide if we need to log
      if [[ "$PLAYER" != "$LAST_PLAYER" || "$TRACK_TITLE" != "$LAST_TRACK" ]]; then
        LAST_PLAYER="$PLAYER"
        LAST_TRACK="$TRACK_TITLE"
        NEW_STATUS=true
      fi
      
      # Check if it's a local file
      if [[ "$TRACK_URL" == *"/local/"* ]]; then
        if $NEW_STATUS; then
          log_message "Found local Spotify track: $TRACK_TITLE"
        fi
        
        # Check if we should reprocess this track
        if ! should_reprocess_track "$TRACK_ID" "$TRACK_TITLE" 0; then
          continue
        fi
        
        # Extract artist and title information
        ARTIST=$(playerctl -p "$PLAYER" metadata xesam:artist 2>/dev/null)
        
        # Extract the title without artist prefix if it has the format "Artist - Title"
        TITLE_ONLY="$TRACK_TITLE"
        TITLE_ARTIST=""
        if [[ "$TRACK_TITLE" == *" - "* ]]; then
          # Extract artist and title from the track title itself
          TITLE_ARTIST=$(echo "$TRACK_TITLE" | sed 's/ - .*$//')
          TITLE_ONLY=$(echo "$TRACK_TITLE" | sed 's/^.*- //')
          
          # If the artist info doesn't match the title info
          if [[ "$ARTIST" != "$TITLE_ARTIST" && $NEW_STATUS ]]; then
            ARTIST="$TITLE_ARTIST"
          fi
        fi
        
        # Clean up title and artist for search (remove parentheses, etc.)
        SEARCH_TITLE=$(echo "$TITLE_ONLY" | sed 's/[()[\]{}]/ /g')
        SEARCH_ARTIST=$(echo "$ARTIST" | sed 's/[()[\]{}]/ /g')
        
        # Find music file using the helper function
        MUSIC_FILE=$(find_music_file "$SEARCH_ARTIST" "$SEARCH_TITLE" "$TRACK_TITLE" "$TITLE_ARTIST")
        
        if [[ -n "$MUSIC_FILE" ]]; then
          if $NEW_STATUS; then
            log_message "Found local file: $MUSIC_FILE"
          fi
          
          # Create temp file for artwork extraction
          COVER_PATH="$TEMP_DIR/local_cover.jpg"
          
          # Extract artwork
          EXTRACTION_SUCCESS=$(extract_artwork "$MUSIC_FILE" "$COVER_PATH" "$NEW_STATUS")
          
          if [[ "$EXTRACTION_SUCCESS" == "true" ]]; then
            CHANGED_ART="file://$COVER_PATH"
            CHANGED_PLAYER="$PLAYER (local file)"
            CHANGED_TRACK="$TRACK_TITLE"
            SPOTIFY_CHANGED=true
            # Process immediately and mark as updated
            log_message "Calling process_artwork for local file: $MUSIC_FILE"
            echo "$(date '+%H:%M:%S') Calling process_artwork for local file: $MUSIC_FILE with art path: $CHANGED_ART" >> /tmp/mpris_rgb_debug.log
            process_artwork "$CHANGED_ART" "$CHANGED_PLAYER" "$CHANGED_TRACK" "$TRACK_ID"
            ARTWORK_UPDATED=true
            log_message "Artwork processing completed, ARTWORK_UPDATED set to true"
            echo "$(date '+%H:%M:%S') Artwork processing completed, ARTWORK_UPDATED=$ARTWORK_UPDATED" >> /tmp/mpris_rgb_debug.log
            break
          else
            if $NEW_STATUS; then
              # Even if extraction fails, still mark this Spotify track as the active one
              # This prevents other players from being processed this cycle
              SPOTIFY_CHANGED=true
              log_message "Artwork extraction failed but marked Spotify as changed"
              echo "$(date '+%H:%M:%S') Artwork extraction failed but marked Spotify as changed" >> /tmp/mpris_rgb_debug.log
            fi
          fi
        else
          if $NEW_STATUS; then
            log_message "Could not find local music file for: $TRACK_TITLE"
          fi
        fi
      # Use Spotify if it's playing and has valid artwork
      elif [[ -n "$ART_URL" ]]; then
        # Skip temporary files
        if [[ "$ART_URL" == *"/tmp/"* ]]; then
          continue
        fi
        
        # If artwork has changed or new status
        if [[ "$ART_URL" != "$LAST_ART" || $NEW_STATUS == true ]]; then
          if [[ "$ART_URL" != "$LAST_ART" ]]; then
            log_message "Spotify artwork changed: $TRACK_TITLE"
          fi
          
          LAST_ARTS["$PLAYER"]="$ART_URL"
          CHANGED_ART="$ART_URL"
          CHANGED_PLAYER="$PLAYER"
          CHANGED_TRACK="$TRACK_TITLE"
          SPOTIFY_CHANGED=true
          
          # Check if we should reprocess this track
          if ! should_reprocess_track "$TRACK_ID" "$TRACK_TITLE" 0; then
            ARTWORK_UPDATED=true
            break
          fi
          
          # Process immediately and mark as updated
          process_artwork "$CHANGED_ART" "$CHANGED_PLAYER" "$CHANGED_TRACK" "$TRACK_ID"
          ARTWORK_UPDATED=true
          break  # Found Spotify with artwork, no need to check others
        fi
      fi
    fi
  done
  
  # Only check other players if Spotify didn't change AND we haven't processed artwork yet
  if ! $SPOTIFY_CHANGED && ! $ARTWORK_UPDATED; then
    for PLAYER in $PLAYERS; do
      # Skip Spotify as we already checked it
      if [[ "$PLAYER" == *"spotify"* ]]; then
        continue
      fi
      
      # Skip players we want to ignore
      if [[ "$PLAYER" == *"haruna"* || 
            "$PLAYER" == *"vlc"* || 
            "$PLAYER" == *"mpv"* || 
            "$PLAYER" == *"celluloid"* || 
            "$PLAYER" == *"totem"* || 
            "$PLAYER" == *"kdeconnect"* ]]; then
        continue
      fi
      
      # Only check players that are playing
      STATUS=$(playerctl -p "$PLAYER" status 2>/dev/null)
      if [[ "$STATUS" != "Playing" ]]; then
        continue
      fi
      
      ART_URL=$(playerctl -p "$PLAYER" metadata mpris:artUrl 2>/dev/null)
      TRACK_ID=$(playerctl -p "$PLAYER" metadata mpris:trackid 2>/dev/null)
      LAST_ART="${LAST_ARTS[$PLAYER]}"
      
      # Check if this player's art changed
      if [[ "$ART_URL" != "$LAST_ART" && -n "$ART_URL" ]]; then
        # Skip temporary files
        if [[ "$ART_URL" == *"/tmp/"* ]]; then
          continue
        fi
        
        TRACK_TITLE=$(playerctl -p "$PLAYER" metadata xesam:title 2>/dev/null)
        log_message "Artwork changed for $PLAYER: $TRACK_TITLE"
        
        # Only log track ID if different from last time
        if [[ "$TRACK_ID" != "$LAST_TRACK_ID" && -n "$TRACK_ID" ]]; then
          log_message "Player track ID: $TRACK_ID"
          LAST_TRACK_ID="$TRACK_ID"
        fi
        
        LAST_ARTS["$PLAYER"]="$ART_URL"
        
        # Only process if we haven't updated artwork yet
        if ! $ARTWORK_UPDATED; then
          CHANGED_ART="$ART_URL"
          CHANGED_PLAYER="$PLAYER"
          CHANGED_TRACK="$TRACK_TITLE"
          
          # Check if we should reprocess this track
          if ! should_reprocess_track "$TRACK_ID" "$TRACK_TITLE" 0; then
            ARTWORK_UPDATED=true
            break
          fi
          
          # Process immediately and mark as updated
          process_artwork "$CHANGED_ART" "$CHANGED_PLAYER" "$CHANGED_TRACK" "$TRACK_ID"
          ARTWORK_UPDATED=true
          break  # Only process one player per cycle
        fi
      fi
    done
  fi
  
  # Check every POLL_INTERVAL seconds for new tracks
  # Only log on first run or when something changes
  if $FIRST_RUN; then
  log_message "Sleeping for $POLL_INTERVAL seconds to check for a different track"
  fi
  sleep $POLL_INTERVAL
done

# Make sure to clean up background processes when script exits
trap "stop_background_alternation" EXIT

