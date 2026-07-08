# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    torrentio = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key)
    @recommendations = ServiceResult.success(
      policy_scope(Recommendation).ordered.limit(20).map { |r|
        { tmdb_id: r.tmdb_id, imdb_id: r.imdb_id, title: r.title, poster_url: r.poster_url, type: r.content_type, year: r.year }
      }
    )
    @continue_watching = fetch_continue_watching
    @up_next = fetch_up_next
    @recently_added = policy_scope(LibraryEntry).where("created_at > ?", 2.weeks.ago).recently_added.limit(20)
    @wishlist_preview = policy_scope(WishlistEntry).recently_added.limit(20)
    # Run the four catalog calls concurrently so a slow cinemeta
    # round-trip doesn't block the others (each has its own timeout).
    popular_thread = Thread.new { torrentio.popular("movie", limit: 20) }
    popular_shows_thread = Thread.new { torrentio.popular("show", limit: 20) }
    trending_thread = Thread.new { torrentio.trending("movie", limit: 20) }
    trending_shows_thread = Thread.new { torrentio.trending("show", limit: 20) }
    @popular = popular_thread.value
    @popular_shows = popular_shows_thread.value
    @trending = trending_thread.value
    @trending_shows = trending_shows_thread.value

    # Prefetch stream listings for the visible carousel titles in the
    # background so opening any of them is instant.  Fire-and-forget:
    # cached_fetch no-ops on already-cached titles, so this is cheap for
    # returning users and only hits Comet/Torrentio for new titles.
    prefetch_visible_streams
  end

  private

  # Warm per-account stream cache for ALL cached catalog titles (not
  # just the visible carousel subset), so any popular/new-release title
  # plays instantly.  Runs once per account: only triggers when the
  # account's stream cache is cold or older than the stream TTL, so
  # returning users don't re-trigger it on every Home load.
  def prefetch_visible_streams
    return unless current_user.has_realdebrid_key?

    # Only warm if never warmed or the last warm is older than the
    # stream cache freshness window (so fresh entries get refreshed).
    return if current_user.streams_warmed_at.present? &&
               current_user.streams_warmed_at > ApiCache::FRESH_TTL.ago

    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        StreamPrefetcher.new(
          rd_api_key: current_user.realdebrid_api_key,
          preferred_languages: current_user.preferred_stream_languages,
          default_language: current_user.default_stream_language
        ).warm_all
        current_user.update_column(:streams_warmed_at, Time.current)
      end
    rescue StandardError => e
      Rails.logger.error("[HomeController] stream prefetch error: #{e.message}")
    end
  end

  def fetch_up_next
    result = UpNextService.new(rd_api_key: current_user.realdebrid_api_key).call(current_user)
    result.success? ? result.data : []
  end

  def fetch_continue_watching
    result = ProgressTrackingService.continue_watching(current_user)
    result.success? ? result.data : []
  end
end
