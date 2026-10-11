"""Minimal Volcengine Doubao speech 2.0 client (seed-audio-1.0 audio generation).
Reads secrets/volc.env; never prints the key.
Doc: https://docs.volcengine.com/docs/DoubaoVoice/audio-generation-http?lang=zh"""
from __future__ import annotations

import base64
import json
import socket
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ENV = REPO / "secrets" / "volc.env"
URL = "https://openspeech.bytedance.com/api/v3/tts/create"
MODEL = "seed-audio-1.0"
REF_MAX_BYTES = 10 * 1024 * 1024  # per reference clip; the clip must also be <= 30 s


class VolcError(Exception):
    pass


def _cfg() -> dict[str, str]:
    if not ENV.exists():
        return {}
    kv = {}
    for line in ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv


def _key() -> str:
    key = _cfg().get("VOLC_API_KEY", "")
    if not key or not key.isascii():  # empty, or still the template's placeholder
        raise VolcError(f"no API key: copy secrets/volc.env.example to {ENV.name} and fill VOLC_API_KEY")
    return key


def default_speaker() -> str | None:
    return _cfg().get("VOLC_SPEAKER_ID") or None


def body(text_prompt: str, *, ref: Path | None = None, speaker: str | None = None,
         fmt: str = "mp3", sample_rate: int = 44100, speech_rate: int = 0) -> dict:
    """ref: a reference clip whose voice is cloned on the fly (refer to it as
    @音频1 in the prompt); speaker: a registered clone or a 2.0 voice id."""
    if ref is not None and speaker is not None:
        raise ValueError("ref and speaker are exclusive")
    b: dict = {"model": MODEL, "text_prompt": text_prompt,
               "audio_config": {"format": fmt, "sample_rate": sample_rate, "speech_rate": speech_rate}}
    if ref is not None:
        data = Path(ref).read_bytes()
        if len(data) > REF_MAX_BYTES:
            raise ValueError(f"{Path(ref).name} is {len(data)} bytes, the limit is {REF_MAX_BYTES}")
        b["references"] = [{"audio_data": base64.b64encode(data).decode("ascii")}]
    elif speaker is not None:
        b["references"] = [{"speaker": speaker}]
    return b


TTS_URL = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
TTS_RATE = 24000
TTS_DONE = 20000000  # the stream's last line on success


def tts(text: str, speaker: str, out: Path, *, instruction: str | None = None, speech_rate: int = 0,
        resource: str = "seed-tts-2.0", timeout: float = 120) -> Path:
    """One line with a preset 2.0 voice (seed-tts-2.0) or a registered clone
    (seed-icl-2.0), written as 16-bit mono WAV. instruction: a voice direction
    such as 用撒娇的语气说 (2.0 preset voices only; not billed).
    The stream is asked for PCM -- the doc warns chunked WAV carries a header
    per chunk -- and wrapped in one WAV header here."""
    import wave
    params: dict = {"text": text, "speaker": speaker, "audio_params": {"format": "pcm", "sample_rate": TTS_RATE}}
    if speech_rate:
        params["audio_params"]["speech_rate"] = speech_rate
    if instruction:
        params["additions"] = json.dumps({"context_texts": [instruction]}, ensure_ascii=False)
    req = urllib.request.Request(TTS_URL, method="POST", data=json.dumps({"req_params": params}).encode("utf-8"))
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Api-Key", _key())
    req.add_header("X-Api-Resource-Id", resource)
    req.add_header("X-Api-Request-Id", str(uuid.uuid4()))
    pcm, last = bytearray(), {}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for line in r.read().decode("utf-8").splitlines():
                if not line.strip():
                    continue
                last = json.loads(line)
                if last.get("code") not in (0, TTS_DONE):
                    break
                if last.get("data"):
                    pcm += base64.b64decode(last["data"])
    except urllib.error.HTTPError as e:
        text_ = e.read().decode("utf-8", "replace")
        try:
            last = json.loads(text_ or "{}")
        except ValueError:
            last = {"code": e.code, "message": text_[:200]}
    except urllib.error.URLError as e:
        raise VolcError(f"network error: {e.reason}")
    except socket.timeout as e:
        raise VolcError(f"request timeout: {e}")
    if last.get("code") != TTS_DONE or not pcm:
        raise VolcError(f"tts failed: code={last.get('code')} {last.get('message')}")
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TTS_RATE)
        w.writeframes(bytes(pcm))
    return out


def generate(req_body: dict, out: Path, timeout: float = 300) -> dict:
    """POST one generation; writes the decoded audio to out and returns the
    response without the audio (duration, original_duration -- the billed one)."""
    req = urllib.request.Request(URL, method="POST", data=json.dumps(req_body).encode("utf-8"))
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Api-Key", _key())
    req.add_header("X-Api-Request-Id", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            res = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        try:
            res = json.loads(text or "{}")
        except ValueError:
            res = {"code": e.code, "message": text[:200]}
    except urllib.error.URLError as e:
        raise VolcError(f"network error: {e.reason}")
    except socket.timeout as e:
        raise VolcError(f"request timeout: {e}")
    if not res.get("audio"):
        raise VolcError(f"generate failed: code={res.get('code')} {res.get('message')}")
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(res.pop("audio")))
    return res
