# Roadmap

This is the one live backlog. Everything shipped is in the [changelog](../CHANGELOG.md), and past plans are in the [archive](archive/).

The app is at 0.4.0. Nothing is being built right now. The items below are deferred, each for a stated reason.

## Plugs

Paused on 2026-10-02 because the plugs were not working. Resume when they are.

Three smart plugs on the Home network, paired in the Lifelong Smart app (a branded Tuya app), should get a Plugs card under Lights on the Home tab. They speak Tuya protocol 3.4, which signs every local command with the plug's own 16-character local key, so the keys are needed once, whatever the route. Reading them from the phone failed because the phone is not rooted. A developer account is ruled out.

The route to build:

1. Log in by QR code with the Smart Life app, using Tuya's `tuya-device-sharing-sdk`, the same library Home Assistant uses. Each plug first has to be moved into Smart Life (hold its button about 5 seconds until it blinks, then add it). After one scan Switchboard talks to the plugs on the local network only.
2. A "Connect plugs" button on the Home tab shows the QR code in the panel. The keys land in Switchboard's state folder with mode 0600.
3. Control uses `tinytuya` from a private Python environment under `~/Library/Application Support/Switchboard/`, through a `plugs.py` helper that mirrors `wiz.py`.

Flashing local firmware (Cloudcutter to OpenBeken) was considered and left out, since it is model specific and can brick a plug.

## Other deferred items

- Codex warn and danger thresholds. Deferred by the owner. Do not raise it again.
- The m5air2 screenshot hang. Deferred until that Mac is available. Ask the owner then.
- Disk and cleanup tools belong in sys-monitor, not here.
