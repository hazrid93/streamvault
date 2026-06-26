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
    @recently_added = policy_scope(LibraryEntry).where("created_at > ?", 2.weeks.ago).recently_added.limit(20)
    @wishlist_preview = policy_scope(WishlistEntry).recently_added.limit(20)
    @popular = torrentio.popular("movie", limit: 20)
    @popular_shows = torrentio.popular("show", limit: 20)
    @trending = torrentio.trending("movie", limit: 20)
    @trending_shows = torrentio.trending("show", limit: 20)
  end

  private

  def fetch_continue_watching
    result = ProgressTrackingService.continue_watching(current_user)
    result.success? ? result.data : []
  end
end
