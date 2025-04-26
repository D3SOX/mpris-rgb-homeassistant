# MPRIS RGB HomeAssistant Integration

This script connects your media players to Home Assistant for RGB lighting control based on album artwork.

## Features

- Extracts vibrant colors from album artwork
- Dynamically alternates colors based on track BPM (beats per minute)
- Works with Spotify and other MPRIS-compatible media players
- Supports local music files
- Web-based BPM lookup for tracks

The script will attempt to get BPM information in the following order:
1. Web-based BPM lookup services
2. For local files: direct extraction from MP3 metadata
3. Estimation based on genre detection from track titles

## Usage

Run the script:

```bash
./mpris_rgb_homeassistant.sh
```

For automatic startup, add it to your login scripts or create a systemd service.

## Configuration Options

Edit the script to adjust these variables:

- `POLL_INTERVAL`: How often to check for playing media (seconds)
- `ALTERNATION_DELAY`: Default delay between color alternations (used when BPM is unavailable)
- `NUM_COLORS`: Number of colors to extract from artwork
- `MIN_BPM_DELAY`: Minimum delay for fast-tempo tracks 
- `MAX_BPM_DELAY`: Maximum delay for slow-tempo tracks
- `USE_BPM`: Set to false to disable BPM detection

## Requirements



## Prerequisites

- Linux system with
  - systemd
  - playerctl
  - ImageMagick
  - curl
  - bc (basic calculator)
  - Bash
  - Media players that support MPRIS
- Home Assistant setup with RGB devices

## Installation

1. Clone this repository to your local share directory:
```bash
mkdir -p ~/.local/share/mpris-rgb-homeassistant
git clone https://github.com/d3sox/mpris-rgb-homeassistant.git ~/.local/share/mpris-rgb-homeassistant
cd ~/.local/share/mpris-rgb-homeassistant
```

2. Install the systemd service:
```bash
mkdir -p ~/.config/systemd/user/
cp ~/.local/share/mpris-rgb-homeassistant/mpris-rgb-homeassistant.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

3. Create a .env file in the installation directory:
```bash
cd ~/.local/share/mpris-rgb-homeassistant
cat > .env << EOF
WEBHOOK_URL="http://your-home-assistant:8123/api/webhook/unique_webhook_id"
MUSIC_DIR="/home/yourusername/Music/"
EOF
```

4. Enable and start the service:
```bash
systemctl --user enable --now mpris-rgb-homeassistant.service
```

## Verify Operation

Check the service status:
```bash
systemctl --user status mpris-rgb-homeassistant.service
```

View logs in real-time:
```bash
journalctl --user -u mpris-rgb-homeassistant -f
```

## Home Assistant Webhook Setup

To receive and process RGB data from this script, you need to create a webhook in Home Assistant:

1. Go to **Settings** → **Automations & Scenes** → **Create Automation**
2. Choose to create a blank automation
3. Configure the automation as follows:

```yaml
alias: Light Webhook
description: Update Light Webhook for multiple colors with dynamic transition time
triggers:
  - trigger: webhook
    allowed_methods:
      - POST
      - PUT
    local_only: false
    webhook_id: "unique_webhook_id"  # Generate a unique ID or string
conditions:
  - condition: state
    entity_id: input_boolean.sync_bulb_right_wall
    state: "on"
actions:
  - parallel:
      - action: light.turn_on
        metadata: {}
        data:
          transition: "{{ trigger.json.transition | default(1) }}"
          rgb_color: "{{ trigger.json.rgb }}"
        target:
          entity_id: light.your_rgb_light  # Replace with your light entity
      - if:
          - condition: template
            value_template: "{{ state_attr('light.your_rgb_light','music_mode') == True }}"
        then:
          - action: yeelight.set_music_mode
            metadata: {}
            data:
              music_mode: false
            target:
              entity_id: light.your_rgb_light  # Replace with your light entity
        else: []
mode: single
```

4. Save the automation

Once set up, the webhook URL will be:
```
http://your-home-assistant:8123/api/webhook/unique_webhook_id
```

The script will send RGB color data to this webhook, which Home Assistant will then apply to your light.

## Multi-Color Extraction and Alternation

This script supports extracting multiple dominant colors from artwork and alternating between them for more dynamic lighting effects:

### How It Works

1. The script extracts multiple colors (default: 3) from each artwork in order of vibrancy/saturation
2. With each update, it alternates between these colors, creating a rhythmic effect
3. The sequence repeats with each new track's artwork

### Configuring Multi-Color

You can adjust the number of colors extracted by modifying these variables at the top of the script:
```bash
NUM_COLORS=3  # Number of colors to extract
COLOR_INDEX=0  # Track which color to use (don't change this)
```

### Yeelight Music Mode

For Yeelight bulbs, the webhook is configured to disable music mode when it's active, as this can provide more reliable control in some environments. If you want to use music mode instead:

1. Modify the webhook configuration to set `music_mode: true` instead of `false`
2. Adjust the condition template as needed for your setup

The script sends dynamic transition times based on the BPM of the current track, creating smoother, rhythm-matched color transitions.

### Excluding Media Players

The script automatically excludes certain media players to prevent unwanted color changes:
- Video players (haruna, vlc, mpv, celluloid, totem)
- KDE Connect duplicates
- Other media players can be added to the exclusion list in the script

## Remote API Access

You can also trigger your RGB light control remotely through your Home Assistant instance. This allows external applications or services to control your RGB lights.

### Setting Up Remote Access

1. Make sure your Home Assistant instance is accessible remotely (e.g., through a domain like `https://home.example.org`)
2. Set up proper authentication for your Home Assistant instance
3. Use the following URL format to call your webhook:

```
https://home.example.org/api/webhook/unique_webhook_id
```

### Example API Calls

To change your RGB light colors remotely, send a POST request to the webhook URL:

```bash
# Basic color change
curl -X POST \
  https://home.example.org/api/webhook/unique_webhook_id \
  -H 'Content-Type: application/json' \
  -d '{"rgb": [255, 0, 0]}'

# With custom transition time (2.5 seconds)
curl -X POST \
  https://home.example.org/api/webhook/unique_webhook_id \
  -H 'Content-Type: application/json' \
  -d '{"rgb": [255, 0, 0], "transition": 2.5}'
```

Python example:
```python
import requests

url = "https://home.example.org/api/webhook/unique_webhook_id"
payload = {
    "rgb": [255, 0, 0],  # Red color
    "transition": 2.0  # 2 second transition
}

response = requests.post(url, json=payload)
print(response.status_code)
```

### Authentication Notes

- Webhook endpoints do not require authentication tokens
- For security, consider enabling the `local_only: true` option in your webhook configuration if you don't need remote access
- For further protection, use a long and complex webhook ID
- Consider using HTTPS and proper network security measures

## Troubleshooting

If you encounter issues:
1. Check the logs for error messages
2. Ensure your media player is compatible with MPRIS
3. Verify your Home Assistant configuration is correct
4. Check that the webhook ID in the script matches your Home Assistant automation

## Spotify Local Files Support

This service has special support for Spotify local files. When you play local files through Spotify:

1. The service uses the track metadata to find matching MP3 files in your `MUSIC_DIR`
2. It extracts album artwork directly from your local files
3. The RGB colors are then generated from this artwork and sent to Home Assistant

For this to work correctly:
- Ensure your `MUSIC_DIR` in the `.env` file points to your music collection
- Local files must be in MP3 format with embedded album artwork
- File naming should reasonably match the track metadata from Spotify
