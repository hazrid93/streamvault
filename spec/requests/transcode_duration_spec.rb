require 'rails_helper'

RSpec.describe "TranscodeDuration", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  before do
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  describe "GET /transcode/duration" do
    context "when not authenticated" do
      it "redirects to login" do
        sign_out user
        get transcode_duration_path, params: { url: "https://download.real-debrid.com/d/test.mkv" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    it "rejects file:// URLs" do
      get transcode_duration_path, params: { url: "file:///etc/passwd" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects localhost URLs" do
      get transcode_duration_path, params: { url: "http://127.0.0.1:3000/internal.mp4" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects non-allowlisted public URLs" do
      get transcode_duration_path, params: { url: "https://example.com/video.mkv" }
      expect(response).to have_http_status(:bad_request)
    end

    it "returns duration JSON for valid URLs" do
      allow(TranscodeService).to receive(:probe_duration).and_return(7200)
      get transcode_duration_path, params: { url: "https://download.real-debrid.com/d/test.mkv" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["duration"]).to eq(7200)
    end
  end
end
