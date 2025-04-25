#!/bin/bash

# Load environment variables from .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Configuration variables
POLL_INTERVAL=2
TEMP_DIR="/tmp/mpris_covers"
NUM_COLORS=3  # Number of colors to extract
COLOR_INDEX=0  # Track which color to use

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

# Function to process artwork and send colors to Home Assistant
process_artwork() {
  local ART_SOURCE="$1"
  local PLAYER_NAME="$2"
  local TRACK_TITLE="$3"
  local COVER_PATH="$TEMP_DIR/current_cover.jpg"
  local TIMESTAMP=$(date "+%H:%M:%S")
  
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
  magick "$TEMP_PROCESS_DIR/vibrant.jpg" -crop 4x4@ +repage +adjoin "$TEMP_PROCESS_DIR/tile_%d.jpg"
  
  # Extract multiple colors from different tiles
  declare -a COLORS_ARRAY
  declare -a SATURATION_ARRAY
  
  # Initialize arrays
  for ((i=0; i<$NUM_COLORS; i++)); do
    COLORS_ARRAY[$i]="0,0,0"
    SATURATION_ARRAY[$i]=0
  done
  
  # Analyze each tile for saturation and color
  for TILE in "$TEMP_PROCESS_DIR"/tile_*.jpg; do
    # Calculate average saturation (using HSL colorspace where saturation is the second channel)
    SATURATION=$(magick "$TILE" -colorspace HSL -format "%[fx:mean.g*100]" info:)
    
    # Extract color from tile
    TILE_RGB=$(magick "$TILE" -resize 1x1\! \
      -format "%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]" info:)
    
    # Check if this color is more saturated than our current colors
    for ((i=0; i<$NUM_COLORS; i++)); do
      if (( $(echo "$SATURATION > ${SATURATION_ARRAY[$i]}" | bc -l 2>/dev/null) )); then
        # Shift the rest of the array to make room
        for ((j=$NUM_COLORS-1; j>$i; j--)); do
          SATURATION_ARRAY[$j]=${SATURATION_ARRAY[$j-1]}
          COLORS_ARRAY[$j]=${COLORS_ARRAY[$j-1]}
        done
        
        # Insert the new color
        SATURATION_ARRAY[$i]=$SATURATION
        COLORS_ARRAY[$i]=$TILE_RGB
        break
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
        awk '{printf("%d,%d,%d", $1*255, $2*255, $3*255)}')
    done
  fi
  
  # Ensure we have valid colors
  for ((i=0; i<$NUM_COLORS; i++)); do
    # Parse RGB values
    R=$(echo "${COLORS_ARRAY[$i]}" | cut -d "," -f 1)
    G=$(echo "${COLORS_ARRAY[$i]}" | cut -d "," -f 2)
    B=$(echo "${COLORS_ARRAY[$i]}" | cut -d "," -f 3)
    
    # Ensure values are integers and not empty
    R=$(echo "$R" | sed 's/[^0-9]//g')
    G=$(echo "$G" | sed 's/[^0-9]//g')
    B=$(echo "$B" | sed 's/[^0-9]//g')
    
    # Validate all values
    if [[ -z "$R" || -z "$G" || -z "$B" ]]; then
      # If extraction totally failed, use a vibrant default
      R=128
      G=$((50 + 50*i))
      B=128
    fi
    
    # If all colors are too similar (grayscale), boost the dominant channel
    RANGE=$(($(echo "$R $G $B" | tr ' ' '\n' | sort -nr | head -1) - $(echo "$R $G $B" | tr ' ' '\n' | sort -n | head -1)))
    if [ $RANGE -lt 30 ]; then
      # Find the highest channel and boost it
      if [ $R -ge $G ] && [ $R -ge $B ]; then
        # Red is highest, boost it
        R=$((R + 50))
        if [ $R -gt 255 ]; then R=255; fi
        G=$((G - 20))
        if [ $G -lt 0 ]; then G=0; fi
        B=$((B - 20))
        if [ $B -lt 0 ]; then B=0; fi
      elif [ $G -ge $R ] && [ $G -ge $B ]; then
        # Green is highest, boost it
        G=$((G + 50))
        if [ $G -gt 255 ]; then G=255; fi
        R=$((R - 20))
        if [ $R -lt 0 ]; then R=0; fi
        B=$((B - 20))
        if [ $B -lt 0 ]; then B=0; fi
      else
        # Blue is highest, boost it
        B=$((B + 50))
        if [ $B -gt 255 ]; then B=255; fi
        R=$((R - 20))
        if [ $R -lt 0 ]; then R=0; fi
        G=$((G - 20))
        if [ $G -lt 0 ]; then G=0; fi
      fi
    fi
    
    # Update the array with processed values
    COLORS_ARRAY[$i]="$R,$G,$B"
  done
  
  # Cleanup temp files
  rm -rf "$TEMP_PROCESS_DIR"
  
  # Get the current color to use (alternate between them)
  COLOR_INDEX=$((COLOR_INDEX % NUM_COLORS))
  CURRENT_RGB=${COLORS_ARRAY[$COLOR_INDEX]}
  
  # Parse RGB values
  R=$(echo "$CURRENT_RGB" | cut -d "," -f 1)
  G=$(echo "$CURRENT_RGB" | cut -d "," -f 2)
  B=$(echo "$CURRENT_RGB" | cut -d "," -f 3)
  
  # Only update if the color has actually changed
  if [[ "$R" != "$LAST_R" || "$G" != "$LAST_G" || "$B" != "$LAST_B" ]]; then
    echo "[$TIMESTAMP] ACTIVE: $PLAYER_NAME - \"$TRACK_TITLE\""
    echo "[$TIMESTAMP] Color extracted: R=$R G=$G B=$B (Color index: $COLOR_INDEX)"
    
    # Prepare payload
    PAYLOAD="{\"rgb\": [$R, $G, $B]}"
    
    # Send to Home Assistant webhook
    curl -s -X POST \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "$WEBHOOK_URL"
    
    echo "[$TIMESTAMP] Sent to Home Assistant"
    
    # Update last RGB values
    LAST_R="$R"
    LAST_G="$G"
    LAST_B="$B"
  fi
  
  # Increment the color index for next time
  COLOR_INDEX=$((COLOR_INDEX + 1))
}

# Function to log with timestamp
log_message() {
  local MSG="$1"
  local TIMESTAMP=$(date "+%H:%M:%S")
  echo "[$TIMESTAMP] $MSG"
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
  
  # Check every POLL_INTERVAL seconds
  sleep $POLL_INTERVAL
done

