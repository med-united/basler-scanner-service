# Basler Scanner Service

A single-file HTTP service (`scanner.py`) that exposes a Basler daA3840-45uc USB
camera as a document scanner. A web application fetches images from it via
plain HTTP GET requests.

## Endpoints

| Path           | Returns                                                  |
| -------------- | -------------------------------------------------------- |
| `/preview.jpg` | One downscaled preview frame (poll it for a live view)   |
| `/capture`     | One full-resolution JPEG (quality 97)                    |

`example.html` is a self-contained demo page showing the polling preview and
capture flow (it expects the service on port 8000).

## Requirements

- **Basler pylon Software Suite** (<https://www.baslerweb.com/pylon>) — provides
  the USB camera driver and the pylon Viewer.
- **uv** (<https://docs.astral.sh/uv/>) — runs the script; all Python
  dependencies are declared inside `scanner.py` and installed automatically on
  first run.

## Camera configuration

The service sets **no** camera features — configure the camera yourself and
store the settings in the camera:

1. Configure the camera in pylon Viewer (ROI, exposure, gain, frame rate,
   sharpness, …).
2. User Set Control → select `UserSet1` → execute **User Set Save**.
3. Set **User Set Default** to `UserSet1` so the camera boots with these
   settings.

Close pylon Viewer before starting the service — only one process can open the
camera at a time.

## Running

```
uv run scanner.py <port>
```

The port argument is required. The service listens on `127.0.0.1` only, i.e.
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

## Autostart on Windows

Use Task Scheduler to start the service when the user logs in:

1. Open **Task Scheduler** → **Create Task…**.
2. **General:** name it e.g. `Basler Scanner`; keep **Run only when user is
   logged on**.
3. **Triggers:** New → **At log on** (optionally limited to the specific user).
4. **Actions:** New → Start a program:
   - Program: full path to `uv.exe`
     (typically `C:\Users\<user>\.local\bin\uv.exe`)
   - Arguments: `run scanner.py <port>`
   - Start in: the full path of this folder.
5. **Settings:** enable **If the task fails, restart every** 1 minute so the
   service recovers if it starts before the camera is ready.

Notes:

- Run `uv run scanner.py <port>` once manually in this folder first, so the
  Python environment is downloaded and cached for that user account.
- The service runs in a console window; closing that window stops the
  scanner (the restart-on-failure setting will bring it back).
- To check it is running: open `http://127.0.0.1:<port>/preview.jpg` in a
  browser on the machine.
