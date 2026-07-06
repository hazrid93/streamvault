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

    it "does not attach the Authorization header for non-RD CDN hosts" do
      # Even if a provider host is allowlisted, the RD key should not
      # be sent to it — only real-debrid.com CDN hosts get the bearer.
      # torrentio.strem.fun is a provider host (allowlisted via
      # StreamProvider.resolve_base_urls) so it passes the host check,
      # but provider hosts bypass the DNS-resolution check. The bearer
      # token should still NOT be attached. We verify by stubbing the
      # upstream HTTP and checking the request didn't include an
      # Authorization header.
      stub_request(:get, "https://torrentio.strem.fun/stream/movie/tt123.json")
        .to_return(status: 200, body: "data", headers: { 'Content-Type' => 'application/json' })

      get direct_stream_path, params: { url: "https://torrentio.strem.fun/stream/movie/tt123.json" }

      # The request should succeed (200 from stub) and NOT include
      # the RD key in the outbound Authorization header.
      expect(WebMock).to have_requested(:get, "https://torrentio.strem.fun/stream/movie/tt123.json")
        .with { |req| req.headers["Authorization"].nil? }
    end
  end
end
