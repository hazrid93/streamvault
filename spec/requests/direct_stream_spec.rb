require 'rails_helper'

RSpec.describe "DirectStream", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  before do
    sign_in user
    # Stub DNS so download.real-debrid.com passes the SSRF guard's
    # public-address check in offline test envs.
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  describe "GET /direct_stream" do
    context "when not authenticated" do
      it "redirects to login" do
        sign_out user
        get direct_stream_path, params: { url: "https://download.real-debrid.com/d/test.mkv" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    it "rejects file:// URLs" do
      get direct_stream_path, params: { url: "file:///etc/passwd" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects localhost URLs" do
      get direct_stream_path, params: { url: "http://127.0.0.1:3000/internal.mp4" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects non-allowlisted public URLs" do
      get direct_stream_path, params: { url: "https://example.com/video.mkv" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects private-network URLs" do
      get direct_stream_path, params: { url: "http://192.168.1.1/video.mkv" }
      expect(response).to have_http_status(:bad_request)
    end

    it "never sends the RealDebrid key to a provider host" do
      stub_request(:get, "https://torrentio.strem.fun/stream/movie/tt123.json")
        .to_return(status: 200, body: "data", headers: { "Content-Type" => "application/json" })

      get direct_stream_path, params: { url: "https://torrentio.strem.fun/stream/movie/tt123.json" }

      expect(WebMock).to have_requested(:get, "https://torrentio.strem.fun/stream/movie/tt123.json")
        .with { |request| request.headers["Authorization"].blank? }
    end

    it "allows only the configured TorrServer origin without leaking the RD key" do
      previous = ENV["LOCAL_TORRENT_ENABLED"]
      ENV["LOCAL_TORRENT_ENABLED"] = "true"
      local_url = "http://torrserver:8090/stream/Movie.mkv?link=#{'a' * 40}&index=1&play="
      stub_request(:get, local_url)
        .to_return(status: 206, body: "data", headers: { "Content-Type" => "video/x-matroska" })

      get direct_stream_path, params: { url: local_url }

      expect(WebMock).to have_requested(:get, local_url)
        .with { |request| request.headers["Authorization"].to_s.start_with?("Basic ") && !request.headers["Authorization"].include?("test_key") }
    ensure
      ENV["LOCAL_TORRENT_ENABLED"] = previous
    end

    it "rejects a different port on the local torrent hostname" do
      previous = ENV["LOCAL_TORRENT_ENABLED"]
      ENV["LOCAL_TORRENT_ENABLED"] = "true"

      get direct_stream_path, params: { url: "http://torrserver:8080/private" }

      expect(response).to have_http_status(:bad_request)
    ensure
      ENV["LOCAL_TORRENT_ENABLED"] = previous
    end

    it "sends the RealDebrid key only to a RealDebrid CDN" do
      stub_request(:get, "https://download.real-debrid.com/d/test.mkv")
        .to_return(status: 200, body: "data", headers: { "Content-Type" => "video/x-matroska" })

      get direct_stream_path, params: { url: "https://download.real-debrid.com/d/test.mkv" }

      expect(WebMock).to have_requested(:get, "https://download.real-debrid.com/d/test.mkv")
        .with { |request| request.headers["Authorization"] == "Bearer test_key" }
    end
  end
end
