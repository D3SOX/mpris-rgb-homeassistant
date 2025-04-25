#!/bin/bash

# Function to log with timestamp
log_message() {
  local MSG="$1"
  local TIMESTAMP=$(date "+%H:%M:%S")
  echo "[$TIMESTAMP] $MSG"
}

# Load environment variables from .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Configuration variables
POLL_INTERVAL=2  # Main polling interval for checking media players
ALTERNATION_DELAY=0.35  # Delay between color alternations
TEMP_DIR="/tmp/mpris_covers"
NUM_COLORS=3  # Number of colors to extract. Set to -1 to disable color alternation.
COLOR_INDEX=0  # Track which color to use
COLORS_CACHE=""  # Cache for extracted colors
COLOR_SIMILARITY_THRESHOLD=50  # Threshold for color similarity detection

# For debugging
log_message "Starting with NUM_COLORS=$NUM_COLORS and COLOR_INDEX=$COLOR_INDEX"

# Check if required variables are set
if [ -z "$WEBHOOK_URL" ]; then
  echo "Error: WEBHOOK_URL not defined in .env file"
  exit 1
fi

if [ -z "$MUSIC_DIR" ]; then
  echo "Error: MUSIC_DIR not defined in .env file"
  exit 1
fi

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

# Background color alternation process ID
COLOR_ALTERNATION_PID=""

mkdir -p "$TEMP_DIR"

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
  
  # Extract artwork with ffmpeg
  ffmpeg -y -i "$MUSIC_FILE" -an -vcodec copy "$COVER_PATH" 2>/dev/null
  
  # Check if extraction succeeded
  if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
    if $NEW_STATUS; then
      log_message "Successfully extracted artwork from local file"
    fi
    success=true
  else
    if $NEW_STATUS; then
      log_message "Trying alternate artwork extraction method"
    fi
    # Try alternate extraction method using ffmpeg
    ffmpeg -y -i "$MUSIC_FILE" -an -vf "scale=500:500" "$COVER_PATH" 2>/dev/null
    
    if [[ -f "$COVER_PATH" && -s "$COVER_PATH" ]]; then
      if $NEW_STATUS; then
        log_message "Successfully extracted artwork using alternate method"
      fi
      success=true
    fi
  fi
  
  echo "$success"
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
  
  log_message "Starting background color alternation with $NUM_CACHED_COLORS colors and delay $DELAY"
  
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
    
    # Update the array
    COLORS_ARRAY[$i]="$CR,$CG,$CB"
    
    # Remove redundant color logging - this is already done in the main process
  done
  
  # Continuously alternate colors at the specified delay
  while true; do
    # Exit if we should stop alternating (NUM_COLORS <= 0)
    if [ -f "/tmp/mpris_rgb_stop_alternation" ]; then
      log_message "Stopping background color alternation"
      rm -f "/tmp/mpris_rgb_stop_alternation"
      exit 0
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
    
    # No logging here - just send to Home Assistant
    
    # Prepare payload
    PAYLOAD="{\"rgb\": [$R, $G, $B]}"
    
    # Send to Home Assistant webhook
    curl -s -X POST \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "$WEBHOOK" >/dev/null 2>&1
    
    # Increment index for next time
    NEXT_INDEX=$((NEXT_INDEX + 1))
    
    # Sleep for the specified delay
    sleep "$DELAY"
  done
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
  fi
}

