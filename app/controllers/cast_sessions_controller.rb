# frozen_string_literal: true

class CastSessionsController < ApplicationController
  include StreamUrlValidation

  before_action :authenticate_user!

  def create
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { error: "Invalid stream URL" }, status: :bad_request
      return
    end

    local_lease = nil
    if local_torrent_url?(input_url)
      retained = retain_local_lease
      if retained.nil? || retained.failure?
        render json: { error: "Local playback session is no longer active" }, status: :unprocessable_entity
        return
      end
      local_lease = retained.data[:lease]
      # Never trust the client-supplied TorrServer query. Reconstruct the URL
      # from the exact hash/file attached to the authenticated browser lease.
      input_url = retained.data[:streaming_url]
    elsif params[:local_torrent_hash].present?
      render json: { error: "Local torrent parameters do not match the stream source" }, status: :bad_request
      return
    end

    hls = HlsSession.create(
      user_id: current_user.id,
      input_url: input_url,
      headers: stream_upstream_headers(input_url, current_user),
      start_seconds: params[:position].to_f.clamp(0, 86_400),
      audio_stream: nil,
      subtitle_stream: nil,
      default_language: current_user.default_stream_language,
      preferred_languages: current_user.preferred_stream_languages
    )

    unless wait_for_playlist(hls)
      HlsSession.stop(hls.id)
      local_lease&.release!
      render json: { error: "Cast stream did not become ready in time" }, status: :gateway_timeout
      return
    end

    cast_session = CastSession.create!(
      user: current_user,
      local_torrent_lease: local_lease,
      hls_session_id: hls.id,
      title: params[:title].to_s.first(300),
      poster_url: safe_poster_url(params[:poster_url]),
      position_seconds: params[:position].to_i.clamp(0, 86_400),
      last_heartbeat_at: Time.current,
      expires_at: CastSession::TTL.from_now
    )

    render json: {
      id: cast_session.id,
      media_url: "#{request.base_url}/hls/#{hls.id}/playlist.m3u8",
      content_type: "application/vnd.apple.mpegurl",
      title: cast_session.title,
      poster_url: cast_session.poster_url
    }
  rescue TranscodeService::TranscodeError => error
    HlsSession.stop(hls.id) if hls
    local_lease&.release!
    Rails.logger.warn("[Cast] HLS start failed: #{error.message}")
    render json: { error: "Cast stream could not be prepared" }, status: :bad_gateway
  rescue StandardError => error
    HlsSession.stop(hls.id) if hls
    local_lease&.release!
    Rails.logger.error("[Cast] Session creation failed: #{error.class}: #{error.message}")
    render json: { error: "Cast session could not be created" }, status: :internal_server_error
  end

  def destroy
    session = current_user.cast_sessions.active.find(params[:id])
    session.finish!
    LocalTorrentService.new.cleanup!
    head :no_content
  end

  private

  def retain_local_lease
    hash = params[:local_torrent_hash].to_s
    return nil if hash.blank?

    browser_lease = current_user.local_torrent_leases.active.find_by(
      info_hash: hash.downcase,
      lease_token: params[:local_torrent_session].to_s
    )
    return nil unless browser_lease

    result = LocalTorrentService.new(user: current_user).retain(
      info_hash: browser_lease.info_hash,
      file_idx: browser_lease.file_idx,
      filename: browser_lease.filename,
      title: browser_lease.title,
      kind: "cast"
    )
    result
  end

  def wait_for_playlist(session)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    loop do
      return true if session.playlist_ready?
      return false if HlsSession.error(session.id)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.25
    end
  end

  def safe_poster_url(value)
    uri = URI.parse(value.to_s)
    uri.to_s if uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end
end
