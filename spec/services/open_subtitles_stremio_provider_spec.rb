require "rails_helper"

RSpec.describe OpenSubtitlesStremioProvider do
  let(:search_connection) { instance_double(Faraday::Connection) }
  let(:download_connection) { instance_double(Faraday::Connection) }
  let(:provider) { described_class.new(search_connection: search_connection, download_connection: download_connection) }

  before do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  after do
    Rails.cache = @original_cache
  end

  it "returns preferred-language tracks from the official Stremio add-on" do
    allow(search_connection).to receive(:get).with("subtitles/movie/tt0433035.json").and_return(
      instance_double(Faraday::Response, success?: true, body: {
        "subtitles" => [
          { "id" => "1", "lang" => "spa", "url" => "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/1" },
          { "id" => "2", "lang" => "eng", "url" => "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/2" },
          { "id" => "3", "lang" => "eng", "url" => "http://127.0.0.1/subtitle.srt" }
        ]
      })
    )

    tracks = provider.search(
      imdb_id: "tt0433035", type: "movie", default_language: "ENG",
      preferred_languages: [ "SPANISH" ]
    )

    expect(tracks.pluck(:language)).to eq([ "ENG", "SPANISH" ])
    expect(tracks.first[:index]).to start_with("external:opensubtitles:")
    expect(tracks).to all(include(external: true, text_supported: true, source: "opensubtitles"))
  end

  it "uses the Stremio series identifier with season and episode" do
    allow(search_connection).to receive(:get).with("subtitles/series/tt0903747:2:3.json").and_return(
      instance_double(Faraday::Response, success?: true, body: { "subtitles" => [] })
    )

    expect(provider.search(imdb_id: "tt0903747", type: "series", season: 2, episode: 3)).to eq([])
  end

  it "downloads only allowlisted HTTPS Stremio subtitle URLs" do
    url = "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/1953000446"
    allow(download_connection).to receive(:get).with(url).and_return(
      instance_double(Faraday::Response, success?: true, body: "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    )

    expect(provider.download(url)).to be_success
    expect(provider.download("http://127.0.0.1/private.srt")).to be_failure
    expect(provider.download("https://subs5.strem.io.evil.test/en/download/file")).to be_failure
  end
end