# Modified process_artwork function to extract and cache all colors at once
process_artwork() {
  local ART_SOURCE="$1"
  local PLAYER_NAME="$2"
  local TRACK_TITLE="$3"
  local COVER_PATH="$TEMP_DIR/current_cover.jpg"
  local TIMESTAMP=$(date "+%H:%M:%S")
  
  # First, stop any existing color alternation
  stop_background_alternation
  
  # Download/copy art to temp location
  if [[ "$ART_SOURCE" == file://* ]]; then
    # Local file
    cp "${ART_SOURCE#file://}" "$COVER_PATH"
  else
    # Remote URL
    curl -s "$ART_SOURCE" -o "$COVER_PATH"
  fi
  
  # Create a temporary directory for processing
  local TEMP_PROCESS_DIR="$TEMP_DIR/process_$$"
  mkdir -p "$TEMP_PROCESS_DIR"
  
  # Method 1: Extract the most vibrant colors using advanced processing
  # First, extract a high-contrast, saturated version of the image
  magick "$COVER_PATH" -modulate 100,250,100 -contrast-stretch 3%x15% "$TEMP_PROCESS_DIR/vibrant.jpg"
  
  # Create color swatches from the image
  magick "$TEMP_PROCESS_DIR/vibrant.jpg" -colors 16 -unique-colors "$TEMP_PROCESS_DIR/colors.gif"
  
  # Split the image into tiles and find the most colorful tiles
  # Using a finer grid (6x6) to capture more color variety
  magick "$TEMP_PROCESS_DIR/vibrant.jpg" -crop 6x6@ +repage +adjoin "$TEMP_PROCESS_DIR/tile_%d.jpg"
  
  # Extract multiple colors from different tiles
  declare -a COLORS_ARRAY
  declare -a SATURATION_ARRAY
  declare -a HUE_ARRAY
  
  # Initialize arrays
  for ((i=0; i<16; i++)); do
    COLORS_ARRAY[$i]="0,0,0"
    SATURATION_ARRAY[$i]=0
    HUE_ARRAY[$i]=0
  done
  
  # Analyze each tile for saturation, hue, and color
  for TILE in "$TEMP_PROCESS_DIR"/tile_*.jpg; do
    # Extract HSL values (Hue, Saturation, Lightness)
    HSL=$(magick "$TILE" -colorspace HSL -format "%[fx:mean.r*360],%[fx:mean.g*100],%[fx:mean.b*100]" info:)
    HUE=$(echo "$HSL" | cut -d "," -f 1)
    SATURATION=$(echo "$HSL" | cut -d "," -f 2)
    LIGHTNESS=$(echo "$HSL" | cut -d "," -f 3)
    
    # Skip very dark or very light tiles
    if (( $(echo "$LIGHTNESS < 15 || $LIGHTNESS > 85" | bc -l 2>/dev/null) )); then
      continue
    fi
    
    # Extract color from tile - make sure it's in 0-255 range
    TILE_RGB=$(magick "$TILE" -resize 1x1\! -format "%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]" info:)
    
    # Calculate color score (combination of saturation and uniqueness)
    COLOR_SCORE=$SATURATION
    
    # Check if this color is unique enough compared to colors we already have
    IS_UNIQUE=true
    for ((j=0; j<16; j++)); do
      if [[ "${COLORS_ARRAY[$j]}" == "0,0,0" ]]; then
        continue  # Skip uninitialized positions
      fi
      
      # Calculate hue difference with existing colors
      HUE_DIFF=$(echo "scale=2; a=$HUE; b=${HUE_ARRAY[$j]}; if(a>b) a-b else b-a" | bc -l 2>/dev/null)
      # If hue difference is greater than 180, calculate the shorter path around the color wheel
      if (( $(echo "$HUE_DIFF > 180" | bc -l 2>/dev/null) )); then
        HUE_DIFF=$(echo "scale=2; 360-$HUE_DIFF" | bc -l 2>/dev/null)
      fi
      
      # If hues are too similar, mark as not unique
      if (( $(echo "$HUE_DIFF < 30" | bc -l 2>/dev/null) )); then
        IS_UNIQUE=false
        break
      fi
    done
    
    # Add color to our collection if it's unique enough or initial positions
    if $IS_UNIQUE || [[ "${COLORS_ARRAY[0]}" == "0,0,0" ]]; then
      # Find an open slot or lowest saturation slot
      TARGET_SLOT=-1
      MIN_SATURATION=101  # Above max possible saturation
      
      for ((j=0; j<16; j++)); do
        if [[ "${COLORS_ARRAY[$j]}" == "0,0,0" ]]; then
          TARGET_SLOT=$j
          break
        elif (( $(echo "${SATURATION_ARRAY[$j]} < $MIN_SATURATION" | bc -l 2>/dev/null) )); then
          MIN_SATURATION=${SATURATION_ARRAY[$j]}
          TARGET_SLOT=$j
        fi
      done
      
      if [[ $TARGET_SLOT -ne -1 ]] && (( $(echo "$SATURATION > $MIN_SATURATION" | bc -l 2>/dev/null) )); then
        COLORS_ARRAY[$TARGET_SLOT]=$TILE_RGB
        SATURATION_ARRAY[$TARGET_SLOT]=$SATURATION
        HUE_ARRAY[$TARGET_SLOT]=$HUE
      fi
    fi
  done
  
  # Sort colors by saturation (highest first)
  for ((i=0; i<15; i++)); do
    for ((j=i+1; j<16; j++)); do
      if (( $(echo "${SATURATION_ARRAY[$i]} < ${SATURATION_ARRAY[$j]}" | bc -l 2>/dev/null) )); then
        # Swap colors
        TEMP_COLOR=${COLORS_ARRAY[$i]}
        COLORS_ARRAY[$i]=${COLORS_ARRAY[$j]}
        COLORS_ARRAY[$j]=$TEMP_COLOR
        
        # Swap saturation
        TEMP_SAT=${SATURATION_ARRAY[$i]}
        SATURATION_ARRAY[$i]=${SATURATION_ARRAY[$j]}
        SATURATION_ARRAY[$j]=$TEMP_SAT
        
        # Swap hue
        TEMP_HUE=${HUE_ARRAY[$i]}
        HUE_ARRAY[$i]=${HUE_ARRAY[$j]}
        HUE_ARRAY[$j]=$TEMP_HUE
      fi
    done
  done
  
  # If we couldn't extract enough colors, fall back to the colors.gif
  if [[ "${COLORS_ARRAY[0]}" == "0,0,0" ]]; then
    log_message "Falling back to color palette extraction"
    # Extract top colors from the palette
    for ((i=0; i<$NUM_COLORS; i++)); do
      COLORS_ARRAY[$i]=$(magick "$TEMP_PROCESS_DIR/colors.gif" -format "%[pixel:p{$i,0}]" info: | 
        sed 's/srgb(//' | sed 's/)//' | tr ',' ' ' | 
        awk '{printf("%d,%d,%d", int($1*255), int($2*255), int($3*255))}')
    done
  fi
  
  # Check color variety
  local ALL_SIMILAR=true
  local SIMILARITY_COUNT=0
  
  # Create final colors array with exactly the required number of colors
  declare -a FINAL_COLORS
  for ((i=0; i<$NUM_COLORS; i++)); do
    if [ $i -lt ${#COLORS_ARRAY[@]} ] && [ "${COLORS_ARRAY[$i]}" != "0,0,0" ]; then
      FINAL_COLORS[$i]=${COLORS_ARRAY[$i]}
    else
      # If we don't have enough valid colors, create complementary ones
      if [ $i -gt 0 ]; then
        # Get a previous valid color
        local BASE_COLOR=${FINAL_COLORS[0]}
        
        # Create complementary color by offsetting the hue
        IFS=',' read -r R G B <<< "$BASE_COLOR"
        
        # Convert RGB to HSL, shift the hue, and convert back to RGB
        # Here we're using simple hue shifting based on position
        # Hue offsets: 120° and 240° for complementary colors in a triad
        local HUE_OFFSET=$((120 * i % 360))
        
        # Use ImageMagick to handle the conversion
        TEMP_COLOR_FILE="$TEMP_PROCESS_DIR/temp_color_$i.png"
        echo "rgb($R,$G,$B)" | magick -size 1x1 xc:- -colorspace HSL \
          -modulate 100,100,$((100 + HUE_OFFSET)) -colorspace sRGB \
          -format "%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]" info: > "$TEMP_COLOR_FILE" 2>/dev/null
        
        # Ensure we get 0-255 range for RGB values
        NEW_COLOR=$(cat "$TEMP_COLOR_FILE" | sed -E 's/[^0-9,]//g')
        
        # Check if values are valid
        IFS=',' read -r NR NG NB <<< "$NEW_COLOR"
        if [[ -z "$NR" || -z "$NG" || -z "$NB" ]] || \
           [[ "$NR" -gt 255 || "$NG" -gt 255 || "$NB" -gt 255 ]]; then
          # Use fallback color if values are invalid
          case $i in
            1) NEW_COLOR="0,255,0" ;;    # Green
            2) NEW_COLOR="0,0,255" ;;    # Blue
            *) NEW_COLOR="255,255,0" ;;  # Yellow
          esac
        fi
        
        FINAL_COLORS[$i]=$NEW_COLOR
      else
        # Default vibrant color if we have no valid colors at all
        case $i in
          0) FINAL_COLORS[$i]="255,0,0" ;;    # Red
          1) FINAL_COLORS[$i]="0,255,0" ;;    # Green
          2) FINAL_COLORS[$i]="0,0,255" ;;    # Blue
          *) FINAL_COLORS[$i]="255,255,0" ;;  # Yellow
        esac
      fi
    fi
  done
  
  # Now check if the selected colors are too similar
  for ((i=0; i<$NUM_COLORS-1; i++)); do
    for ((j=i+1; j<$NUM_COLORS; j++)); do
      IFS=',' read -r R1 G1 B1 <<< "${FINAL_COLORS[$i]}"
      IFS=',' read -r R2 G2 B2 <<< "${FINAL_COLORS[$j]}"
      
      # Validate RGB values (ensure they're in 0-255 range)
      R1=$(echo "$R1" | grep -o '[0-9]*' | head -1)
      G1=$(echo "$G1" | grep -o '[0-9]*' | head -1)
      B1=$(echo "$B1" | grep -o '[0-9]*' | head -1)
      R2=$(echo "$R2" | grep -o '[0-9]*' | head -1)
      G2=$(echo "$G2" | grep -o '[0-9]*' | head -1)
      B2=$(echo "$B2" | grep -o '[0-9]*' | head -1)
      
      # Set defaults if invalid
      [ -z "$R1" ] && R1=0
      [ -z "$G1" ] && G1=0
      [ -z "$B1" ] && B1=0
      [ -z "$R2" ] && R2=0
      [ -z "$G2" ] && G2=0
      [ -z "$B2" ] && B2=0
      
      # Ensure values are in valid range
      R1=$(( R1 > 255 ? 255 : R1 ))
      G1=$(( G1 > 255 ? 255 : G1 ))
      B1=$(( B1 > 255 ? 255 : B1 ))
      R2=$(( R2 > 255 ? 255 : R2 ))
      G2=$(( G2 > 255 ? 255 : G2 ))
      B2=$(( B2 > 255 ? 255 : B2 ))
      
      # Update the array with validated values
      FINAL_COLORS[$i]="$R1,$G1,$B1"
      FINAL_COLORS[$j]="$R2,$G2,$B2"
      
      # Calculate color difference using a simple Euclidean distance
      COLOR_DIFF=$(echo "scale=2; sqrt(($R1-$R2)^2 + ($G1-$G2)^2 + ($B1-$B2)^2)" | bc -l)
      
      if (( $(echo "$COLOR_DIFF < $COLOR_SIMILARITY_THRESHOLD" | bc -l) )); then
        SIMILARITY_COUNT=$((SIMILARITY_COUNT + 1))
      fi
    done
  done
  
  # If more than half of the color pairs are too similar, use complementary colors instead
  if [ $SIMILARITY_COUNT -gt $(($NUM_COLORS * ($NUM_COLORS - 1) / 4)) ]; then
    log_message "Detected too many similar colors. Generating complementary colors."
    
    # Keep the first color and generate complementary ones
    BASE_COLOR=${FINAL_COLORS[0]}
    IFS=',' read -r R G B <<< "$BASE_COLOR"
    
    # Ensure the base color is vibrant
    # Find the max channel
    MAX_CHANNEL=$R
    MAX_COLOR="R"
    if [ $G -gt $MAX_CHANNEL ]; then
      MAX_CHANNEL=$G
      MAX_COLOR="G"
    fi
    if [ $B -gt $MAX_CHANNEL ]; then
      MAX_CHANNEL=$B
      MAX_COLOR="B"
    fi
    
    # Boost the max channel and reduce others to create a more vibrant base
    case $MAX_COLOR in
      "R")
        R=$(( R < 200 ? R + 55 : 255 ))
        G=$(( G > 50 ? G - 30 : 0 ))
        B=$(( B > 50 ? B - 30 : 0 ))
        ;;
      "G")
        G=$(( G < 200 ? G + 55 : 255 ))
        R=$(( R > 50 ? R - 30 : 0 ))
        B=$(( B > 50 ? B - 30 : 0 ))
        ;;
      "B")
        B=$(( B < 200 ? B + 55 : 255 ))
        R=$(( R > 50 ? R - 30 : 0 ))
        G=$(( G > 50 ? G - 30 : 0 ))
        ;;
    esac
    
    # Validate RGB values
    R=$(( R > 255 ? 255 : (R < 0 ? 0 : R) ))
    G=$(( G > 255 ? 255 : (G < 0 ? 0 : G) ))
    B=$(( B > 255 ? 255 : (B < 0 ? 0 : B) ))
    
    # Update the base color
    FINAL_COLORS[0]="$R,$G,$B"
    
    # Generate complementary colors with evenly distributed hues
    for ((i=1; i<$NUM_COLORS; i++)); do
      # Calculate hue offset based on position (distribute evenly around color wheel)
      local HUE_OFFSET=$((360 / NUM_COLORS * i))
      
      # Use ImageMagick to create the complementary color
      TEMP_COLOR_FILE="$TEMP_PROCESS_DIR/comp_color_$i.png"
      
      # Use printf to ensure proper RGB format
      echo "rgb($R,$G,$B)" | magick -size 1x1 xc:- -colorspace HSL \
        -modulate 100,100,$((100 + HUE_OFFSET)) -colorspace sRGB \
        -format "%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]" info: > "$TEMP_COLOR_FILE" 2>/dev/null
      
      # Extract and validate the RGB values
      NEW_RGB=$(cat "$TEMP_COLOR_FILE" | sed -E 's/[^0-9,]//g')
      
      # Check if values are valid
      IFS=',' read -r NR NG NB <<< "$NEW_RGB"
      if [[ -z "$NR" || -z "$NG" || -z "$NB" ]] || \
         [[ "$NR" -gt 255 || "$NG" -gt 255 || "$NB" -gt 255 ]]; then
        # Use fallback complementary colors
        case $i in
          1) NEW_RGB="0,255,255" ;;  # Cyan
          2) NEW_RGB="255,0,255" ;;  # Magenta
          3) NEW_RGB="255,255,0" ;;  # Yellow
          *) NEW_RGB="128,0,255" ;;  # Purple
        esac
      fi
      
      FINAL_COLORS[$i]=$NEW_RGB
    done
  fi
  
  # Ensure colors are valid and enhance them
  for ((i=0; i<$NUM_COLORS; i++)); do
    # Parse RGB values
    IFS=',' read -r R G B <<< "${FINAL_COLORS[$i]}"
    
    # Ensure values are integers and not empty
    R=$(echo "$R" | grep -o '[0-9]*' | head -1)
    G=$(echo "$G" | grep -o '[0-9]*' | head -1)
    B=$(echo "$B" | grep -o '[0-9]*' | head -1)
    
    # Validate and set defaults if values are invalid
    if [[ -z "$R" || -z "$G" || -z "$B" || "$R" -gt 255 || "$G" -gt 255 || "$B" -gt 255 ]]; then
      # If extraction totally failed, use a vibrant default
      case $i in
        0) R=255; G=0; B=0 ;;    # Red
        1) R=0; G=255; B=0 ;;    # Green
        2) R=0; G=0; B=255 ;;    # Blue
        *) R=255; G=255; B=0 ;;  # Yellow
      esac
    fi
    
    # Ensure values are in valid range
    R=$(( R > 255 ? 255 : (R < 0 ? 0 : R) ))
    G=$(( G > 255 ? 255 : (G < 0 ? 0 : G) ))
    B=$(( B > 255 ? 255 : (B < 0 ? 0 : B) ))
    
    # Enhance color vibrance - boost the dominant channel
    MAX_CHANNEL=$R
    if [ $G -gt $MAX_CHANNEL ]; then MAX_CHANNEL=$G; fi
    if [ $B -gt $MAX_CHANNEL ]; then MAX_CHANNEL=$B; fi
    
    # Adjust the dominant channel saturation if colors are dull
    if [ $MAX_CHANNEL -lt 100 ]; then
      if [ $R -eq $MAX_CHANNEL ]; then R=$((R + 100)); fi
      if [ $G -eq $MAX_CHANNEL ]; then G=$((G + 100)); fi
      if [ $B -eq $MAX_CHANNEL ]; then B=$((B + 100)); fi
      
      # Cap at 255
        if [ $R -gt 255 ]; then R=255; fi
        if [ $G -gt 255 ]; then G=255; fi
        if [ $B -gt 255 ]; then B=255; fi
    fi
    
    # Update the array with enhanced values
    FINAL_COLORS[$i]="$R,$G,$B"
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
  echo "[$TIMESTAMP] ACTIVE: $PLAYER_NAME - \"$TRACK_TITLE\""
  echo "[$TIMESTAMP] Color extracted: R=$R G=$G B=$B (Color index: $COLOR_INDEX)"
  
  # Prepare payload
  PAYLOAD="{\"rgb\": [$R, $G, $B]}"
  
  # Send to Home Assistant webhook
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$WEBHOOK_URL"
  
  TIMESTAMP=$(date "+%H:%M:%S")
  echo "[$TIMESTAMP] Sent to Home Assistant"
  
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
  
  # Start background color alternation if enabled
  if [ $NUM_COLORS -gt 1 ]; then
    log_message "Starting background color alternation with ${#FINAL_COLORS[@]} colors"
    # Start the background process - skip passing redundant arguments to reduce duplicate logging
    alternate_colors_background "$ALTERNATION_DELAY" "${FINAL_COLORS[0]}" "${FINAL_COLORS[1]}" "${FINAL_COLORS[2]}" "$NUM_COLORS" "$WEBHOOK_URL" "$PLAYER_NAME" "$TRACK_TITLE" &
    COLOR_ALTERNATION_PID=$!
    log_message "Background color alternation started with PID: $COLOR_ALTERNATION_PID"
  else
    log_message "Color alternation disabled (NUM_COLORS=$NUM_COLORS)"
  fi
}

