# frozen_string_literal: true

# Pre-warms and refreshes the ApiCache table for high-traffic content.
# Called on boot and every REWARM_INTERVAL by the cache_warmer initializer.
# All work is wrapped so one failing slice never aborts the rest.
#
# Crawl scope (bounded to limit upstream load):
#   - popular: top 100 movies + top 100 series (cinemeta "top", 2 pages)
#   - new releases: top 100 for the current year (cinemeta "year")
#   - title metadata for every title surfaced above
#
# This warmer BYPASSES the cache-read path (it calls the *_uncached
# fetchers directly and upserts), so a periodic re-warm actually refreshes
# entries instead of short-circuiting on the fresh cache it just built.
# The advisory lock in Cacheable still applies to per-request refreshes;
# here we upsert directly (idempotent), so no lock is needed.
#
# Stream listings are per-RealDebrid-account, so they are NOT warmed
# here — they cache on first play per user via stale-while-revalidate.
class CacheWarmer
  PAGE_SIZE = TorrentioService::CATALOG_PAGE_SIZE

  # How often the periodic re-warm loop runs.  Entries are considered
  # stale after ApiCache::FRESH_TTL (1 day), so re-warming every 3 hours
  # keeps the hot set fresh well before staleness kicks in, re-fetches
  # existing entries (re-check), and catches new popular/new-release
  # titles promptly as catalogs shift.
  REWARM_INTERVAL = 3.hours

  def initialize
    @service = TorrentioService.new
  end

  def warm_all
    warm_catalogs
    warm_metadata_for_cached_titles
  end

  private

  # Warm the catalog pages (popular + new releases) for both types.
  # Calls the uncached fetcher + upserts directly so a re-warm refreshes
  # the entry instead of reading the fresh cache and no-opping.
  def warm_catalogs
    this_year = Date.today.year

    %w[movie show].each do |type|
      cinemeta_type = type == "show" ? "series" : type

      # Popular: 2 pages × PAGE_SIZE ≈ top 100.
      2.times do |i|
        skip = i * PAGE_SIZE
        key = "cinemeta:catalog/#{cinemeta_type}/top///#{PAGE_SIZE}"
        warm_slice(key) do
          path = @service.build_catalog_path(cinemeta_type, "top", nil, skip)
          @service.fetch_catalog_uncached(path, type, PAGE_SIZE)
        end
      end

      # New releases for the current year (1 page ≈ top 100 by recency).
      key = "cinemeta:catalog/#{cinemeta_type}/year/#{this_year}//#{PAGE_SIZE}"
      warm_slice(key) do
        path = @service.build_catalog_path(cinemeta_type, "year", this_year.to_s, nil)
        @service.fetch_catalog_uncached(path, type, PAGE_SIZE)
      end
    end
  end

  # Walk every cached catalog page and warm/refresh title metadata for
  # each imdb_id it references.
  def warm_metadata_for_cached_titles
    imdb_ids = collect_imdb_ids_from_catalogs
    Rails.logger.info("[CacheWarmer] warming metadata for #{imdb_ids.size} titles")

    imdb_ids.each do |imdb_id, type|
      cinemeta_type = type == "show" ? "series" : type
      key = "cinemeta:meta:#{cinemeta_type}/#{imdb_id}"
      warm_slice(key) do
        @service.fetch_metadata_uncached(imdb_id, type)
      end
    end
  end

  # Scan cached catalog payloads for imdb_ids and their content type.
  def collect_imdb_ids_from_catalogs
    seen = {}
    ApiCache.where("key LIKE ?", "cinemeta:catalog/%").find_each do |record|
      payload = record.payload
      next unless payload.is_a?(Array)
      payload.each do |item|
        id = item["imdb_id"]
        seen[id] = item["type"] if id.present?
      end
    end
    seen
  end

  # Fetch + upsert one slice, isolating failures.  nil payloads (fetch
  # errors) are intentionally not stored so a transient outage doesn't
  # clobber a previously-good cache entry with an empty/error result.
  def warm_slice(key)
    payload = yield
    ApiCache.upsert(key, payload) unless payload.nil?
  rescue StandardError => e
    Rails.logger.error("[CacheWarmer] slice failed for #{key}: #{e.message}")
  end
end