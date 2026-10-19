#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for binary in ffmpeg ffprobe swiftc python3; do
  command -v "$binary" >/dev/null || { printf 'Missing verification dependency: %s\n' "$binary"; exit 1; }
done
mkdir -p /tmp/yingshu-media-smoke
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=640x360:rate=30' \
  -f lavfi -i 'sine=frequency=880:sample_rate=44100' \
  -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac /tmp/yingshu-media-smoke/source.mp4
ffmpeg -hide_banner -loglevel error -y -display_rotation:v:0 90 -i /tmp/yingshu-media-smoke/source.mp4 \
  -map 0 -c copy /tmp/yingshu-media-smoke/rotated.mp4
ffmpeg -hide_banner -loglevel error -y -i /tmp/yingshu-media-smoke/source.mp4 \
  -an -frames:v 2 -c:v libx264 /tmp/yingshu-media-smoke/short.mp4
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=1' \
  -f lavfi -i 'sine=frequency=880:sample_rate=44100:duration=3' \
  -c:v libx264 -pix_fmt yuv420p -c:a aac /tmp/yingshu-media-smoke/audio-tail.mp4
ffmpeg -hide_banner -loglevel error -y -itsoffset 0.2041 -i /tmp/yingshu-media-smoke/source.mp4 \
  -an -c copy /tmp/yingshu-media-smoke/delayed.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=220:sample_rate=44100:duration=0.4' \
  /tmp/yingshu-media-smoke/short-music.wav
# Real codec/container fixtures; HDR10 carries 10-bit PQ/BT.2020 signalling.
ffmpeg -hide_banner -loglevel error -y -i /tmp/yingshu-media-smoke/source.mp4 -t 1 -an \
  -c:v libx265 -x265-params 'log-level=error:pools=1:frame-threads=1' -tag:v hvc1 /tmp/yingshu-media-smoke/hevc-sdr.mov
ffmpeg -hide_banner -loglevel error -y -i /tmp/yingshu-media-smoke/hevc-sdr.mov -c copy /tmp/yingshu-media-smoke/hevc-sdr.mp4
ffmpeg -hide_banner -loglevel error -y -i /tmp/yingshu-media-smoke/source.mp4 -t 1 -c copy /tmp/yingshu-media-smoke/h264.mov
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=1' \
  -pix_fmt yuv420p10le -c:v libx265 -tag:v hvc1 \
  -x265-params 'log-level=error:pools=1:frame-threads=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400' \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc /tmp/yingshu-media-smoke/hdr10.mov
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=120:duration=1' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p /tmp/yingshu-media-smoke/highfps120.mov
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=240:duration=1' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p /tmp/yingshu-media-smoke/highfps240.mp4
python3 - <<'PY_DNG'
import struct
from pathlib import Path
w,h=512,384
# Synthetic, uncompressed Bayer DNG. It carries real DNG TIFF/CFA tags and 16-bit sensor samples.
entries=[]
def tag(n,t,count,value): entries.append((n,t,count,value))
def shorts(*items): return struct.pack('<'+'H'*len(items),*items)
def longs(*items): return struct.pack('<'+'I'*len(items),*items)
def rational(*items): return b''.join(struct.pack('<II',n,d) for n,d in items)
def srational(*items): return b''.join(struct.pack('<ii',n,d) for n,d in items)
tag(254,4,1,longs(0));tag(256,4,1,longs(w));tag(257,4,1,longs(h));tag(258,3,1,shorts(16))
tag(259,3,1,shorts(1));tag(262,3,1,shorts(32803));tag(273,4,1,longs(0));tag(274,3,1,shorts(1))
tag(277,3,1,shorts(1));tag(278,4,1,longs(h));tag(279,4,1,longs(w*h*2));tag(284,3,1,shorts(1))
tag(50706,1,4,bytes([1,4,0,0]));tag(50707,1,4,bytes([1,1,0,0]))
model=b'YingShu Synthetic Bayer DNG\0';tag(50708,2,len(model),model)
tag(50714,5,1,rational((0,1)));tag(50717,4,1,longs(65535))
tag(50721,10,9,srational(*[(1 if i%4==0 else 0,1) for i in range(9)]))
tag(50728,5,3,rational((1,1),(1,1),(1,1)));tag(50778,3,1,shorts(21))
tag(271,2,8,b'YingShu\0');tag(272,2,14,b'Synthetic DNG\0')
tag(339,3,1,shorts(1))
tag(50718,5,2,rational((1,1),(1,1)));tag(50719,4,2,longs(0,0));tag(50720,4,2,longs(w,h));tag(50829,4,4,longs(0,0,h,w))
tag(33421,3,2,shorts(2,2));tag(33422,1,4,bytes([0,1,1,2]));tag(50710,1,3,bytes([0,1,2]));tag(50711,3,1,shorts(1));tag(50713,3,2,shorts(1,1))
entries.sort();offset=8+2+12*len(entries)+4;extra=bytearray();ifd=[]
for n,t,count,data in entries:
    if n==273: pass
    if len(data)>4:
        ifd.append([n,t,count,struct.pack('<I',offset+len(extra))]);extra.extend(data)
        if len(extra)%2:extra.append(0)
    else:ifd.append([n,t,count,data.ljust(4,b'\0')])
