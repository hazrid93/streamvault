# frozen_string_literal: true

# Pre-warms the ApiCache table for high-traffic content.  Called by
# CacheWarmerJob on boot (and can be invoked manually).  All work is
# wrapped so one failing slice never aborts the rest.
#
# Crawl scope (bounded to limit upstream load):
#   - popular: top 100 movies + top 100 series (cinemeta "top", 2 pages)
#   - new releases: top 100 for the current year (cinemeta "year")
#   - title metadata for every title surfaced above
#
# Stream listings are per-RealDebrid-account, so they are NOT warmed
# here — they cache on first play per user via stale-while-revalidate.
class CacheWarmer
  PAGE_SIZE = TorrentioService::CATALOG_PAGE_SIZE

  def initialize
    @service = TorrentioService.new
  end

  def warm_all
    warm_catalogs
    warm_metadata_for_cached_titles
  end

  private

  # Warm the catalog pages (popular + new releases) for both types.
  def warm_catalogs
    this_year = Date.today.year

    %w[movie show].each do |type|
      # Popular: 2 pages × PAGE_SIZE ≈ top 100.
      2.times do |i|
        warm_slice { @service.catalog(type, "top", skip: i * PAGE_SIZE, limit: PAGE_SIZE) }
      end

      # New releases for the current year (1 page ≈ top 100 by recency).
      warm_slice { @service.catalog(type, "year", genre: this_year.to_s, limit: PAGE_SIZE) }
    end
  end

  # Walk every cached catalog page and warm title metadata for each
  # imdb_id it references.  Metadata fetches are themselves cached, so
  # this only hits cinemeta for titles not yet stored.
  def warm_metadata_for_cached_titles
    imdb_ids = collect_imdb_ids_from_catalogs
    Rails.logger.info("[CacheWarmer] warming metadata for #{imdb_ids.size} titles")

    # Cinemeta doesn't need the type (it resolves by id), but the
    # metadata() call uses it to pick series vs movie normalisation —
    # infer from the cache key's type segment.
    imdb_ids.each do |imdb_id, type|
      warm_slice { @service.metadata(imdb_id, type) }
    end
  end

  # Scan cached catalog keys for imdb_ids and their content type.
  def collect_imdb_ids_from_catalogs
    seen = {}
    ApiCache.where("key LIKE ?", "cinemeta:catalog/%").find_each do |record|
      payload = record.payload
      next unless payload.is_a?(Array)
      payload.each do |item|
        id = item["imdb_id"]
        # The item's type was normalised to "show"/"movie"; cinemeta
        # metadata() accepts both, defaulting to the stored type.
        seen[id] = item["type"] if id.present?
      end
    end
    seen
  end

  # Run a warming slice, isolating failures so one bad request doesn't
  # abort the whole crawl.
  def warm_slice
    yield
  rescue StandardError => e
    Rails.logger.error("[CacheWarmer] slice failed: #{e.message}")
  end
end