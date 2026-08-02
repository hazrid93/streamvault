# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Live captions" do
  let(:user) { create(:user) }
  let(:stream_url) { "https://download.real-debrid.com/d/file123/movie.mkv" }

  before do
    sign_in user
    allow(LiveCaptionTranslationService).to receive(:enabled?).and_return(true)
    allow_any_instance_of(LiveCaptionsController).to receive(:resolve_public_addresses).and_return([ "1.1.1.1" ])
  end

  it "returns absolute English cues from the selected audio stream" do
    result = LiveCaptionTranslationService::Result.new(
      status: :ok,
      cues: [ { start: 50.2, end: 53.8, text: "Good evening." } ],
      window_start: 50,
      window_end: 80,
      source_language: "fr"
    )
    service = instance_double(LiveCaptionTranslationService, translate: result)
    allow(LiveCaptionTranslationService).to receive(:new).and_return(service)

    post live_captions_path, params: {
      url: stream_url,
      audio_stream: "2",
      start_seconds: "57"
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "cues" => [ { "start" => 50.2, "end" => 53.8, "text" => "Good evening." } ],
      "window_start" => 50,
      "window_end" => 80,
      "source_language" => "fr",
      "output_language" => "en"
    )
    expect(service).to have_received(:translate).with(
      stream_url,
      headers: anything,
      audio_stream: 2,
      source_language: nil,
      start_seconds: "57",
      default_language: user.default_language,
      preferred_languages: user.preferred_stream_languages
    )
  end

  it "rejects disallowed source URLs before invoking Whisper" do
    expect(LiveCaptionTranslationService).not_to receive(:new)

    post live_captions_path, params: {
      url: "https://attacker.example/private.mkv",
      start_seconds: "0"
    }

    expect(response).to have_http_status(:bad_request)
  end

  it "reports a busy local caption engine with a retry delay" do
    result = LiveCaptionTranslationService::Result.new(
      status: :busy,
      cues: [],
      message: "Local caption engine is busy",
      retry_after: 5
    )
    allow(LiveCaptionTranslationService).to receive(:new).and_return(
      instance_double(LiveCaptionTranslationService, translate: result)
    )

    post live_captions_path, params: { url: stream_url, start_seconds: "0" }

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to include("retry_after" => 5)
  end

  it "returns service unavailable without invoking extraction when local captions are disabled" do
    allow(LiveCaptionTranslationService).to receive(:enabled?).and_return(false)
    expect(LiveCaptionTranslationService).not_to receive(:new)

    post live_captions_path, params: { url: stream_url, start_seconds: "0" }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["error"]).to eq("Local live captions are unavailable")
  end

  it "requires authentication" do
    sign_out user

    post live_captions_path, params: { url: stream_url, start_seconds: "0" }

    expect(response).to redirect_to(new_user_session_path)
  end
end
