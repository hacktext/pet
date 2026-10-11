import base64
import io
import json
import urllib.error

import pytest

from petgen import volc


@pytest.fixture(autouse=True)
def mock_key(monkeypatch):
    """All tests use a fake API key to avoid reading secrets."""
    monkeypatch.setattr(volc, "_cfg", lambda: {"VOLC_API_KEY": "test-key"})


class TestBody:
    def test_text_only(self):
        b = volc.body("你好呀")
        assert b["model"] == "seed-audio-1.0"
        assert b["text_prompt"] == "你好呀"
        assert "references" not in b
        assert b["audio_config"] == {"format": "mp3", "sample_rate": 44100, "speech_rate": 0}

    def test_reference_audio_is_inlined_base64(self, tmp_path):
        ref = tmp_path / "me.wav"
        ref.write_bytes(b"RIFFfake")
        b = volc.body("@音频1 温柔地说：你回来啦", ref=ref)
        assert b["references"] == [{"audio_data": base64.b64encode(b"RIFFfake").decode("ascii")}]

    def test_speaker_id(self):
        assert volc.body("嗨", speaker="S_abc")["references"] == [{"speaker": "S_abc"}]

    def test_ref_and_speaker_are_exclusive(self, tmp_path):
        ref = tmp_path / "me.wav"
        ref.write_bytes(b"x")
        with pytest.raises(ValueError):
            volc.body("嗨", ref=ref, speaker="S_abc")

    def test_long_reference_rejected_before_sending(self, tmp_path):
        ref = tmp_path / "big.wav"
        ref.write_bytes(b"x" * (10 * 1024 * 1024 + 1))
        with pytest.raises(ValueError):
            volc.body("嗨", ref=ref)


class TestGenerate:
    def test_writes_decoded_audio(self, monkeypatch, tmp_path):
        sent = {}

        def fake_urlopen(req, timeout):
            sent["headers"] = dict(req.header_items())
            sent["url"] = req.full_url
            payload = {"audio": base64.b64encode(b"MP3DATA").decode(), "duration": 1.5, "original_duration": 1.5}
            return io.BytesIO(json.dumps(payload).encode())

        monkeypatch.setattr(volc.urllib.request, "urlopen", fake_urlopen)
        out = tmp_path / "a.mp3"
        r = volc.generate(volc.body("嗨"), out)
        assert out.read_bytes() == b"MP3DATA"
        assert r["original_duration"] == 1.5
        assert sent["url"] == "https://openspeech.bytedance.com/api/v3/tts/create"
        assert sent["headers"]["X-api-key"] == "test-key"
        assert "X-api-request-id" in sent["headers"]

    def test_error_body_raises_with_code(self, monkeypatch, tmp_path):
        def fake_urlopen(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {},
                                         io.BytesIO(b'{"code": 45000010, "message": "invalid api key"}'))

        monkeypatch.setattr(volc.urllib.request, "urlopen", fake_urlopen)
        with pytest.raises(volc.VolcError, match="45000010.*invalid api key"):
            volc.generate(volc.body("嗨"), tmp_path / "a.mp3")
        assert not (tmp_path / "a.mp3").exists()

    def test_missing_key_is_a_clear_error(self, monkeypatch):
        monkeypatch.setattr(volc, "_cfg", lambda: {"VOLC_API_KEY": "在这里填完整的 API Key"})
        with pytest.raises(volc.VolcError, match="volc.env"):
            volc._key()


class TestTts:
    def _stream(self, *lines):
        return io.BytesIO("".join(json.dumps(l) + "\n" for l in lines).encode())

    def test_joins_the_streamed_chunks(self, monkeypatch, tmp_path):
        sent = {}

        def fake_urlopen(req, timeout):
            sent["headers"] = dict(req.header_items())
            sent["body"] = json.loads(req.data)
            sent["url"] = req.full_url
            return self._stream({"code": 0, "data": base64.b64encode(b"AB").decode()},
                                {"code": 0, "data": base64.b64encode(b"CD").decode()},
                                {"code": 0, "data": None},
                                {"code": 20000000, "message": "OK", "data": None})

        monkeypatch.setattr(volc.urllib.request, "urlopen", fake_urlopen)
        out = tmp_path / "v.wav"
        volc.tts("你好", "zh_female_vv_uranus_bigtts", out, instruction="用撒娇的语气说")
        import wave
        with wave.open(str(out)) as w:
            assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 24000)
            assert w.readframes(w.getnframes()) == b"ABCD"
        assert sent["url"] == "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
        assert sent["headers"]["X-api-resource-id"] == "seed-tts-2.0"
        p = sent["body"]["req_params"]
        assert p["text"] == "你好" and p["speaker"] == "zh_female_vv_uranus_bigtts"
        assert p["audio_params"] == {"format": "pcm", "sample_rate": 24000}
        assert json.loads(p["additions"]) == {"context_texts": ["用撒娇的语气说"]}

    def test_error_in_stream_raises_and_writes_nothing(self, monkeypatch, tmp_path):
        monkeypatch.setattr(volc.urllib.request, "urlopen",
                            lambda req, timeout: self._stream({"code": 45000030, "message": "not granted"}))
        with pytest.raises(volc.VolcError, match="45000030"):
            volc.tts("你好", "x", tmp_path / "v.wav")
        assert not (tmp_path / "v.wav").exists()
