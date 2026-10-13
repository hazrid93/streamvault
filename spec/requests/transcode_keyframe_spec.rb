require "rails_helper"

RSpec.describe "TranscodeKeyframe", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:url) { "https://download.real-debrid.com/d/test.mkv" }

  before do
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  it "returns the keyframe at or before the requested time" do
    allow(TranscodeService).to receive(:keyframe_at_or_before).and_return(596.04)

    get transcode_keyframe_path, params: { url: url, t: "600" }

    expect(response.parsed_body).to eq("seconds" => 596.04)
    expect(TranscodeService).to have_received(:keyframe_at_or_before)
      .with(url, seconds: "600", headers: { "Authorization" => "Bearer test_key" })
  end

  it "rejects URLs outside the stream allowlist" do
    get transcode_keyframe_path, params: { url: "https://example.com/video.mkv", t: "600" }

    expect(response).to have_http_status(:bad_request)
  end
end
