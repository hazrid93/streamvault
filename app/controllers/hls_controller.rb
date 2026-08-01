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
  MAX_START_SECONDS = 24 * 60 * 60
  MAX_SEGMENT_WAIT_SECONDS = 2.0
  SEGMENT_POLL_INTERVAL_SECONDS = 0.05
  SEGMENT_WAIT_SECONDS = begin
    seconds = ENV.fetch("HLS_SEGMENT_WAIT_SECONDS", Rails.env.test? ? "0.05" : "1.0").to_f
    seconds.finite? ? seconds.clamp(0.0, MAX_SEGMENT_WAIT_SECONDS) : (Rails.env.test? ? 0.05 : 1.0)
  end

  # POST /hls/start
  # Params: url, start_seconds, audio_stream, subtitle_stream, hdr
  # Returns: { session_id: "...", playlist_url: "/hls/<id>/playlist.m3u8" }
  def start
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { error: "Invalid stream URL" }, status: :bad_request
      return
    end

    headers = stream_upstream_headers(input_url, current_user)

    session = HlsSession.create(
      user_id: current_user.id,
      input_url: input_url,
      headers: headers,
      start_seconds: normalized_start_seconds(params[:start_seconds]),
      audio_stream: params[:audio_stream],
      subtitle_stream: params[:subtitle_stream],
      default_language: current_user.default_stream_language,
      preferred_languages: current_user.preferred_stream_languages,
      hdr: params[:hdr] == "1"
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
    error = HlsSession.error(params[:id])
    if error
      render json: { error: error }, status: :failed_dependency
      return
    end
    session = HlsSession.find(params[:id])
    unless session
      head :not_found
      return
    end

    HlsSession.touch_activity(session.id)
    touch_cast_session(session.id)

    # Playlist not ready yet — either the file doesn't exist, or
    # ffmpeg has written the #EXTM3U header but no segment entries
    # yet (the first segment isn't complete).  Return 202 so the
    # client keeps polling.
    unless session.playlist_ready?
      head :accepted
      return
    end

    response.headers["Cache-Control"] = "no-cache"
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["X-Accel-Buffering"] = "no"
    # The session ID in the URL path is an unguessable bearer token.
    # Prevent it leaking to third-party hosts via a Referer header if
    # the player page has external links.
    response.headers["Referrer-Policy"] = "no-referrer"
    send_data File.read(session.playlist_path),
              type: "application/vnd.apple.mpegurl",
              disposition: :inline
  end

  # GET /hls/:id/:segment (e.g. init.mp4, 0.m4s, 0.ts)
  #
  # iOS Safari's native HLS player requests segments by index as it
  # plays through the playlist. When ffmpeg is transcoding slower than 1×, it
  # may request a segment before the file has been written. Wait briefly for
  # the file to appear; long waits can occupy all Puma threads, so the wait is
  # configured with HLS_SEGMENT_WAIT_SECONDS and capped at two seconds.

  def segment
    session = HlsSession.find(params[:id])
    unless session
      head :not_found
      return
    end
    HlsSession.touch_activity(session.id)
    touch_cast_session(session.id)

    segment_name = params[:segment].to_s
    path = case segment_name
    when "init.mp4"
      session.init_segment_path
    when /\A(\d+)\.ts\z/
      session.segment_path(Regexp.last_match(1).to_i)
    when /\A(\d+)\.m4s\z/
      session.segment_path(Regexp.last_match(1).to_i, format: :m4s)
    end
    unless path
      head :not_found
      return
    end

    unless File.exist?(path)
      # Check if ffmpeg has already exited (playlist has #EXT-X-ENDLIST)
      # — if so, the segment truly doesn't exist and 404 is correct.
      if ffmpeg_finished?(session)
        head :not_found
        return
      end

      # Poll the filesystem without holding a DB connection.  The bounded
      # wait gives ffmpeg a chance to finish the segment, then lets Safari
      # retry instead of occupying a Puma thread for a long time.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SEGMENT_WAIT_SECONDS
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        sleep [ SEGMENT_POLL_INTERVAL_SECONDS, remaining ].min
        break if File.exist?(path) || ffmpeg_finished?(session)
      end

      unless File.exist?(path)
        if ffmpeg_finished?(session)
          head :not_found
        else
          response.headers["Retry-After"] = "1"
          head :service_unavailable
        end
        return
      end
    end

    response.headers["Cache-Control"] = "no-cache"
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Referrer-Policy"] = "no-referrer"
    content_type = case File.extname(path)
    when ".ts" then "video/mp2t"
    when ".m4s", ".mp4" then "video/mp4"
    else "application/octet-stream"
    end
    send_file path, type: content_type, disposition: :inline
  end

  # POST /hls/:id/stop
  def stop
    HlsSession.stop(params[:id])
    head :ok
  end

  private

  def touch_cast_session(hls_session_id)
    CastSession.active.find_by(hls_session_id: hls_session_id)&.heartbeat!
  rescue StandardError => error
    Rails.logger.debug("[Cast] Heartbeat failed: #{error.class}: #{error.message}")
  end

  def ffmpeg_finished?(session)
    playlist = session.playlist_path
    return false unless File.exist?(playlist)
    File.read(playlist).include?("#EXT-X-ENDLIST")
  rescue StandardError
    false
  end

  def normalized_start_seconds(value)
    seconds = value.to_f
    return 0 unless seconds.finite? && seconds.positive?

    [ seconds, MAX_START_SECONDS ].min
  end
end
