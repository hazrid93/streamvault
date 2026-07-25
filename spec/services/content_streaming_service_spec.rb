require 'rails_helper'

RSpec.describe ContentStreamingService do
  let(:user) { create(:user, realdebrid_api_key: "test_key_123") }
  subject(:service) { described_class.new(user) }

  around do |ex|
    ENV["STREAM_PROVIDER"] = "torrentio"
    ex.run
    ENV.delete("STREAM_PROVIDER")
  end

  before do
    # Provider work runs in threads with separate DB connections; bypass the
    # integration cache here so one example cannot leak a committed ApiCache
    # row into the next example's resolver fixtures.
    allow_any_instance_of(TorrentioService).to receive(:cached_fetch) do |_service, _key, **_options, &block|
      block.call
    end
  end

  let(:cinemeta_stub) {
    stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
      .to_return(
        status: 200,
        body: { "meta" => { "id" => "tt1375666", "name" => "Inception" } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  }

  describe "#fetch_streams" do
    it "globally groups merged provider results by RD status and seeders" do
      comet = instance_double(CometService)
      torrentio = instance_double(TorrentioService)
      allow(StreamProvider).to receive(:providers).and_return([ comet, torrentio ])
      allow(comet).to receive(:streams).and_return(ServiceResult.success([
        { title: "non-RD high", rd_plus: false, seeders: 100 },
        { title: "RD low", rd_plus: true, seeders: 3 }
      ]))
      allow(torrentio).to receive(:streams).and_return(ServiceResult.success([
        { title: "RD high", rd_plus: true, seeders: 20 },
        { title: "non-RD low", rd_plus: false, seeders: 2 }
      ]))

      result = service.send(:fetch_streams, "tt1375666", "movie")

      expect(result.data.pluck(:title)).to eq([ "RD high", "RD low", "non-RD high", "non-RD low" ])
    end
  end

  describe "#start_stream" do
    it "returns failure when RealDebrid key is missing" do
      user.update!(realdebrid_api_key: nil)
      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("RealDebrid API key not configured")
    end

    it "returns failure when no streams available" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("No streams available")
    end

    it "starts a stream and returns resolved URL" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file123/Inception.mkv")
    end

    it "skips blocked streams and tries next" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file456/Inception720.mkv")
      expect(result.data[:filename]).to eq("Inception720.mkv")
    end

    it "returns failure when all streams are blocked" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked1/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, %r{torrentio\.strem\.fun/resolve/realdebrid/test_key/blocked1/})
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("blocked")
    end

    it "skips streams with failed_infringement filenames" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/inf/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/inf/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/abc/failed_infringement_003.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/def/Inception720.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/def/Inception720.mkv")
    end

    it "skips torrentio failed_unexpected placeholder redirects" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/fail/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/fail/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/failed_unexpected_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/def/Inception720.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/def/Inception720.mkv")
    end

    it "chooses the default language before another preferred language" do
      user.update!(preferred_languages: %w[ENG FRENCH], default_language: "FRENCH")
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 2160p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/eng/null/0/InceptionENG.mkv", "behaviorHints" => { "filename" => "InceptionENG.mkv" } },
              { "title" => "Inception FRENCH 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/french/null/0/InceptionFrench.mkv", "behaviorHints" => { "filename" => "InceptionFrench.mkv" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/french/null/0/InceptionFrench.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/french/InceptionFrench.mkv" })

      result = service.start_stream("tt1375666", "movie")

      expect(result).to be_success
      expect(result.data[:filename]).to eq("InceptionFrench.mkv")
      expect(WebMock).not_to have_requested(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/eng/null/0/InceptionENG.mkv")
    end

    it "does not use streams outside the preferred languages" do
      user.update!(preferred_languages: %w[FRENCH], default_language: "FRENCH")
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception GERMAN 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/german/null/0/InceptionGerman.mkv", "behaviorHints" => { "filename" => "InceptionGerman.mkv" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.start_stream("tt1375666", "movie")

      expect(result).to be_failure
      expect(WebMock).not_to have_requested(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/german/null/0/InceptionGerman.mkv")
    end
  end

  describe "local torrent playback" do
    it "enforces local-only even when a request asks for RealDebrid" do
      local_user = create(:user, realdebrid_api_key: nil, streaming_preference: "local")
      provider = instance_double(TorrentioService)
      local_engine = instance_double(LocalTorrentService)
      allow(LocalTorrentService).to receive(:enabled?).and_return(true)
      allow(StreamProvider).to receive(:providers).and_return([provider])
      allow(provider).to receive(:streams).and_return(ServiceResult.success([
        { title: "Inception 1080p", info_hash: "a" * 40, file_idx: 0, filename: "Inception.mkv" }
      ]))
      allow(LocalTorrentService).to receive(:new).and_return(local_engine)
      allow(local_engine).to receive(:start).and_return(ServiceResult.success(
        streaming_url: "http://torrserver:8090/stream/Inception.mkv?link=#{'a' * 40}&index=1&play=",
        filename: "Inception.mkv",
        source: "local"
      ))

      result = described_class.new(local_user).start_stream("tt1375666", "movie", source_mode: "realdebrid")

      expect(result).to be_success
      expect(result.data[:source]).to eq("local")
      expect(local_engine).to have_received(:start).with(hash_including(info_hash: "a" * 40))
    end

    it "falls back locally when RealDebrid resolution fails in automatic mode" do
      user.update!(streaming_preference: "automatic")
      local_engine = instance_double(LocalTorrentService)
      allow(LocalTorrentService).to receive(:enabled?).and_return(true)
      allow(LocalTorrentService).to receive(:new).and_return(local_engine)
      allow(local_engine).to receive(:start).and_return(ServiceResult.success(
        streaming_url: "http://torrserver:8090/stream/Movie.mkv?link=#{'c' * 40}&index=1&play=",
        filename: "Movie.mkv",
        source: "local",
        info_hash: "c" * 40
      ))
      stream = { title: "Movie", info_hash: "c" * 40, file_idx: 0, filename: "Movie.mkv", resolve_url: "https://torrentio.strem.fun/resolve/fail" }
      allow(service).to receive(:fetch_streams).and_return(ServiceResult.success([stream]), ServiceResult.success([stream]))
      allow(service).to receive(:start_realdebrid_stream).and_return(ServiceResult.failure("Unauthorized RD key"))

      result = service.start_stream("tt1375666", "movie")

      expect(result).to be_success
      expect(result.data[:source]).to eq("local")
      expect(service).to have_received(:fetch_streams).twice
    end

    it "enforces RealDebrid-only even when a request asks for local" do
      user.update!(streaming_preference: "realdebrid")
      allow(LocalTorrentService).to receive(:enabled?).and_return(true)
      allow(LocalTorrentService).to receive(:new).and_call_original
      allow(service).to receive(:fetch_streams).and_return(ServiceResult.success([
        { resolve_url: "https://torrentio.strem.fun/resolve/fail", info_hash: "d" * 40 }
      ]))
      allow(service).to receive(:start_realdebrid_stream).and_return(ServiceResult.failure("Unauthorized RD key"))

      result = service.start_stream("tt1375666", "movie", source_mode: "local")

      expect(result).to be_failure
      expect(result.error_message).to eq("Unauthorized RD key")
      expect(LocalTorrentService).not_to have_received(:new)
    end

    it "resolves an explicitly selected local source without an RD resolve URL" do
      local_engine = instance_double(LocalTorrentService)
      allow(LocalTorrentService).to receive(:new).and_return(local_engine)
      allow(local_engine).to receive(:start).and_return(ServiceResult.success(
        streaming_url: "http://torrserver:8090/stream/Movie.mkv?link=#{'b' * 40}&index=1&play=",
        filename: "Movie.mkv"
      ))

      result = service.resolve_single(
        nil,
        filename: "Movie.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        source_mode: "local",
        info_hash: "b" * 40,
        file_idx: 0
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to start_with("http://torrserver:8090/")
    end
  end

  describe "#resolve_first_valid_batch" do
    it "returns a later valid resolver without waiting for an earlier slow resolver" do
      slow_candidate = { resolve_url: "https://resolver.example/slow" }
      fast_candidate = { resolve_url: "https://resolver.example/fast" }
      slow_started = Queue.new

      allow(service).to receive(:resolve_stream) do |candidate|
        if candidate == slow_candidate
          slow_started << true
          sleep 0.5
          nil
        else
          slow_started.pop
          { streaming_url: "https://download.real-debrid.com/d/fast.mp4", filename: "fast.mp4", stream: candidate }
        end
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = service.send(:resolve_first_valid_batch, [ slow_candidate, fast_candidate ])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(result).to include(filename: "fast.mp4")
      expect(elapsed).to be < 0.25
    end
  end

  describe "#resolve_single" do
    it "resolves the selected stream when it is available" do
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file123/Inception.mp4")
      expect(result.data[:filename]).to eq("Inception.mp4")
    end

    it "falls back to another candidate when the selected stream is blocked" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4", "behaviorHints" => { "filename" => "Inception720.mp4" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv",
        filename: "Inception.mkv",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file456/Inception720.mp4")
      expect(result.data[:filename]).to eq("Inception720.mp4")
    end

    it "continues fallback resolution beyond the first small batch of candidates" do
      cinemeta_stub

      streams = (1..15).map do |index|
        { "title" => "Inception ENG blocked #{index}", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked#{index}/null/0/Inception#{index}.mkv", "behaviorHints" => { "filename" => "Inception#{index}.mkv" } }
      end
      streams << { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok16/null/0/Inception720.mp4", "behaviorHints" => { "filename" => "Inception720.mp4" } }

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: { "streams" => streams }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, %r{torrentio\.strem\.fun/resolve/realdebrid/test_key/blocked\d+/})
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok16/null/0/Inception720.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file789/Inception720.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked1/null/0/Inception1.mkv",
        filename: "Inception1.mkv",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file789/Inception720.mp4")
      expect(result.data[:filename]).to eq("Inception720.mp4")
    end

    it "retries a transient resolve timeout before failing the selected stream" do
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/flaky/null/0/Inception.mp4")
        .to_timeout
        .then
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file999/Inception.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/flaky/null/0/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file999/Inception.mp4")
    end

    it "does not fetch arbitrary resolve URLs" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      result = service.resolve_single(
        "https://example.com/internal",
        filename: "internal.mp4",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_failure
      expect(WebMock).not_to have_requested(:get, "https://example.com/internal")
    end
  end
end
