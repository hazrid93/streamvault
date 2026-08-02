#!/bin/sh
set -eu

MODEL_NAME="${WHISPER_MODEL:-base-q5_1}"
MODEL_PATH="/models/ggml-${MODEL_NAME}.bin"
VAD_PATH="/models/ggml-silero-v6.2.0.bin"

[ -r "$MODEL_PATH" ] || { echo "Missing local Whisper model: $MODEL_PATH" >&2; exit 1; }
[ -r "$VAD_PATH" ] || { echo "Missing local Whisper VAD model: $VAD_PATH" >&2; exit 1; }

THREADS="${WHISPER_THREADS:-4}"
export OMP_NUM_THREADS="$THREADS"

# Low scheduling priority, low cgroup shares, and explicit thread limits make
# caption generation yield CPU to FFmpeg whenever playback is transcoding.
exec nice -n 12 /opt/whisper/whisper-server \
  --model "$MODEL_PATH" \
  --host 0.0.0.0 \
  --port 8080 \
  --threads "$THREADS" \
  --processors 1 \
  --language auto \
  --translate \
  --suppress-nst \
  --vad \
  --vad-model "$VAD_PATH" \
  --no-gpu