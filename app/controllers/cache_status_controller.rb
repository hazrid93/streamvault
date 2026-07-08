# frozen_string_literal: true

# Dashboard showing the full state of the caching subsystem:
#   - ApiCache breakdown by type (catalogs, metadata, streams, ratings,
#     TMDB) with fresh/stale/error counts and DB footprint
#   - CacheWarmer boot + periodic-loop status (state, last run, next ETA,
#     thread liveness, errors)
#   - Crawler coverage (titles discovered vs metadata warmed)
#   - Per-account stream prefetch status (StreamPrefetcher)
#
# Read-only — just queries the ApiCache table and the in-memory warmer
# status registry.  Authenticated users only (this is a self-hosted
# single-operator deployment).
class CacheStatusController < ApplicationController
  before_action :authenticate_user!

  def show
    @cache_breakdown = build_cache_breakdown
    @cache_totals    = build_cache_totals
    @warmer_status   = build_warmer_status
    @crawler_status  = build_crawler_status
    @stream_status   = build_stream_status
  end

  private

  # ---- ApiCache breakdown -------------------------------------------------

  def build_cache_breakdown
    rows = ApiCache.all.to_a
    groups = rows.group_by { |r| bucket_for(r.key) }

    groups.map do |bucket, recs|
      {
        bucket: bucket,
        total: recs.size,
        fresh: recs.count { |r| r.fresh? },
        stale: recs.count { |r| !r.fresh? },
        fetching: recs.count { |r| r.fetching },
        errors: recs.count { |r| r.fetch_error.present? },
        bytes: recs.sum { |r| r.payload.to_json.bytesize rescue 0 },
        newest: recs.map(&:cached_at).compact.max,
        oldest: recs.map(&:cached_at).compact.min
      }
    end.sort_by { |h| -h[:total] }
  end

  def build_cache_totals
    rows = ApiCache.all.to_a
    {
      total: rows.size,
      fresh: rows.count { |r| r.fresh? },
      stale: rows.count { |r| !r.fresh? },
      fetching: rows.count { |r| r.fetching },
      errors: rows.count { |r| r.fetch_error.present? },
      bytes: rows.sum { |r| r.payload.to_json.bytesize rescue 0 },
      oldest: rows.map(&:cached_at).compact.min,
      newest: rows.map(&:cached_at).compact.max
    }
  end

  # Map a cache key to a human bucket label.
  def bucket_for(key)
    parts = key.split(":")
    case parts[0]
    when "cinemeta"
      case parts[1]
      when "catalog" then "Catalog pages"
      when "meta"    then "Title metadata"
      when "search"  then "Search results"
      else "Cinemeta (other)"
      end
    when "comet"      then "Comet streams (per-account)"
    when "torrentio"  then "Torrentio streams (per-account)"
    when "omdb"       then "OMDb ratings"
    when "tmdb"       then "TMDB (recs/filmography)"
    else parts[0] || "unknown"
    end
  end

  # ---- Warmer status ------------------------------------------------------

  def build_warmer_status
    s = CacheWarmer.status.with_indifferent_access
    alive = CacheWarmer.threads_alive?

    boot = s[:boot] || {}
    periodic = s[:periodic] || {}

    {
      rewarm_interval: CacheWarmer::REWARM_INTERVAL,
      boot: {
        state: boot[:state],
        started_at: boot[:started_at],
        finished_at: boot[:finished_at],
        duration_ms: boot[:duration_ms],
        error: boot[:error],
        thread_alive: alive[:boot]
      },
      periodic: {
        state: periodic[:state],
        last_started_at: periodic[:last_started_at],
        last_finished_at: periodic[:last_finished_at],
        duration_ms: periodic[:duration_ms],
        next_run_at: periodic[:next_run_at],
        runs: periodic[:runs],
        error: periodic[:error],
        thread_alive: alive[:periodic]
      }
    }
  end

  # ---- Crawler coverage ---------------------------------------------------
  # What the warmer crawls: catalog titles discovered vs metadata warmed.

  def build_crawler_status
    catalog_rows = ApiCache.where("key LIKE ?", "cinemeta:catalog/%").to_a
    imdb_ids = []
    catalog_rows.each do |r|
      next unless r.payload.is_a?(Array)
      r.payload.each { |item| imdb_ids << item["imdb_id"] if item["imdb_id"].present? }
    end
    unique = imdb_ids.uniq

    meta_rows = ApiCache.where("key LIKE ?", "cinemeta:meta:%").to_a
    warmed_ids = meta_rows.map { |r| r.key.split("/").last }.compact.uniq

    covered = unique.count { |id| warmed_ids.include?(id) }

    {
      catalog_pages: catalog_rows.size,
      titles_discovered: unique.size,
      metadata_warmed: warmed_ids.size,
      coverage_pct: unique.empty? ? 0 : (covered.to_f / unique.size * 100).round(1),
      missing: unique.size - covered
    }
  end

  # ---- Per-account stream prefetch ---------------------------------------

  def build_stream_status
    users = User.where.not(realdebrid_api_key: [nil, ""]).to_a
    users.map do |u|
      hash = Digest::SHA256.hexdigest(u.realdebrid_api_key)[0, 16]
      comet = ApiCache.where("key LIKE ?", "comet:streams:#{hash}%").count
      torrentio = ApiCache.where("key LIKE ?", "torrentio:streams:#{hash}%").count
      total_titles = build_crawler_status[:titles_discovered]
      {
        email: u.email,
        warmed_at: u.streams_warmed_at,
        comet_cached: comet,
        torrentio_cached: torrentio,
        coverage_pct: total_titles.zero? ? 0 : (comet.to_f / total_titles * 100).round(1)
      }
    end.sort_by { |h| -h[:comet_cached] }
  end
end