# frozen_string_literal: true

class LiveCaptionsController < ApplicationController
  include StreamUrlValidation

  before_action :authenticate_user!

  # POST /transcode/live_captions
  def create
    unless LiveCaptionTranslationService.enabled?
      render json: { error: "Local live captions are unavailable" }, status: :service_unavailable
      return
    end

    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { error: "Invalid or disallowed stream URL" }, status: :bad_request
      return
    end

    result = LiveCaptionTranslationService.new.translate(
      input_url,
      headers: stream_upstream_headers(input_url, current_user),
      audio_stream: normalized_audio_stream,
      source_language: params[:source_language],
      start_seconds: params[:start_seconds],
      default_language: current_user.default_language,
      preferred_languages: current_user.preferred_stream_languages
    )

    if result.ok?
      render json: {
        cues: result.cues,
        window_start: result.window_start,
        window_end: result.window_end,
        source_language: result.source_language,
        output_language: "en"
      }
    else
      render json: {
        error: result.message,
        retry_after: result.retry_after
      }.compact, status: response_status(result.status)
    end
  end

  private

  def normalized_audio_stream
    value = params[:audio_stream].presence
    return unless value

    Integer(value, exception: false)&.then { |index| index.between?(0, 999) ? index : nil }
  end

  def response_status(status)
    case status
    when :invalid then :bad_request
    when :no_audio then :unprocessable_content
    when :busy then :too_many_requests
    when :timeout then :gateway_timeout
    when :not_configured, :unavailable then :service_unavailable
    else :bad_gateway
    end
  end
end
