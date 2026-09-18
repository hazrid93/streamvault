require 'rails_helper'

RSpec.describe "Content", type: :request do
  let(:user) { create(:user) }

  around do |ex|
    ENV["STREAM_PROVIDER"] = "torrentio"
    ex.run
    ENV.delete("STREAM_PROVIDER")
  end
  describe "GET /content/:type/:imdb_id" do
    context "when not authenticated" do
      it "redirects to login" do
        get content_path(type: "movie", imdb_id: "tt1375666")
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "year" => "2010" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
          .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get content_path(type: "movie", imdb_id: "tt1375666")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("stream-resolve-loading")
        expect(response.body).to include("Finding a working stream")
        expect(response.body).to include('data-controller="stream-loading"')
        expect(response.body).to include("stream_provider_torrentio_movie")
        expect(response.body).to include("SEARCHING")
        expect(WebMock).not_to have_requested(:get, %r{torrentio\.strem\.fun/.*/stream/movie/tt1375666\.json})
      end

      it "rejects an invalid imdb_id format (SEC-09)" do
        get content_path(type: "movie", imdb_id: "not_an_imdb_id")
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("Invalid content ID.")
      end

      it "rejects an invalid type format (SEC-09)" do
        get content_path(type: "invalid", imdb_id: "tt1375666")
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("Invalid content type.")
      end
    end
  end

  describe "GET /content/:type/:imdb_id/status" do
    let(:other_user) { create(:user) }

    before { sign_in user }

    it "returns JSON with library and wishlist status for the current user" do
      library_entry = create(:library_entry, user: user, imdb_id: "tt1375666")
      wishlist_entry = create(:wishlist_entry, user: user, imdb_id: "tt1375666")

      get content_status_path(type: "movie", imdb_id: "tt1375666")
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      body = response.parsed_body
      expect(body["in_library"]).to be true
      expect(body["in_wishlist"]).to be true
      expect(body["library_entry_id"]).to eq(library_entry.id)
      expect(body["wishlist_entry_id"]).to eq(wishlist_entry.id)
    end

    it "scopes to the current user (IDOR — other user's entries are not visible)" do
      create(:library_entry, user: other_user, imdb_id: "tt1375666")
      create(:wishlist_entry, user: other_user, imdb_id: "tt1375666")

      get content_status_path(type: "movie", imdb_id: "tt1375666")
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["in_library"]).to be false
      expect(body["in_wishlist"]).to be false
    end

    it "rejects an invalid imdb_id" do
      get content_status_path(type: "movie", imdb_id: "not_an_imdb_id")
      expect(response).to redirect_to(root_path)
    end

    it "rejects an invalid imdb_id with JSON 400" do
      get content_status_path(type: "movie", imdb_id: "not_an_imdb_id"),
          headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /content/:type/:imdb_id/stream_results/:provider" do
    before { sign_in user }

    it "returns one provider's streams in its Turbo frame" do
      stub_request(:get, %r{torrentio\.strem\.fun/stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: { streams: [ { title: "Inception 1080p 👤 42", infoHash: "a" * 40, fileIdx: 0, behaviorHints: { filename: "Inception.mkv" } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      get content_stream_results_path(type: "movie", imdb_id: "tt1375666", provider: "torrentio", title: "Inception")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="stream_provider_torrentio_movie"')
      expect(response.body).to include("Inception 1080p")
      expect(response.body).to include("Stream info")
      expect(response.body).to include("Reported seeders")
    end

    it "replaces an unknown provider frame with a visible error" do
      get content_stream_results_path(type: "movie", imdb_id: "tt1375666", provider: "unknown")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This stream provider is not configured")
      expect(response.body).to include('id="stream_provider_unknown_movie"')
    end

    it "shows a provider timeout without repeating the slow request for local mode" do
      user.update!(realdebrid_api_key: "test-rd-key", streaming_preference: "automatic")
      provider = instance_double(CometService)
      allow(provider).to receive(:streams)
        .and_return(ServiceResult.failure("Comet took too long to respond. Please try again."))
      allow(StreamProvider).to receive(:provider).and_return(
        { id: "comet", label: "Comet", service: provider }
      )
      allow(LocalTorrentService).to receive(:enabled?).and_return(true)

      get content_stream_results_path(type: "movie", imdb_id: "tt1375666", provider: "comet")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Comet took too long to respond")
      expect(provider).to have_received(:streams).once
    end

    it "retries keyless when the saved RD key has no active subscription" do
      user.update!(realdebrid_api_key: "test-rd-key", streaming_preference: "automatic")
      original_comet_url = ENV["COMET_URL"]
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "http://comet.example.com"
      allow(LocalTorrentService).to receive(:enabled?).and_return(true)

      # Keyed request: Comet answers with a single "No active subscription"
      # notice. Keyless request: the full torrent list.
      stub_request(:get, %r{comet\.example\.com/[^/]+/stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: { "streams" => [ {
            "name" => "[❌] realdebrid",
            "description" => "realdebrid: No active subscription.\nPlease renew your debrid account.",
            "url" => "https://comet.feels.legal"
          } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, %r{comet\.example\.com/stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: { "streams" => [ {
            "name" => "[⬇️] Comet 1080p",
            "description" => "📄 Inception 2010 1080p BluRay x264-YTS.mkv\n👤 24 💾 1.8 GB 🔎 Torrents.csv",
            "behaviorHints" => {
              "bingeGroup" => "comet|realdebrid|#{'a' * 40}",
              "filename" => "Inception 2010 1080p BluRay x264-YTS.mkv",
              "videoSize" => 1_932_735_283
            }
          } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      begin
        get content_stream_results_path(type: "movie", imdb_id: "tt1375666", provider: "comet", title: "Inception")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Inception 2010 1080p")
        expect(response.body).to include("no active subscription")
        expect(response.body).not_to include("[❌] realdebrid")
        expect(WebMock).to(have_requested(:get, %r{comet\.example\.com/stream/movie/tt1375666\.json}))
      ensure
        ENV["COMET_URL"] = original_comet_url
      end
    end
  end

  describe "GET /content/:type/:imdb_id/episode_streams" do
    before { sign_in user }

    it "rejects an invalid imdb_id (SEC-09)" do
      get episode_streams_path(type: "show", imdb_id: "not_an_imdb_id", season: 1, episode: 1)
      expect(response).to redirect_to(root_path)
    end
  end
end
