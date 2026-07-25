# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HLS streaming", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "testkey") }

  before do
    sign_in user
  end

  describe "POST /hls/start" do
    context "with invalid URL" do
      it "returns bad_request for private IP" do
        post "/hls/start", params: { url: "http://127.0.0.1/test.mp4" }
        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid stream URL")
      end
    end

    context "with valid URL but ffmpeg failure" do
      it "returns bad_gateway when transcode fails" do
        allow(TranscodeService).to receive(:transcode_to_hls)
          .and_raise(TranscodeService::TranscodeError, "FFmpeg failed")

        post "/hls/start", params: { url: "https://real-debrid.com/test.mp4" }
        expect(response).to have_http_status(:bad_gateway)
      end
    end
    it "clamps start_seconds to 24 hours before creating the session" do
      captured_kwargs = nil
      session = instance_double(HlsSession, id: "hls-start-clamped")
      allow(HlsSession).to receive(:create) do |**kwargs|
        captured_kwargs = kwargs
        session
      end

      post "/hls/start", params: {
        url: "https://real-debrid.com/test.mp4",
        start_seconds: "999999"
      }

      expect(response).to have_http_status(:ok)
      expect(captured_kwargs[:start_seconds]).to eq(86_400)
    end

    it "clamps invalid and negative start_seconds to zero before creating the session" do
      captured_kwargs = nil
      session = instance_double(HlsSession, id: "hls-start-zero")
      allow(HlsSession).to receive(:create) do |**kwargs|
        captured_kwargs = kwargs
        session
      end

      post "/hls/start", params: {
        url: "https://real-debrid.com/test.mp4",
        start_seconds: "-100"
      }

      expect(response).to have_http_status(:ok)
      expect(captured_kwargs[:start_seconds]).to eq(0)
    end
  end

  describe "GET /hls/:id/playlist.m3u8" do
    it "returns 404 for unknown session" do
      get "/hls/nonexistent/playlist.m3u8"
      expect(response).to have_http_status(:not_found)
    end
    it "returns a cached startup diagnostic after failed session cleanup" do
      cache = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(cache)
      HlsSession.set_error("failed-session", "FFmpeg exited before producing a segment.")

      get "/hls/failed-session/playlist.m3u8"

      expect(response).to have_http_status(:failed_dependency)
      expect(response.parsed_body).to eq("error" => "FFmpeg exited before producing a segment.")
    end

    context "with a valid session" do
      let(:session_id) { SecureRandom.hex(16) }
      let(:segment_dir) { Rails.root.join("tmp", "hls", session_id).to_s }
      let(:playlist_content) do
        <<~PLAYLIST
          #EXTM3U
          #EXT-X-VERSION:3
          #EXT-X-TARGETDURATION:4
          #EXT-X-MEDIA-SEQUENCE:0
          #EXT-X-PLAYLIST-TYPE:EVENT
          #EXTINF:4.000000,
          0.ts
          #EXT-X-ENDLIST
        PLAYLIST
      end

      before do
        FileUtils.mkdir_p(segment_dir)
        File.write(File.join(segment_dir, "playlist.m3u8"), playlist_content)
        File.write(File.join(segment_dir, "0.ts"), "dummy_ts_data")

        HlsSessionRecord.create!(
          user: user,
          session_id: session_id,
          segment_dir: segment_dir,
          pid: 99999
        )
      end

      after do
        FileUtils.rm_rf(segment_dir)
        HlsSessionRecord.find_by(session_id: session_id)&.destroy
      end

      it "returns the playlist with correct Content-Type" do
        get "/hls/#{session_id}/playlist.m3u8"
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/vnd.apple.mpegurl")
        expect(response.body).to start_with("#EXTM3U")
      end

      it "works without authentication (iOS media requests don't send cookies)" do
        sign_out user
        get "/hls/#{session_id}/playlist.m3u8"
        expect(response).to have_http_status(:ok)
        expect(response.body).to start_with("#EXTM3U")
      end

      it "returns 202 when playlist file is not ready yet" do
        File.delete(File.join(segment_dir, "playlist.m3u8"))
        get "/hls/#{session_id}/playlist.m3u8"
        expect(response).to have_http_status(:accepted)
      end
    end
  end

  describe "GET /hls/:id/:segment" do
    let(:session_id) { SecureRandom.hex(16) }
    let(:segment_dir) { Rails.root.join("tmp", "hls", session_id).to_s }

    before do
      FileUtils.mkdir_p(segment_dir)
      File.write(File.join(segment_dir, "playlist.m3u8"), "#EXTM3U\n")
      File.write(File.join(segment_dir, "0.ts"), "dummy_ts_segment_data")

      HlsSessionRecord.create!(
        user: user,
        session_id: session_id,
        segment_dir: segment_dir,
        pid: 99999
      )
    end

    after do
      FileUtils.rm_rf(segment_dir)
      HlsSessionRecord.find_by(session_id: session_id)&.destroy
    end

    it "returns the segment with correct Content-Type" do
      get "/hls/#{session_id}/0.ts"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("video/mp2t")
    end

    it "works without authentication (iOS media requests don't send cookies)" do
      sign_out user
      get "/hls/#{session_id}/0.ts"
      expect(response).to have_http_status(:ok)
    end

    it "returns 503 for not-yet-produced segment on a live stream" do
      get "/hls/#{session_id}/99.ts"
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("1")
    end
    it "bounds the wait for a missing live segment before asking Safari to retry" do
      stub_const("HlsController::SEGMENT_WAIT_SECONDS", 0.02)
      stub_const("HlsController::SEGMENT_POLL_INTERVAL_SECONDS", 0.005)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      get "/hls/#{session_id}/99.ts"

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("1")
      expect(elapsed).to be < 0.5
    end

    it "returns 404 for non-existent segment when ffmpeg has finished" do
      File.write(File.join(segment_dir, "playlist.m3u8"), "#EXTM3U\n#EXT-X-ENDLIST\n")
      get "/hls/#{session_id}/99.ts"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /hls/:id/stop" do
    let(:session_id) { SecureRandom.hex(16) }
    let(:segment_dir) { Rails.root.join("tmp", "hls", session_id).to_s }

    before do
      FileUtils.mkdir_p(segment_dir)
      File.write(File.join(segment_dir, "playlist.m3u8"), "#EXTM3U\n")

      HlsSessionRecord.create!(
        user: user,
        session_id: session_id,
        segment_dir: segment_dir,
        pid: 99999
      )
    end

    it "returns ok and removes the session" do
      post "/hls/#{session_id}/stop"
      expect(response).to have_http_status(:ok)
      expect(HlsSessionRecord.find_by(session_id: session_id)).to be_nil
    end
  end
end