pixeloffset=offset+len(extra)
for item in ifd:
    if item[0]==273:item[3]=struct.pack('<I',pixeloffset)
header=b'II'+struct.pack('<HI',42,8)+struct.pack('<H',len(ifd))
header+=b''.join(struct.pack('<HHI',n,t,c)+v for n,t,c,v in ifd)+struct.pack('<I',0)+extra
pixels=b''.join(struct.pack('<H',int(x/(w-1)*55000) if (y%2,x%2)==(0,0) else (15000 if (y%2,x%2)==(1,1) else int(y/(h-1)*55000))) for y in range(h) for x in range(w))
Path('/tmp/yingshu-media-smoke/synthetic-bayer.dng').write_bytes(header+pixels)
PY_DNG
swiftc -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift Sources/YingShu/CompanionStickerRenderer.swift Sources/YingShu/MediaEngine.swift \
  scripts/media_smoke.swift -o /tmp/yingshu-media-smoke/smoke
/tmp/yingshu-media-smoke/smoke
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -show_entries format=duration \
  -of json /tmp/yingshu-media-smoke/result.mp4
audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 /tmp/yingshu-media-smoke/silent-portrait.mp4)
if [[ -n "$audio_streams" ]]; then
  printf '%s\n' 'FAIL: source audio leaked into silent export'
  exit 1
fi
printf '%s\n' 'PASS: no source audio in silent export'

ffmpeg -hide_banner -loglevel error -y -ss 1.4 -t 0.2 -i /tmp/yingshu-media-smoke/result.mp4 \
  -vn -ac 1 -c:a pcm_s16le /tmp/yingshu-media-smoke/mix-check.wav
python3 - <<'PY_AUDIO'
import cmath
import math
import struct
import wave
with wave.open('/tmp/yingshu-media-smoke/mix-check.wav', 'rb') as source:
    rate = source.getframerate()
    raw = source.readframes(source.getnframes())
samples = [value / 32768 for value in struct.unpack('<' + 'h' * (len(raw) // 2), raw)]
def amplitude(hz):
    return abs(sum(value * cmath.exp(-2j * math.pi * hz * index / rate) for index, value in enumerate(samples))) / len(samples)
music, original = amplitude(220), amplitude(880)
assert music > 0.005 and original < 0.002 and music > 20 * original, (music, original)
print(f'PASS: looped 220 Hz music present ({music:.5f}); original 880 Hz source excluded ({original:.5f})')
PY_AUDIO

ffprobe -v error -select_streams v -show_entries stream=codec_name,pix_fmt,color_space,color_primaries,color_transfer,r_frame_rate \
  -of json /tmp/yingshu-media-smoke/phone-formats.mp4
