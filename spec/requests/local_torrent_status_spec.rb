# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Local torrent session", type: :request do
  let(:user) { create(:user) }
  let(:service) { instance_double(LocalTorrentService) }
  let(:info_hash) { "a" * 40 }

  before do
    sign_in user
    allow(LocalTorrentService).to receive(:new).and_return(service)
  end

  it "stops the matching playback session" do
    allow(service).to receive(:stop).and_return(ServiceResult.success(true))

    post stop_local_torrent_path, params: { info_hash: info_hash, session_token: "current-token" }, as: :json

    expect(response).to have_http_status(:no_content)
    expect(service).to have_received(:stop).with(info_hash: info_hash, session_token: "current-token")
  end

  it "does not stop a stale or mismatched session" do
    allow(service).to receive(:stop).and_return(ServiceResult.failure("Invalid torrent"))

    post stop_local_torrent_path, params: { info_hash: info_hash, session_token: "stale-token" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
  end
end