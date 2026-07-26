require "rails_helper"

RSpec.describe CacheWarmer do
  let(:service) { instance_double(TorrentioService) }
  let(:warmer) do
    described_class.new.tap { |instance| instance.instance_variable_set(:@service, service) }
  end

  def catalog_item(id, type)
    { "imdb_id" => id, "type" => type, "title" => id }
  end

  before do
    allow(service).to receive(:build_catalog_path) do |type, catalog, genre, skip|
      [ type, catalog, genre, skip ].compact.join(":")
    end
    allow(service).to receive(:fetch_catalog_uncached) do |path, type, _limit|
      suffix = path.include?(":50") ? "2" : (path.include?(Date.current.year.to_s) ? "3" : "1")
      imdb = type == "movie" ? "tt100000#{suffix}" : "tt200000#{suffix}"
      [ catalog_item(imdb, type) ]
    end
    allow(service).to receive(:fetch_metadata_uncached) do |imdb_id, type|
      { imdb_id: imdb_id, type: type, title: "Metadata #{imdb_id}" }
    end
  end

  it "warms distinct first/second catalog pages and only their unique metadata" do
    warmer.warm_all

    expect(ApiCache.find_by!(key: "cinemeta:catalog/movie/top///50").payload)
      .to contain_exactly(include("imdb_id" => "tt1000001"))
    expect(ApiCache.find_by!(key: "cinemeta:catalog/movie/top//50/50").payload)
      .to contain_exactly(include("imdb_id" => "tt1000002"))
    expect(ApiCache.find_by!(key: "cinemeta:catalog/series/top///50").payload)
      .to contain_exactly(include("imdb_id" => "tt2000001"))
    expect(service).to have_received(:fetch_metadata_uncached).exactly(6).times
    expect(ApiCache.where("key LIKE ?", "cinemeta:meta:%").count).to eq(6)

    # Three-hour catalog polls do not re-fetch metadata that is still within
    # its one-day freshness window.
    warmer.warm_all
    expect(service).to have_received(:fetch_metadata_uncached).exactly(6).times
  end

  it "does not crawl unrelated historical catalog rows" do
    ApiCache.upsert(
      "cinemeta:catalog/movie/search/old//50",
      [ catalog_item("tt9999999", "movie") ]
    )

    warmer.warm_all

    expect(service).not_to have_received(:fetch_metadata_uncached).with("tt9999999", anything)
    expect(ApiCache.find_by(key: "cinemeta:meta:movie/tt9999999")).to be_nil
  end

  it "preserves a good catalog when an upstream refresh is empty" do
    key = "cinemeta:catalog/movie/top///50"
    ApiCache.upsert(key, [ catalog_item("tt7654321", "movie") ])
    allow(service).to receive(:fetch_catalog_uncached).and_return([])

    warmer.warm_all

    expect(ApiCache.find_by!(key: key).payload)
      .to contain_exactly(include("imdb_id" => "tt7654321"))
  end
end
