#!/usr/bin/env python3
"""Original procedural music for YingShu, released under CC0 1.0."""
import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Resources"
ROOT.mkdir(exist_ok=True)
RATE = 32000

def compose(name, root, beat, warm=False):
    length = beat * 64
    data = [0.0] * int(length * RATE)
    chords = [(0, 4, 7), (-3, 0, 4), (-5, -1, 2), (-7, -3, 0)]
    rng = random.Random(24 if warm else 17)
    def add_note(start, midi, duration, strength, pad=False):
        frequency = 440 * 2 ** ((midi - 69) / 12)
        first = int(start * RATE)
        count = min(int(duration * RATE), len(data) - first)
        for i in range(count):
            t = i / RATE
            attack = min(1.0, t / (0.3 if pad else 0.014))
            release = min(1.0, (duration - t) / 0.25)
            envelope = attack * release * math.exp(-t / (3.0 if pad else 0.8))
            sound = math.sin(2 * math.pi * frequency * t)
            sound += 0.23 * math.sin(2 * math.pi * frequency * 2.003 * t) * math.exp(-t * 2)
            sound += 0.075 * math.sin(2 * math.pi * frequency * 3.005 * t) * math.exp(-t * 3)
            data[first + i] += sound * envelope * strength
    for bar in range(16):
        chord = chords[(bar // 2) % len(chords)]
        for tick in range(4):
            note = root + chord[[0, 1, 2, 1][tick]] + (12 if tick % 2 else 0)
            add_note((bar * 4 + tick) * beat, note, beat * 3.4, 0.14 + rng.random() * 0.025)
        for note in chord:
            add_note(bar * 4 * beat, root - 12 + note, beat * 4.5, 0.032, pad=True)
    # Overall fades avoid clicks and make repeated previews gentle.
    peak = max(max(data), -min(data), 0.01)
    pcm = bytearray()
    for i, sample in enumerate(data):
        fade = min(1, i / (RATE * 1.2), (len(data) - i) / (RATE * 2.8))
        pcm.extend(struct.pack("<h", int(max(-1, min(1, sample / peak * 0.68 * fade)) * 32767)))
    with wave.open(str(ROOT / name), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(pcm)

if __name__ == "__main__":
    compose("breeze.wav", 62, 0.68)
    compose("afternoon.wav", 60, 0.86, warm=True)
    print("Generated original CC0 music: breeze.wav, afternoon.wav")
