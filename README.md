# MPRIS RGB Home Assistant

A service that connects your media players to Home Assistant RGB devices. This utility uses the MPRIS interface to detect media playback status and syncs it with your Home Assistant-controlled RGB lights.

## Prerequisites

- Linux system with systemd
- Home Assistant setup with RGB devices
- Media players that support MPRIS

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
description: Update Light Webhook
triggers:
  - trigger: webhook
    allowed_methods:
      - POST
      - PUT
    local_only: false
    webhook_id: "unique_webhook_id"  # Generate a unique ID or string
conditions: []
actions:
  - action: light.turn_on
    metadata: {}
    data:
      transition: 1
      rgb_color: "{{trigger.json.rgb}}"
    target:
      entity_id: light.your_rgb_light  # Replace with your light entity
mode: single
```

4. Save the automation

Once set up, the webhook URL will be:
```
http://your-home-assistant:8123/api/webhook/unique_webhook_id
```

The script will send RGB color data to this webhook, which Home Assistant will then apply to your light.

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
curl -X POST \
  https://home.example.org/api/webhook/unique_webhook_id \
  -H 'Content-Type: application/json' \
  -d '{"rgb": [255, 0, 0]}'
```

Python example:
```python
import requests

url = "https://home.example.org/api/webhook/unique_webhook_id"
payload = {"rgb": [255, 0, 0]}  # Red color

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
