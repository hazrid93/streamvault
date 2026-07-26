# frozen_string_literal: true

# Extracts a small, authenticated preview frame from the original media URL.
# This intentionally does not use ActionController::Live: the bounded FFmpeg
# capture completes before the response is sent.
class TranscodeThumbnailController < ApplicationController
  include StreamUrlValidation

  MAX_TIMESTAMP_SECONDS = 24 * 60 * 60
  PRIVATE_CACHE_SECONDS = 2.hours.to_i

  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    timestamp = normalized_timestamp(params[:timestamp])
    unless timestamp && valid_stream_url?(input_url) && verify_stream_url!
      render json: { error: "Invalid thumbnail request" }, status: :bad_request
      return
    end

    jpeg = TranscodeService.extract_thumbnail(
      input_url,
      headers: stream_upstream_headers(input_url, current_user),
      timestamp: timestamp
    )

    response.headers["Cache-Control"] = "private, max-age=#{PRIVATE_CACHE_SECONDS}"
    send_data jpeg,
              type: "image/jpeg",
              disposition: :inline,
              filename: "thumbnail.jpg"
  rescue TranscodeService::ThumbnailBusyError
    response.headers["Retry-After"] = "1"
    render json: { error: "Thumbnail extraction is busy" }, status: :service_unavailable
  rescue TranscodeService::ThumbnailTimeoutError
    render json: { error: "Thumbnail extraction timed out" }, status: :gateway_timeout
  rescue TranscodeService::ThumbnailExtractionError
    render json: { error: "Thumbnail could not be extracted" }, status: :unprocessable_content
  end

  private

  def normalized_timestamp(value)
    seconds = Float(value, exception: false)
    return nil unless seconds&.finite?

    seconds.floor.clamp(0, MAX_TIMESTAMP_SECONDS)
  end
end
