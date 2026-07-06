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

    it "attaches the Authorization header for all allowlisted hosts" do
      # The RD bearer token is attached to all allowlisted stream hosts,
      # including provider hosts.  Provider hosts (Torrentio/Comet) are
      # user-configured and trusted — the key is needed for some
      # provider endpoints that proxy RD content.
      stub_request(:get, "https://torrentio.strem.fun/stream/movie/tt123.json")
        .to_return(status: 200, body: "data", headers: { 'Content-Type' => 'application/json' })

      get direct_stream_path, params: { url: "https://torrentio.strem.fun/stream/movie/tt123.json" }

      expect(WebMock).to have_requested(:get, "https://torrentio.strem.fun/stream/movie/tt123.json")
        .with { |req| req.headers["Authorization"].present? }
    end
  end
end
