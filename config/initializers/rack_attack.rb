# frozen_string_literal: true

# Rate limiting via rack-attack.  Limits are per-IP for unauthenticated
# endpoints (login) and per-user-id for authenticated endpoints.  When a
# limit is hit, rack-attack returns 429 Too Many Requests with a
# Retry-After header.

class Rack::Attack
  # --- Store -----------------------------------------------------------
  # Use the Rails cache (Solid Cache, DB-backed) so limits are shared
  # across all Puma workers, not per-process.
  Rack::Attack.cache.store = Rails.cache

  # --- Helpers ---------------------------------------------------------
  # Authenticated requests are limited per-user; anonymous per-IP.
  # Use req.ip (works across Rack versions) instead of req.remote_ip
  # (which requires ActionDispatch::RemoteIp middleware and is not
  # available in all test environments).
  def self.client_ip(req)
    req.respond_to?(:remote_ip) ? req.remote_ip : req.ip
  end

  def self.authenticated_user_id(request)
    request.env["warden"]&.user(fetch: false)&.id&.to_s
  end

  safe_list = if Rails.env.development? || Rails.env.test?
    %w[127.0.0.1 ::1].freeze
  else
    [].freeze
  end

  # --- Throttles -------------------------------------------------------

  # Login attempts: 5 per 15 minutes per IP.
  throttle("sessions/ip", limit: 5, period: 15.minutes) do |req|
    next unless req.path == "/users/sign_in" && req.post?
    ip = client_ip(req)
    ip unless safe_list.include?(ip)
  end

  # Signup attempts: 3 per hour per IP.
  throttle("registrations/ip", limit: 3, period: 1.hour) do |req|
    next unless req.path == "/users" && req.post?
    ip = client_ip(req)
    ip unless safe_list.include?(ip)
  end

  # Watch progress saves: 1 per 3 seconds per user.
  throttle("progress/user", limit: 1, period: 3.seconds) do |req|
    next unless req.path == "/streaming/progress" && req.patch?
    authenticated_user_id(req)
  end

  # Transcode + HLS start: 2 per 10 seconds per user.
  throttle("stream_start/user", limit: 2, period: 10.seconds) do |req|
    next unless (req.path == "/streaming" && req.post?) ||
                (req.path == "/hls/start" && req.post?)
    authenticated_user_id(req)
  end

  # Search: 10 per minute per user.
  throttle("search/user", limit: 10, period: 1.minute) do |req|
    next unless req.path == "/search" && req.get?
    authenticated_user_id(req) || client_ip(req)
  end

  # --- Response on throttle -------------------------------------------
  # Override the default 429 response to return JSON for API clients
  # and a friendly HTML message for browser requests.
  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.matched_data"] || {}
    now = Time.now.to_i
    headers = {
      "Content-Type" => "text/plain",
      "Retry-After" => (match_data[:period] || 60).to_s
    }
    body = "Rate limit exceeded. Please retry later.\n"
    [ 429, headers, [ body ] ]
  end
end
