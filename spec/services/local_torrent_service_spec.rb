# frozen_string_literal: true

require "rails_helper"

RSpec.describe LocalTorrentService do
  subject(:service) { described_class.new }

  let(:info_hash) { "0123456789abcdef0123456789abcdef01234567" }
  let(:settings) do
    {
      "CacheSize" => 64.megabytes,
      "UseDisk" => false,
      "TorrentsSavePath" => "",
      "RemoveCacheOnDrop" => false,
      "TorrentDisconnectTimeout" => 30,
      "ReaderReadAHead" => 95,
      "ResponsiveMode" => true,
      "ConnectionsLimit" => 25,
      "UploadRateLimit" => 0,
      "EnableDLNA" => false,
      "EnableBonjour" => false
    }
  end

  around do |example|
    previous = ENV["LOCAL_TORRENT_ENABLED"]
    ENV["LOCAL_TORRENT_ENABLED"] = "true"
    example.run
  ensure
    ENV["LOCAL_TORRENT_ENABLED"] = previous
  end

  before do
    stub_request(:post, "http://torrserver:8090/settings")
      .with(body: hash_including("action" => "get"))
      .to_return(status: 200, body: settings.to_json, headers: json_headers)
    stub_request(:post, "http://torrserver:8090/settings")
      .with(body: hash_including("action" => "set"))
      .to_return(status: 200)
  end

  it "rejects malformed info hashes without contacting TorrServer torrents" do
    result = service.start(info_hash: "not-a-hash")

    expect(result).to be_failure
    expect(WebMock).not_to have_requested(:post, "http://torrserver:8090/torrents")
  end

  it "adds a temporary torrent, selects the requested file, and returns an internal stream URL" do
    stub_request(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "list"))
      .to_return(status: 200, body: [].to_json, headers: json_headers)
    stub_request(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "add", "save_to_db" => false))
      .to_return(status: 200, body: { hash: info_hash }.to_json, headers: json_headers)
    stub_request(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "get", "hash" => info_hash))
      .to_return(
        status: 200,
        body: {
          hash: info_hash,
          file_stats: [
            { id: 1, path: "extras/trailer.mp4", length: 10.megabytes },
            { id: 2, path: "Movie.2026.mkv", length: 8.gigabytes }
          ]
        }.to_json,
        headers: json_headers
      )

    result = service.start(
      info_hash: info_hash,
      file_idx: 1,
      filename: "Movie.2026.mkv",
      title: "Movie",
      poster_url: "http://169.254.169.254/latest/meta-data"
    )

    expect(result).to be_success
    expect(result.data[:filename]).to eq("Movie.2026.mkv")
    expect(result.data[:streaming_url]).to eq(
      "http://torrserver:8090/stream/Movie.2026.mkv?link=#{info_hash}&index=2&play="
    )
    expect(WebMock).to have_requested(:post, "http://torrserver:8090/settings")
      .with { |request| JSON.parse(request.body).dig("sets", "CacheSize") == 10.gigabytes }
    expect(WebMock).to have_requested(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "add", "poster" => ""))
  end

  it "prevents a second local torrent from exceeding the single-stream cache budget" do
    stub_request(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "list"))
      .to_return(
        status: 200,
        body: [{ hash: "f" * 40, title: "Already playing", stat_string: "Torrent working" }].to_json,
        headers: json_headers
      )

    result = service.start(info_hash: info_hash)

    expect(result).to be_failure
    expect(result.error_message).to include("Another local torrent")
  end

  it "serializes concurrent starts so only one torrent can claim the cache" do
    active_hashes = []
    state_lock = Mutex.new
    allow_any_instance_of(described_class).to receive(:ensure_settings!).and_return(true)
    allow_any_instance_of(described_class).to receive(:list_torrents) do
      state_lock.synchronize { active_hashes.map { |hash| { "hash" => hash } } }
    end
    allow_any_instance_of(described_class).to receive(:add_torrent) do |_instance, hash, **_options|
      state_lock.synchronize { active_hashes << hash }
      sleep 0.05
    end
    allow_any_instance_of(described_class).to receive(:wait_for_metadata) do |_instance, hash|
      { "hash" => hash, "file_stats" => [{ "id" => 1, "path" => "Movie.mp4", "length" => 1.gigabyte }] }
    end

    results = ["a" * 40, "b" * 40].map do |hash|
      Thread.new { described_class.new.start(info_hash: hash, filename: "Movie.mp4") }
    end.map(&:value)

    expect(results.count(&:success?)).to eq(1)
    expect(results.count(&:failure?)).to eq(1)
    expect(active_hashes.size).to eq(1)
  end

  it "refuses to clear media while a local stream is active" do
    stub_request(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "list"))
      .to_return(
        status: 200,
        body: [{ hash: info_hash, stat_string: "Torrent working" }].to_json,
        headers: json_headers
      )

    result = service.clear!

    expect(result).to be_failure
    expect(WebMock).not_to have_requested(:post, "http://torrserver:8090/torrents")
      .with(body: hash_including("action" => "wipe"))
  end

  def json_headers
    { "Content-Type" => "application/json" }
  end
end