while true; do
  # Get all player metadata
  PLAYERS=$(playerctl -l 2>/dev/null)
  CHANGED_ART=""
  CHANGED_PLAYER=""
  CHANGED_TRACK=""
  SPOTIFY_CHANGED=false
  NEW_STATUS=false
  ARTWORK_UPDATED=false
  
  if $FIRST_RUN; then
    log_message "Checking media players..."
    FIRST_RUN=false
  fi
  
  # First pass - check if Spotify is playing and has artwork
  for PLAYER in $PLAYERS; do
    if [[ "$PLAYER" == *"spotify"* ]]; then
      # Check if Spotify is playing
      STATUS=$(playerctl -p "$PLAYER" status 2>/dev/null)
      if [[ "$STATUS" != "Playing" ]]; then
        continue
      fi
      
      # Set SPOTIFY_CHANGED to true whenever Spotify is playing
      SPOTIFY_CHANGED=true
      
      ART_URL=$(playerctl -p "$PLAYER" metadata mpris:artUrl 2>/dev/null)
      TRACK_URL=$(playerctl -p "$PLAYER" metadata xesam:url 2>/dev/null)
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
            process_artwork "$CHANGED_ART" "$CHANGED_PLAYER" "$CHANGED_TRACK"
            ARTWORK_UPDATED=true
            break
          else
            if $NEW_STATUS; then
              # Even if extraction fails, still mark this Spotify track as the active one
              # This prevents other players from being processed this cycle
              SPOTIFY_CHANGED=true
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
          
          # Process immediately and mark as updated
          process_artwork "$CHANGED_ART" "$CHANGED_PLAYER" "$CHANGED_TRACK"
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
      LAST_ART="${LAST_ARTS[$PLAYER]}"
      
      # Check if this player's art changed
      if [[ "$ART_URL" != "$LAST_ART" && -n "$ART_URL" ]]; then
        # Skip temporary files
        if [[ "$ART_URL" == *"/tmp/"* ]]; then
          continue
        fi
        
        TRACK_TITLE=$(playerctl -p "$PLAYER" metadata xesam:title 2>/dev/null)
        log_message "Artwork changed for $PLAYER: $TRACK_TITLE"
        LAST_ARTS["$PLAYER"]="$ART_URL"
        
        # Only process if we haven't updated artwork yet
        if ! $ARTWORK_UPDATED; then
          CHANGED_ART="$ART_URL"
          CHANGED_PLAYER="$PLAYER"
          CHANGED_TRACK="$TRACK_TITLE"
          
          # Process immediately and mark as updated
          process_artwork "$CHANGED_ART" "$CHANGED_PLAYER" "$CHANGED_TRACK"
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

