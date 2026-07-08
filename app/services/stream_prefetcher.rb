# frozen_string_literal: true

# Full per-account stream cache warmer.  Stream listings are per-RealDebrid-
# account (resolve URLs embed the RD key; Comet checks RD instant
# availability per key), so the boot CacheWarmer — which has no user key —
# can't warm them.  This service warms streams for *every* title the boot
# warmer already cached metadata for (popular + new releases ≈ 188 titles),
# not just the ones visible in a carousel, so any of them plays instantly.
#
# Triggered when a user with an RD key hits Home.  It only runs once per
# account (tracked in the user record) so returning users don't re-trigger
# it on every page load — though cached_fetch no-ops on fresh entries, so
# a redundant run would just do cheap DB reads.
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
    return if @rd_api_key.blank?

    titles = collect_cached_titles
    return if titles.empty?

    # Skip entirely if this account already has fresh stream entries for
    # most of the title set — avoids redundant work on returning users.
    fresh_ratio = fresh_ratio_for(titles.size)
    if fresh_ratio >= 0.8
      Rails.logger.info("[StreamPrefetcher] skipping: account is #{(fresh_ratio * 100).to_i}% warm")
      return
    end

    providers = StreamProvider.providers(rd_api_key: @rd_api_key)
    return if providers.empty?

    Rails.logger.info("[StreamPrefetcher] warming #{titles.size} titles (account #{(fresh_ratio * 100).to_i}% warm)")

    # Bounded concurrency: process in batches so we don't fire dozens of
    # concurrent upstream requests at once.
    titles.each_slice(MAX_CONCURRENCY) do |batch|
      threads = batch.map do |title|
        Thread.new { warm_one(title, providers) }
      end
      threads.each(&:join)
    end

    Rails.logger.info("[StreamPrefetcher] warm complete")
  rescue StandardError => e
    Rails.logger.error("[StreamPrefetcher] error: #{e.message}")
  end

  private

  # Collect every (imdb_id, type) referenced by cached catalog pages.
  # This is the full set of popular + new-release titles the boot warmer
  # prepared metadata for — typically ~188 titles.
  def collect_cached_titles
    seen = {}
    ApiCache.where("key LIKE ?", "cinemeta:catalog%").find_each do |record|
      payload = record.payload
      next unless payload.is_a?(Array)
      payload.each do |item|
        id = item["imdb_id"]
        next if id.blank? || seen.key?(id)
        seen[id] = { imdb_id: id, type: (item["type"].presence || "movie") }
      end
    end
    seen.values
  end

  def warm_one(title, providers)
    providers.each do |provider|
      # streams() returns cached data instantly when fresh; only uncached
      # titles block on Comet/Torrentio.  Language filtering is applied
      # on read, so one cached raw listing serves all language prefs.
      provider.streams(
        title[:imdb_id],
        title[:type],
        preferred_languages: @preferred_languages,
        default_language: @default_language
      )
    rescue StandardError => e
      Rails.logger.error("[StreamPrefetcher] #{provider.class} #{title[:imdb_id]}: #{e.message}")
    end
  end

  # Fraction of the title set that already has fresh stream cache entries
  # for this account (0.0 = nothing cached, 1.0 = fully warm).
  def fresh_ratio_for(total)
    return 0.0 if total.zero?
    hash = rd_key_hash
    fresh = ApiCache.where(cached_at: ApiCache::FRESH_TTL.ago..)
      .where("key LIKE ? OR key LIKE ?",
             "comet:streams:#{hash}%",
             "torrentio:streams:#{hash}%")
      .count
    [fresh.to_f / total, 1.0].min
  end

  def rd_key_hash
    return "none" if @rd_api_key.blank?
    Digest::SHA256.hexdigest(@rd_api_key)[0, 16]
  end
end