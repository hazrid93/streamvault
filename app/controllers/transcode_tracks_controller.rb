# frozen_string_literal: true

class TranscodeTracksController < ApplicationController
  include StreamUrlValidation

  MP4_EXTENSIONS = %w[.mp4 .m4v .mov].freeze
  AAC_CODEC = "aac"

  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { audio: [], subtitles: [] }, status: :bad_request
      return
    end

    tracks = TranscodeService.probe_media_tracks(input_url, headers: transcode_headers)
    external_subtitles = ExternalSubtitleService.search(
      imdb_id: params[:imdb_id],
      type: params[:type],
      season: params[:season],
      episode: params[:episode],
      title: params[:title],
      filename: params[:filename],
      preferred_languages: current_user.preferred_stream_languages,
      default_language: current_user.default_stream_language
    )

    subtitles = TranscodeService.selectable_subtitle_tracks(tracks[:subtitles] + external_subtitles)
    video_stream = probe_video_stream(input_url)
    render json: tracks.merge(
      subtitles: subtitles,
      video_codec: video_stream[:codec_name].to_s.downcase,
      direct_playable: direct_playable?(input_url, tracks, video_stream),
      direct_stream_url: direct_stream_url(input_url),
      remux_direct_playable: remux_direct_playable?(video_stream),
      remux_direct_url: remux_direct_url(input_url)
    )
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?
    return {} unless realdebrid_cdn_url?(params[:url].to_s)

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end

  def probe_video_stream(input_url)
    TranscodeService.probe_video_stream(input_url, headers: transcode_headers)
  end

  def direct_playable?(input_url, tracks, video_stream = nil)
    filename = params[:filename].to_s.downcase
    return false unless MP4_EXTENSIONS.any? { |ext| filename.end_with?(ext) }

    video_stream ||= probe_video_stream(input_url)
    return false unless TranscodeService.browser_safe_video?(video_stream)

    audio_codecs = tracks[:audio].filter_map { |t| t[:codec] }
    return true if audio_codecs.empty? || audio_codecs.any? { |c| c == AAC_CODEC }

    false
  end

  def direct_stream_url(input_url)
    "/direct_stream?url=#{CGI.escape(input_url)}"
  end

  # Remux direct play is eligible when the video codec is H.264 or HEVC,
  # regardless of container, B-frames, resolution, or pixel format.
  # The native <video> element handles B-frames correctly (unlike MSE's
  # SourceBuffer), and the browser plays HEVC natively on macOS via
  # VideoToolbox.  -c:v copy runs at near network speed — no re-encode.
  REMUX_COMPATIBLE_CODECS = %w[h264 hevc h265].freeze

  def remux_direct_playable?(video_stream)
    codec = video_stream[:codec_name].to_s.downcase
    REMUX_COMPATIBLE_CODECS.include?(codec)
  end

  def remux_direct_url(input_url)
    "/transcode?url=#{CGI.escape(input_url)}&remux=1"
  end
end
