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

  # Atomically enqueue one durable per-account warm. The job, not the Puma
  # request, owns provider concurrency and completion bookkeeping.
  def prefetch_visible_streams
    StreamPrefetchJob.enqueue_for(current_user)
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
