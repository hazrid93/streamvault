# frozen_string_literal: true

class DirectStreamController < ApplicationController
  include ActionController::Live
  include StreamUrlValidation

  before_action :authenticate_user!

  MAX_REDIRECTS = 5

  # GET /direct_stream?url=... — transparent HTTP proxy for direct play.
  # Forwards the request to the RealDebrid CDN with auth headers and Range
  # passthrough, so the browser's <video> element downloads at network speed
  # and seeks via Range requests — no ffmpeg involved.
  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      head :bad_request
      return
    end

    range = request.headers["HTTP_RANGE"]

    response.headers["Cache-Control"] = "no-cache"
    response.headers["Accept-Ranges"] = "bytes"
    response.headers["X-Accel-Buffering"] = "no"

    uri = URI.parse(input_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.read_timeout = 60
    http.open_timeout = 10

    request_headers = {}
    if current_user.has_realdebrid_key?
      request_headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
    end
    request_headers["Range"] = range if range

    begin
      http.request_get(uri.request_uri, request_headers) do |upstream|
        response.status = upstream.code.to_i
        pass_through_header(upstream, "Content-Type")
        pass_through_header(upstream, "Content-Length")
        pass_through_header(upstream, "Content-Range")

        upstream.read_body { |chunk| response.stream.write(chunk) }
      end
    rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::EPIPE, IOError
    rescue ActionController::Live::ClientDisconnected
    ensure
      response.stream.close rescue nil
    end
  end

  private

  def pass_through_header(upstream, name)
    value = upstream[name]
    response.headers[name] = value if value.present?
  end
end
