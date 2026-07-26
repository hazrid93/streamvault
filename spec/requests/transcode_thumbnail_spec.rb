# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Transcode thumbnails", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:input_url) { "https://download.real-debrid.com/d/file123/movie.mkv" }
  let(:jpeg) { "\xFF\xD8\xFFpreview\xFF\xD9".b }

  before do
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  describe "GET /transcode/thumbnail" do
    it "requires authentication" do
      sign_out user

      get transcode_thumbnail_path, params: { url: input_url, timestamp: 30 }

      expect(response).to redirect_to(new_user_session_path)
    end

    it "rejects invalid, private, and non-allowlisted URLs before extraction" do
      expect(TranscodeService).not_to receive(:extract_thumbnail)

      [
        "file:///etc/passwd",
        "http://127.0.0.1/internal.mp4",
        "https://example.com/movie.mkv"
      ].each do |url|
        get transcode_thumbnail_path, params: { url: url, timestamp: 30 }
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "rejects non-finite and malformed timestamps before extraction" do
      expect(TranscodeService).not_to receive(:extract_thumbnail)

      [ "not-a-number", "NaN", "Infinity", nil ].each do |timestamp|
        get transcode_thumbnail_path, params: { url: input_url, timestamp: timestamp }
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "forwards scoped credentials, floors timestamps, and returns a private inline JPEG" do
      expect(TranscodeService).to receive(:extract_thumbnail).with(
        input_url,
        headers: { "Authorization" => "Bearer test_key" },
        timestamp: 42
      ).and_return(jpeg)

      get transcode_thumbnail_path, params: { url: input_url, timestamp: "42.9" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/jpeg")
      expect(response.headers["Content-Disposition"]).to include("inline")
      expect(response.headers["Cache-Control"].split(", ")).to contain_exactly("private", "max-age=300")
      expect(response.body.b).to eq(jpeg)
    end

    it "clamps timestamps to the source timeline bounds" do
      allow(TranscodeService).to receive(:extract_thumbnail).and_return(jpeg)

      get transcode_thumbnail_path, params: { url: input_url, timestamp: "-12.5" }
      expect(TranscodeService).to have_received(:extract_thumbnail).with(input_url, hash_including(timestamp: 0))

      get transcode_thumbnail_path, params: { url: input_url, timestamp: "999999" }
      expect(TranscodeService).to have_received(:extract_thumbnail).with(input_url, hash_including(timestamp: 86_400))
    end

    it "allows only the configured local torrent origin and forwards only its Basic credential" do
      previous = ENV.to_h.slice("LOCAL_TORRENT_ENABLED", "TORRSERVER_USERNAME", "TORRSERVER_PASSWORD")
      ENV["LOCAL_TORRENT_ENABLED"] = "true"
      ENV["TORRSERVER_USERNAME"] = "torr-user"
      ENV["TORRSERVER_PASSWORD"] = "torr-password"
      local_url = "http://torrserver:8090/stream/movie.mkv?link=#{'a' * 40}&index=1&play="
      expected_auth = "Basic #{Base64.strict_encode64('torr-user:torr-password')}"
      allow(TranscodeService).to receive(:extract_thumbnail).and_return(jpeg)

      get transcode_thumbnail_path, params: { url: local_url, timestamp: 10 }

      expect(response).to have_http_status(:ok)
      expect(TranscodeService).to have_received(:extract_thumbnail).with(
        local_url,
        headers: { "Authorization" => expected_auth },
        timestamp: 10
      )

      get transcode_thumbnail_path, params: { url: "http://torrserver:8080/private", timestamp: 10 }
      expect(response).to have_http_status(:bad_request)
    ensure
      %w[LOCAL_TORRENT_ENABLED TORRSERVER_USERNAME TORRSERVER_PASSWORD].each do |name|
        previous.key?(name) ? ENV[name] = previous[name] : ENV.delete(name)
      end
    end

    it "returns a short retry response when thumbnail capacity is busy" do
      allow(TranscodeService).to receive(:extract_thumbnail)
        .and_raise(TranscodeService::ThumbnailBusyError, "sensitive queue details")

      get transcode_thumbnail_path, params: { url: input_url, timestamp: 30 }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("1")
      expect(response.body).to include("Thumbnail extraction is busy")
      expect(response.body).not_to include("sensitive queue details")
    end

    it "returns a bounded timeout response without leaking extraction details" do
      allow(TranscodeService).to receive(:extract_thumbnail)
        .and_raise(TranscodeService::ThumbnailTimeoutError, "Bearer test_key #{input_url} ffmpeg stderr")

      get transcode_thumbnail_path, params: { url: input_url, timestamp: 30 }

      expect(response).to have_http_status(:gateway_timeout)
      expect(response.body).to include("Thumbnail extraction timed out")
      expect(response.body).not_to include("test_key", input_url, "ffmpeg")
    end

    it "returns a bounded unprocessable response for other extraction failures" do
      allow(TranscodeService).to receive(:extract_thumbnail)
        .and_raise(TranscodeService::ThumbnailExtractionError, "secret diagnostic")

      get transcode_thumbnail_path, params: { url: input_url, timestamp: 30 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Thumbnail could not be extracted")
      expect(response.body).not_to include("secret diagnostic")
    end
  end
end
