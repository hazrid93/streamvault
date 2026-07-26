# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cast sessions", type: :request do
  let(:user) { create(:user) }
  let(:hls) { instance_double(HlsSession, id: "hls-token-123", playlist_ready?: true) }

  before { sign_in user }

  it "creates a cookie-free HLS URL for a receiver" do
    allow(HlsSession).to receive(:create).and_return(hls)
    allow(HlsSession).to receive(:error).and_return(nil)

    post cast_sessions_path, params: {
      url: "https://torrentio.strem.fun/resolve/test.mkv",
      position: 321,
      title: "Cast Movie",
      poster_url: "https://image.tmdb.org/poster.jpg"
    }, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body
    expect(payload["media_url"]).to eq("http://www.example.com/hls/hls-token-123/playlist.m3u8")
    expect(payload["content_type"]).to eq("application/vnd.apple.mpegurl")
    expect(CastSession.last).to have_attributes(user_id: user.id, hls_session_id: "hls-token-123", position_seconds: 321)
  end

  it "derives a local cast URL from the authenticated lease instead of trusting client query parameters" do
    previous = ENV["LOCAL_TORRENT_ENABLED"]
    ENV["LOCAL_TORRENT_ENABLED"] = "true"
    hash = "a" * 40
    browser_lease = LocalTorrentLease.create!(
      user: user, lease_token: "b" * 48, info_hash: hash, file_idx: 2,
      filename: "Movie.mkv", kind: "browser", last_heartbeat_at: Time.current
    )
    cast_lease = LocalTorrentLease.create!(
      user: user, lease_token: "c" * 48, info_hash: hash, file_idx: 2,
      filename: "Movie.mkv", kind: "cast", last_heartbeat_at: Time.current
    )
    trusted_url = "http://torrserver:8090/stream/Movie.mkv?link=#{hash}&index=2&play="
    malicious_url = "http://torrserver:8090/stream/Other.mkv?link=#{'f' * 40}&index=9&play="
    local = instance_double(LocalTorrentService)
    allow(LocalTorrentService).to receive(:new).with(user: user).and_return(local)
    allow(local).to receive(:retain).and_return(ServiceResult.success(lease: cast_lease, streaming_url: trusted_url))
    allow(HlsSession).to receive(:create).and_return(hls)
    allow(HlsSession).to receive(:error).and_return(nil)

    post cast_sessions_path, params: {
      url: malicious_url,
      local_torrent_hash: browser_lease.info_hash,
      local_torrent_session: browser_lease.lease_token,
      title: "Movie"
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(HlsSession).to have_received(:create).with(hash_including(input_url: trusted_url))
  ensure
    ENV["LOCAL_TORRENT_ENABLED"] = previous
  end

  it "rejects an arbitrary private-network source" do
    allow(HlsSession).to receive(:create)

    post cast_sessions_path, params: { url: "http://169.254.169.254/metadata" }, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(HlsSession).not_to have_received(:create)
  end

  it "finishes the receiver session and runs local cleanup" do
    session = CastSession.create!(
      user: user,
      hls_session_id: "hls-token-stop",
      last_heartbeat_at: Time.current,
      expires_at: 6.hours.from_now
    )
    cleanup = instance_double(LocalTorrentService, cleanup!: true)
    allow(HlsSession).to receive(:stop)
    allow(LocalTorrentService).to receive(:new).and_return(cleanup)

    delete cast_session_path(session)

    expect(response).to have_http_status(:no_content)
    expect(session.reload.state).to eq("ended")
    expect(HlsSession).to have_received(:stop).with("hls-token-stop")
  end
end