# MPRIS RGB Home Assistant

A service that connects your media players to Home Assistant RGB devices. This utility uses the MPRIS interface to detect media playback status and syncs it with your Home Assistant-controlled RGB lights.

## Prerequisites

- Linux system with systemd
- Home Assistant setup with RGB devices
- Media players that support MPRIS

## Installation

1. Clone this repository or download the script files to your home directory

2. Make the script executable:
```bash
chmod +x ~/scripts/mpris_rgb_homeassistant.sh
```

3. Install the systemd service:
```bash
cp ~/scripts/mpris-rgb-homeassistant.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

4. Enable and start the service:
```bash
systemctl --user enable mpris-rgb-homeassistant.service
systemctl --user start mpris-rgb-homeassistant.service
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

## Troubleshooting

If you encounter issues:
1. Check the logs for error messages
2. Ensure your media player is compatible with MPRIS
3. Verify your Home Assistant configuration is correct
4. Check that the webhook ID in the script matches your Home Assistant automation

## Development

For developers looking to modify the script, the main functionality is in `mpris_rgb_homeassistant.sh`. ZZ
