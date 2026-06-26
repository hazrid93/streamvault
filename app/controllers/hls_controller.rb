# frozen_string_literal: true

class HlsController < ApplicationController
  include StreamUrlValidation

  # The start/stop endpoints require an authenticated user (they
  # access current_user and the RealDebrid API key).  The playlist
  # and segment endpoints must NOT require authentication — iOS
  # Safari's <video> element fetches media resources without sending
  # session cookies, so cookie-based auth would reject those requests
  # with 403.  Instead, the session ID (128 bits of entropy) acts as
  # an unguessable bearer token, and the playlist/segment actions
  # rely on the session ID alone for authorisation.
  before_action :authenticate_user!, only: %i[start stop]

  # POST /hls/start
  # Params: url, start_seconds, audio_stream, subtitle_stream
  # Returns: { session_id: "...", playlist_url: "/hls/<id>/playlist.m3u8" }
  def start
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url)
      render json: { error: "Invalid stream URL" }, status: :bad_request
      return
    end

    headers = {}
    if current_user.has_realdebrid_key?
      headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
    end

    session = HlsSession.create(
      user_id: current_user.id,
      input_url: input_url,
      headers: headers,
      start_seconds: params[:start_seconds].to_f,
      audio_stream: params[:audio_stream],
      subtitle_stream: params[:subtitle_stream],
      default_language: current_user.default_stream_language,
      preferred_languages: current_user.preferred_stream_languages
    )

    render json: { session_id: session.id, playlist_url: "/hls/#{session.id}/playlist.m3u8" }
  rescue TranscodeService::TranscodeError => e
    Rails.logger.error("[HLS] Failed to start: #{e.message}")
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /hls/:id/playlist.m3u8
  # No cookie auth — iOS Safari's <video> element fetches media without
  # sending session cookies.  The session ID is an unguessable bearer
  # token that authorises the request.
  def playlist
    session = HlsSession.find(params[:id])
    unless session
      head :not_found
      return
    end

    # If ffmpeg failed before producing any segments, return a
    # descriptive error so the client can stop polling and show it.
    error = HlsSession.error(params[:id])
    if error
      render json: { error: error }, status: :failed_dependency
      return
    end

    # Playlist not ready yet — ffmpeg is still transcoding the first
    # segment.  Return 202 so the client knows to keep polling.
    unless File.exist?(session.playlist_path)
      head :accepted
      return
    end

    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    send_data File.read(session.playlist_path),
              type: "application/vnd.apple.mpegurl",
              disposition: :inline
  end

  # GET /hls/:id/:segment (e.g. 0.ts, 1.ts)
  def segment
    session = HlsSession.find(params[:id])
    unless session
      head :not_found
      return
    end

    segment_index = params[:segment].to_i
    path = session.segment_path(segment_index)

    unless File.exist?(path)
      head :not_found
      return
    end

    response.headers["Cache-Control"] = "no-cache"
    send_file path, type: "video/mp2t", disposition: :inline
  end

  # POST /hls/:id/stop
  def stop
    HlsSession.stop(params[:id])
    head :ok
  end
end
