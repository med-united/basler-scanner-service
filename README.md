# Basler Scanner Service

A single-file HTTP service (`scanner.py`) that exposes a Basler daA3840-45uc USB
camera as a document scanner.

## Endpoints

| Path           | Returns                                                  |
| -------------- | -------------------------------------------------------- |
| `/preview.jpg` | One downscaled preview frame (poll it for a live view)   |
| `/capture`     | One full-resolution JPEG                                 |
| `/capture.pdf` | The same full-resolution capture wrapped as PDF/A-2b     |

Use `/capture.pdf` when the image is uploaded to the ePA, which requires
PDF/A-2b for `application/pdf` documents. The PDF embeds the JPEG unchanged, so
it is the same picture `/capture` returns. It needs an sRGB ICC profile on the
machine.

## Requirements

- **Basler pylon Software Suite** (<https://www.baslerweb.com/pylon>): Provides
  the USB camera driver and the pylon Viewer.
- **uv** (<https://docs.astral.sh/uv/>): Runs the script. Python 3.13 and all
  Python dependencies are declared inside `scanner.py` and downloaded
  automatically on first run.

## Camera configuration

The service sets **no** camera features. You need to configure the camera
yourself and store the settings in the camera:

1. Configure the camera in pylon Viewer (ROI, exposure, gain, frame rate,
   sharpness, …).
2. User Set Control → select `UserSet1` → execute **User Set Save**.
3. Set **User Set Default** to `UserSet1` so the camera boots with these
   settings.

Only one process can open the camera at a time, so the service and pylon Viewer
can never run together. Once installed the service holds the camera
permanently, and pylon Viewer will fail to open it. Release it for the duration
of the configuration:

```powershell
Stop-ScheduledTask -TaskName "Basler Scanner"    # release the camera
# configure in pylon Viewer, then User Set Save, then close pylon Viewer
Start-ScheduledTask -TaskName "Basler Scanner"   # hand it back to the service
```

The task restarts on failure, not after a deliberate stop, so the camera stays
free until you start it again.

## Running

```
uv run scanner.py [port]
```

The port defaults to 41234. The service listens on `127.0.0.1` only, i.e.
it is reachable solely from the machine it runs on — by design, see below.

## Use from a web application

The intended setup: the webapp is served from a (remote) server, but its
JavaScript runs in the browser **on this machine**, so
`fetch("http://127.0.0.1:<port>/capture")` stays local. The service does not
need to be exposed to the network.

**CORS** is already handled: the service answers every request with
`Access-Control-Allow-Origin: *` (GET only), so a page from any origin may
read the responses. Two browser-level caveats remain:

- **Mixed content:** loopback addresses (`127.0.0.1`, `localhost`) are treated
  as trustworthy, so an HTTPS webapp is allowed to fetch from
  `http://127.0.0.1` — this specific case is exempt from mixed-content
  blocking. Use `http://127.0.0.1:<port>`, not the machine's LAN IP or
  hostname (those would be blocked from an HTTPS page).
- **Local network access:** recent Chromium versions gate requests from public
  websites to local/loopback addresses behind a one-time permission prompt
  ("allow this site to access devices on your local network"). On managed
  clients, suppress the prompt by deploying the Chrome enterprise policy
  [`LocalNetworkAccessAllowedForUrls`](https://chromeenterprise.google/policies/local-network-access-allowed-for-urls/)
  (via Group Policy/Intune) containing the **webapp's origin** — the site
  making the request, not the localhost address. Without the policy, each user
  must accept the prompt once per origin; the grant persists.

## Installation on Windows

Install the pylon Software Suite first, then run this in PowerShell as the user
who will operate the scanner:

```powershell
irm https://raw.githubusercontent.com/med-united/basler-scanner-service/main/install.ps1 | iex
```

`install.ps1` installs uv, downloads `scanner.py` into
`%LOCALAPPDATA%\basler-scanner-service`, creates its Python environment and
registers a scheduled task named **Basler Scanner** that starts the service on
port 41234 at every logon, without a console window. It ends by checking that
`http://127.0.0.1:41234/preview.jpg` answers.

Afterwards the service is managed through its task:

```powershell
Stop-ScheduledTask  -TaskName "Basler Scanner"   # release the camera
Start-ScheduledTask -TaskName "Basler Scanner"
Unregister-ScheduledTask -TaskName "Basler Scanner"
```

There is no window and no tray icon, so check the preview URL or the task's
**Last Run Result** in Task Scheduler to see whether it is alive. To see the log
output, stop the task and run the service by hand as described under *Running*.
