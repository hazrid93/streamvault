# frozen_string_literal: true


# Rate limiting via rack-attack. Limits are per-IP for PIN entry and
# per-user-id for authenticated endpoints. When a limit is hit, rack-attack
# returns 429 Too Many Requests with a Retry-After header.

class Rack::Attack
  # Use the Rails cache (Solid Cache, DB-backed) so limits are shared across
  # all Puma workers rather than being held per process.
  Rack::Attack.cache.store = Rails.cache

  def self.client_ip(request)
    request.respond_to?(:remote_ip) ? request.remote_ip : request.ip
  end

  def self.authenticated_user_id(request)
    request.env["warden"]&.user(fetch: false)&.id&.to_s
  end

  safe_list = if Rails.env.development? || Rails.env.test?
    %w[127.0.0.1 ::1].freeze
  else
    [].freeze
  end

  # PIN setup and unlock attempts: 5 per 15 minutes per IP.
  throttle("pin/ip", limit: 5, period: 15.minutes) do |request|
    next unless request.path == "/pin" && request.post?

    ip = client_ip(request)
    ip unless safe_list.include?(ip)
  end

  # Watch progress saves: 1 per 3 seconds per user.
  throttle("progress/user", limit: 1, period: 3.seconds) do |request|
    next unless request.path == "/streaming/progress" && request.patch?

    authenticated_user_id(request)
  end

  # Fresh stream resolution is expensive, so keep a tight per-user limit.
  throttle("stream_start/user", limit: 2, period: 10.seconds) do |request|
    next unless request.path == "/streaming" && request.post?

    authenticated_user_id(request)
  end

  # Seek thumbnails each start a short-lived FFmpeg process. Debounced dragging
  # remains responsive while sustained extraction abuse is bounded per user.
  throttle("transcode_thumbnail/user", limit: 30, period: 1.minute) do |request|
    next unless request.path == "/transcode/thumbnail" && request.get?

    authenticated_user_id(request)
  end

  # iOS HLS starts are also used for seeking and automatic stall recovery.
  # Keep abuse protection without blocking a legitimate seek + three recovery
  # attempts in the same ten-second window.
  throttle("hls_start/user", limit: 6, period: 10.seconds) do |request|
    next unless request.path == "/hls/start" && request.post?

    authenticated_user_id(request)
  end

  # Cast preparation starts an FFmpeg HLS session and may retain a local
  # torrent lease, so bound repeated device-picker retries per user.
  throttle("cast_start/user", limit: 3, period: 10.seconds) do |request|
    next unless request.path == "/cast_sessions" && request.post?

    authenticated_user_id(request)
  end

  # Lazy provider frames are intentionally concurrent, but still bounded so an
  # authenticated client cannot turn the app into an outbound provider flood.
  throttle("stream_results/user", limit: 30, period: 1.minute) do |request|
    next unless request.get? && request.path.match?(%r{\A/content/(movie|show)/tt\d+/stream_results/})

    authenticated_user_id(request)
  end

  throttle("similar_results/user", limit: 20, period: 1.minute) do |request|
    next unless request.get? && request.path.match?(%r{\A/content/(movie|show)/tt\d+/similar_results\z})

    authenticated_user_id(request)
  end

  # Unified discovery search: 10 title searches per minute per user. Keep the
  # legacy /search endpoint covered while old bookmarks redirect to /browse.
  throttle("search/user", limit: 10, period: 1.minute) do |request|
    next unless request.get? &&
                (request.path == "/search" || (request.path == "/browse" && request.params["q"].present?))

    authenticated_user_id(request) || client_ip(request)
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.matched_data"] || {}
    headers = {
      "Content-Type" => "text/plain",
      "Retry-After" => (match_data[:period] || 60).to_s
    }
    body = "Rate limit exceeded. Please retry later.\n"
    [ 429, headers, [ body ] ]
  end
end
