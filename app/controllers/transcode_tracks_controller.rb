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
    render json: tracks.merge(
      subtitles: subtitles,
      direct_playable: direct_playable?(input_url, tracks),
      direct_stream_url: direct_stream_url(input_url)
    )
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end

  def direct_playable?(input_url, tracks)
    filename = params[:filename].to_s.downcase
    return false unless MP4_EXTENSIONS.any? { |ext| filename.end_with?(ext) }

    video_stream = TranscodeService.probe_video_stream(input_url, headers: transcode_headers)
    return false unless TranscodeService.browser_safe_video?(video_stream)

    audio_codecs = tracks[:audio].filter_map { |t| t[:codec] }
    return true if audio_codecs.empty? || audio_codecs.any? { |c| c == AAC_CODEC }

    false
  end

  def direct_stream_url(input_url)
    "/direct_stream?url=#{CGI.escape(input_url)}"
  end
end
