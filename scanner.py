# /// script
# requires-python = "==3.13.*"
# dependencies = [
#     "pypylon",
#     "fastapi",
#     "uvicorn",
#     "opencv-python-headless",
#     "img2pdf",
#     "pikepdf",
# ]
# ///
import io
import os
import threading
from contextlib import asynccontextmanager

import cv2
import img2pdf
import pikepdf
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from pypylon import pylon

DEFAULT_PORT = 41234

_lock = threading.Lock()
_frame = None  # latest full-resolution BGR frame

# sRGB ICC profile needed for PDF/A output (Windows, macOS, Linux)
_ICC_PROFILE = next(
    (p for p in [
        r"C:\Windows\System32\spool\drivers\color\sRGB Color Space Profile.icm",
        "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
        "/usr/share/color/icc/sRGB.icc",
    ] if os.path.exists(p)),
    None,
)


def _grab_loop(cam: pylon.InstantCamera, conv: pylon.ImageFormatConverter) -> None:
    global _frame
    while cam.IsGrabbing():
        result = cam.RetrieveResult(5000, pylon.TimeoutHandling_Return)
        if result is None:
            continue
        try:
            if result.GrabSucceeded():
                img = conv.Convert(result).GetArray()
                with _lock:
                    _frame = img
        finally:
            result.Release()


@asynccontextmanager
async def lifespan(_: FastAPI):
    cam = pylon.InstantCamera(pylon.TlFactory.GetInstance().CreateFirstDevice())
    cam.Open()
    conv = pylon.ImageFormatConverter()
    conv.OutputPixelFormat = pylon.PixelType_BGR8packed
    cam.StartGrabbing(pylon.GrabStrategy_LatestImageOnly)
    threading.Thread(target=_grab_loop, args=(cam, conv), daemon=True).start()
    try:
        yield
    finally:
        cam.StopGrabbing()
        cam.Close()


app = FastAPI(lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET"])


@app.get("/capture")
def capture() -> Response:
    with _lock:
        frame = None if _frame is None else _frame.copy()
    if frame is None:
        raise HTTPException(503, "No frame from camera")
    ok, jpg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 97])
    if not ok:
        raise HTTPException(500, "JPEG encoding failed")
    return Response(jpg.tobytes(), media_type="image/jpeg")


@app.get("/capture.pdf")
def capture_pdf() -> Response:
    with _lock:
        frame = None if _frame is None else _frame.copy()
    if frame is None:
        raise HTTPException(503, "No frame from camera")
    if _ICC_PROFILE is None:
        raise HTTPException(500, "No sRGB ICC profile found on this system")
    ok, jpg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 97])
    if not ok:
        raise HTTPException(500, "JPEG encoding failed")
    # img2pdf builds the PDF/A structure (OutputIntent, XMP, ID) but only knows
    # PDF/A-1b; the ePA Aktensystem wants PDF/A-2, which is a superset of A-1,
    # so upgrade the conformance claim and PDF version via pikepdf.
    a1b = img2pdf.convert(jpg.tobytes(), pdfa=_ICC_PROFILE)
    with pikepdf.open(io.BytesIO(a1b)) as pdf:
        with pdf.open_metadata(update_docinfo=False, set_pikepdf_as_editor=False) as meta:
            meta["pdfaid:part"] = "2"
            meta["pdfaid:conformance"] = "B"
        out = io.BytesIO()
        pdf.save(out, force_version="1.7")
    return Response(out.getvalue(), media_type="application/pdf")


@app.get("/preview.jpg")
def preview() -> Response:
    with _lock:
        frame = None if _frame is None else _frame.copy()
    if frame is None:
        raise HTTPException(503, "No frame from camera")
    h, w = frame.shape[:2]
    small = cv2.resize(frame, (960, h * 960 // w))
    ok, jpg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 70])
    if not ok:
        raise HTTPException(500, "JPEG encoding failed")
    return Response(jpg.tobytes(), media_type="image/jpeg")


if __name__ == "__main__":
    import sys

    import uvicorn

    if len(sys.argv) > 2:
        sys.exit(f"usage: uv run scanner.py [port]  (default {DEFAULT_PORT})")
    port = int(sys.argv[1]) if len(sys.argv) == 2 else DEFAULT_PORT
    uvicorn.run(app, host="127.0.0.1", port=port, access_log=False)
