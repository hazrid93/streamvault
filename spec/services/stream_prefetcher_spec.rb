require "rails_helper"

RSpec.describe StreamPrefetcher do
  before do
    provider_class = Class.new do
      const_set(:STREAMS_CACHE_TTL, 1.hour)

      attr_reader :calls, :maximum_concurrency

      def initialize
        @calls = []
        @mutex = Mutex.new
        @active = 0
        @maximum_concurrency = 0
      end

      def stream_cache_key(imdb_id, type, season: nil, episode: nil)
        "fake:streams:v1:account/#{imdb_id}/#{type}/#{season}/#{episode}"
      end

      def fetch_streams_uncached(imdb_id, type, season: nil, episode: nil)
        @mutex.synchronize do
          @calls << [ imdb_id, type ]
          @active += 1
          @maximum_concurrency = [ @maximum_concurrency, @active ].max
        end
        sleep 0.02
        [ { name: imdb_id, url: "https://example.com/#{imdb_id}" } ]
      ensure
        @mutex.synchronize { @active -= 1 }
      end
    end
    stub_const("CacheWarmTestProvider", provider_class)
    @provider = CacheWarmTestProvider.new
    allow(StreamProvider).to receive(:providers).and_return([ @provider ])
  end

  def cache_catalog(items)
    ApiCache.upsert("cinemeta:catalog/movie/top///50", items)
  end

  it "warms only useful movie keys with bounded real upstream concurrency" do
    movies = 8.times.map do |index|
      { "imdb_id" => "tt300000#{index}", "type" => "movie" }
    end
    cache_catalog(movies + [ { "imdb_id" => "tt4000000", "type" => "show" } ])
    ApiCache.upsert(
      "cinemeta:catalog/movie/search/old//50",
      [ { "imdb_id" => "tt9999999", "type" => "movie" } ]
    )

    result = described_class.new(rd_api_key: "rd-key").warm_all

    expect(result).to be(true)
    expect(@provider.calls.map(&:first)).to match_array(movies.pluck("imdb_id"))
    expect(@provider.calls.map(&:first)).not_to include("tt9999999")
    expect(@provider.maximum_concurrency).to be_between(2, described_class::MAX_CONCURRENCY)
    expect(ApiCache.where("key LIKE ?", "fake:streams:%").count).to eq(8)
  end

  it "reports a complete upstream outage instead of claiming a daily success" do
    cache_catalog([ { "imdb_id" => "tt6000000", "type" => "movie" } ])
    allow(@provider).to receive(:fetch_streams_uncached).and_return(nil)

    expect(described_class.new(rd_api_key: "rd-key").warm_all).to be(false)
  end

  it "uses exact versioned provider keys to skip an already warm account" do
    movies = 5.times.map do |index|
      { "imdb_id" => "tt500000#{index}", "type" => "movie" }
    end
    cache_catalog(movies)
    movies.each do |movie|
      key = @provider.stream_cache_key(movie["imdb_id"], "movie")
      ApiCache.upsert(key, [ { name: movie["imdb_id"] } ])
    end

    expect(described_class.new(rd_api_key: "rd-key").warm_all).to be(true)
    expect(@provider.calls).to be_empty
  end
end
