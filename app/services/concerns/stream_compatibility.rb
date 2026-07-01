# frozen_string_literal: true

module StreamCompatibility
  # Release title patterns for detecting video codec, audio codec, and container.
  # These match common scene/P2P release naming conventions.

  VIDEO_CODEC_PATTERNS = {
    h264: /\b(?:x\.?264|h\.?264|avc)\b/i,
    hevc: /\b(?:x\.?265|h\.?265|hevc|h\.?266)\b/i,
    av1:  /\bav1\b/i,
    vp9:  /\bvp9\b/i
  }.freeze

  # AAC pattern must be checked carefully to avoid matching "AAC" inside
  # "AACx264" or similar concatenated scene tags.  We look for AAC as a
  # standalone codec token: preceded by a non-alphanumeric or start-of-
  # title, and followed by a non-alphanumeric or end-of-title.  Also match
  # common scene patterns like DDP5.1.Atmos, AC3, etc.
  AUDIO_CODEC_PATTERNS = {
    aac:  /(?:\A|[^a-zA-Z])AAC(?:\z|[^a-zA-Z])/,
    ac3:  /\b(?:AC3|DDP[\d.]*|EAC3|ATMOS)\b/i,
    dts:  /\bDTS(?:-HD[\s.]*MA|[\s.]*HD|[\s.]*ES|[\s.]*X)?\b/i,
    mp3:  /\bMP3\b/i,
    opus: /\bOPUS\b/i,
    vorbis: /\bVORBIS\b/i
  }.freeze

  CONTAINER_PATTERNS = {
    mp4:  /\.mp4\b|\.m4v\b|\.mov\b/i,
    mkv:  /\.mkv\b/i,
    avi:  /\.avi\b/i,
    webm: /\.webm\b/i
  }.freeze

  # Compatibility tiers used for sorting.  Higher = more likely to play
  # without ffmpeg bottlenecks.
  #
  #   3 — Direct play ready:  MP4 + H.264 + AAC  (browser plays natively)
  #   2 — Stream copy:        MP4 + H.264 + other audio (ffmpeg stream-copy
  #                           video, transcode audio only)
  #   1 — Partial transcode:  HEVC/AV1 (needs decode + re-encode, CPU-heavy)
  #   0 — Unknown / exotic:   everything else
  COMPATIBILITY_SCORES = {
    direct_play:  3,
    stream_copy:  2,
    heavy_transcode: 1,
    unknown: 0
  }.freeze

  # Parse video codec from a release title string.
  def detect_video_codec(title)
    return "h264" if title.match?(VIDEO_CODEC_PATTERNS[:h264])
    return "hevc" if title.match?(VIDEO_CODEC_PATTERNS[:hevc])
    return "av1"  if title.match?(VIDEO_CODEC_PATTERNS[:av1])
    return "vp9"  if title.match?(VIDEO_CODEC_PATTERNS[:vp9])

    nil
  end

  # Parse audio codec from a release title string.
  def detect_audio_codec(title)
    return "aac"  if title.match?(AUDIO_CODEC_PATTERNS[:aac])
    return "ac3"  if title.match?(AUDIO_CODEC_PATTERNS[:ac3])
    return "dts"  if title.match?(AUDIO_CODEC_PATTERNS[:dts])
    return "mp3"  if title.match?(AUDIO_CODEC_PATTERNS[:mp3])
    return "opus" if title.match?(AUDIO_CODEC_PATTERNS[:opus])

    nil
  end

  # Parse container extension from a filename string.
  def detect_container(filename)
    CONTAINER_PATTERNS.each do |key, pattern|
      return key.to_s if filename.match?(pattern)
    end
    nil
  end

  # Compute a numeric compatibility score for stream sorting.
  # Higher = more likely to play without ffmpeg bottlenecks.
  def compatibility_score(video_codec:, audio_codec:, container:)
    # Direct play eligible: MP4 + H.264 + AAC
    if container == "mp4" && video_codec == "h264" && audio_codec == "aac"
      return COMPATIBILITY_SCORES[:direct_play]
    end

    # Stream copy: MP4 + H.264 (any audio — ffmpeg copies video, transcode audio)
    if container == "mp4" && video_codec == "h264"
      return COMPATIBILITY_SCORES[:stream_copy]
    end

    # Heavy transcode: modern codecs that need decode + re-encode
    if %w[hevc av1 vp9].include?(video_codec)
      return COMPATIBILITY_SCORES[:heavy_transcode]
    end

    COMPATIBILITY_SCORES[:unknown]
  end
end
