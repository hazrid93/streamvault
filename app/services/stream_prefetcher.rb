# frozen_string_literal: true

# Full per-account stream cache warmer.  Stream listings are per-RealDebrid-
# account (resolve URLs embed the RD key; Comet checks RD instant
# availability per key), so the boot CacheWarmer — which has no user key —
# can't warm them. This service warms movie streams from the bounded
# popular/new-release catalog set, not just the visible carousel. Shows are
# skipped because their playable cache keys require a season and episode.
#
# Triggered when a user with an RD key hits Home.  It only runs once per
# account (tracked in the user record) so returning users don't re-trigger
# it on every page load. Only movies are prefetched: a show's root IMDb ID
# cannot warm the season/episode-specific key used during playback.
class StreamPrefetcher
  # Max concurrent title fetches (each may hit Comet + Torrentio).
  MAX_CONCURRENCY = 6

  def initialize(rd_api_key:, preferred_languages: nil, default_language: nil)
    @rd_api_key = rd_api_key
    @preferred_languages = preferred_languages
    @default_language = default_language
  end

  # Warm streams for all cached catalog titles for this account.  Skips
  # titles already freshly cached (cheap DB read), so only genuinely
  # uncached titles trigger Comet/Torrentio requests.
  def warm_all
    return false if @rd_api_key.blank?

    titles = collect_cached_titles
    return false if titles.empty?

    providers = StreamProvider.providers(rd_api_key: @rd_api_key)
    return false if providers.empty?

    # Skip entirely if this account already has fresh stream entries for
    # most provider/title pairs — avoids redundant upstream work.
    fresh_ratio = fresh_ratio_for(titles, providers)
    if fresh_ratio >= 0.8
      Rails.logger.info("[StreamPrefetcher] skipping: account is #{(fresh_ratio * 100).to_i}% warm")
      return true
    end

    Rails.logger.info("[StreamPrefetcher] warming #{titles.size} titles (account #{(fresh_ratio * 100).to_i}% warm)")

    # Bounded concurrency: process in batches so we don't fire dozens of
    # concurrent upstream requests at once.
    outcomes = []
    titles.each_slice(MAX_CONCURRENCY) do |batch|
      threads = batch.map do |title|
        Thread.new { warm_one(title, providers) }
      end
      outcomes.concat(threads.map(&:value).flatten)
    end

    if outcomes.none?(true)
      Rails.logger.error("[StreamPrefetcher] warm failed: every provider request failed")
      return false
    end

    failures = outcomes.count(false)
    Rails.logger.warn("[StreamPrefetcher] warm complete with #{failures} failed slices") if failures.positive?
    Rails.logger.info("[StreamPrefetcher] warm complete")
    true
  rescue StandardError => e
    Rails.logger.error("[StreamPrefetcher] error: #{e.message}")
    false
  end

  private

  # Collect every (imdb_id, type) referenced by cached catalog pages.
  # This is the full set of popular + new-release titles the boot warmer
  # prepared metadata for — typically ~188 titles.
  def collect_cached_titles
    seen = {}
    keys = CacheWarmer.catalog_slices.filter_map { |slice| slice[:key] if slice[:type] == "movie" }
    ApiCache.where(key: keys).find_each do |record|
      payload = record.payload
      next unless payload.is_a?(Array)
      payload.each do |item|
        id = item["imdb_id"]
        type = item["type"].presence || "movie"
        next if id.blank? || seen.key?(id) || type != "movie"

        seen[id] = { imdb_id: id, type: type }
      end
    end
    seen.values
  end

  def warm_one(title, providers)
    providers.map do |provider|
      key = provider.stream_cache_key(title[:imdb_id], title[:type])
      record = ApiCache.find_by(key: key)
      next true if record&.fresh?(provider.class::STREAMS_CACHE_TTL)

      # Bypass cached_fetch for stale entries. Calling #streams here would
      # serve stale and spawn a second detached refresh thread, defeating the
      # six-request concurrency bound across hundreds of titles.
      payload = provider.fetch_streams_uncached(title[:imdb_id], title[:type])
      next false if payload.nil?

      ApiCache.upsert(key, payload)
      true
    rescue StandardError => e
      Rails.logger.error("[StreamPrefetcher] #{provider.class} #{title[:imdb_id]}: #{e.message}")
      false
    end
  end

  # Fraction of the title set that already has fresh stream cache entries
  # for this account (0.0 = nothing cached, 1.0 = fully warm).
  def fresh_ratio_for(titles, providers)
    pairs = providers.product(titles).map do |provider, title|
      [ provider, provider.stream_cache_key(title[:imdb_id], title[:type]) ]
    end
    return 0.0 if pairs.empty?

    records = ApiCache.where(key: pairs.map(&:last)).index_by(&:key)
    fresh = pairs.count do |provider, key|
      records[key]&.fresh?(provider.class::STREAMS_CACHE_TTL)
    end
    fresh.to_f / pairs.size
  end
end
