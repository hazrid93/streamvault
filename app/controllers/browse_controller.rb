# frozen_string_literal: true

# Browse movies & series with a full filter system: content type
# (movie/series), sort mode (popular / new / top rated), genre, and year.
#
# Cinemeta only exposes a single "genre" filter slot per catalog request,
# and its meaning depends on the catalog:
#   - "top" / "imdbRating" → the slot is a genre name (Action, Comedy, …)
#   - "year"                → the slot is a release year (2024, 2023, …)
# So each catalog can filter one dimension natively; the other dimension
# is applied by post-filtering the fetched results in Ruby.
class BrowseController < ApplicationController
  before_action :authenticate_user!

  # How many catalog pages to fetch when a post-filter is active, so the
  # filtered dimension still yields a useful number of titles.
  FILTER_FETCH_PAGES = 4

  def index
    @type = (params[:type].presence || "movie").to_s
    @type = "movie" unless %w[movie show].include?(@type)

    @catalog = (params[:catalog].presence || "top").to_s
    @catalog = "top" unless TorrentioService::CATALOGS.key?(@catalog)

    @genre = params[:genre].to_s
    @genre = "" unless TorrentioService.genres_for(@type).include?(@genre)

    @year = params[:year].to_s
    @year = "" unless valid_year?(@year)

    @page = (params[:page] || 1).to_i
    @page = 1 if @page < 1

    torrentio = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key)

    if @catalog == "year"
      # Native dimension = year (the genre slot holds the year).
      native_value = @year.presence || Date.today.year.to_s
      post_value = @genre
    else
      # top / imdbRating: native dimension = genre.
      native_value = @genre.presence
      post_value = @year
    end

    @post_filtering = post_value.present?

    if @post_filtering
      # Fetch several pages, then narrow by the non-native dimension so
      # the filter still returns a usable set of titles.  No server
      # pagination here — the merged, filtered set is shown in full.
      @items = []
      FILTER_FETCH_PAGES.times do |i|
        skip = i * TorrentioService::CATALOG_PAGE_SIZE
        result = torrentio.catalog(
          @type, @catalog,
          genre: native_value, skip: skip,
          limit: TorrentioService::CATALOG_PAGE_SIZE
        )
        page_items = result.success? ? result.data : []
        break if page_items.blank?
        @items.concat(page_items)
        break if page_items.size < TorrentioService::CATALOG_PAGE_SIZE
      end
      @items = @items.select { |item| matches_post_filter?(item, post_value) }
      @error = nil
      @has_next = false
      @has_prev = false
    else
      skip = (@page - 1) * TorrentioService::CATALOG_PAGE_SIZE
      result = torrentio.catalog(
        @type, @catalog,
        genre: native_value, skip: skip,
        limit: TorrentioService::CATALOG_PAGE_SIZE
      )
      @items = result.success? ? result.data : []
      @error = result.failure? ? result.error_message : nil
      # Cinemeta returns variable page sizes (the "top" catalog's first
      # page is ~46, later pages ~50) yet still has more pages, so a
      # strict size-threshold check would hide "Load more" prematurely.
      # Instead, show it whenever we got any items; the next fetch simply
      # removes the button if it comes back empty.
      @has_next = @items.any?
      @has_prev = @page > 1
    end

    @genres = TorrentioService.genres_for(@type)
    @years = (1990..Date.today.year).to_a.reverse

    respond_to do |format|
      format.html
      format.turbo_stream
    end
  end

  private

  def valid_year?(value)
    value.to_s.match?(/\A\d{4}\z/) && value.to_i.between?(1920, Date.today.year)
  end

  # Matches an item against the non-native filter dimension.  +post_value+
  # is either a genre name (when browsing the year catalog) or a year
  # (when browsing top / imdbRating).
  def matches_post_filter?(item, post_value)
    if @catalog == "year"
      # Post-filter by genre.
      genres = item[:genre].to_s.split(",").map(&:strip)
      genres.include?(post_value)
    else
      # Post-filter by year (compare the leading 4-digit year, so series
      # ranges like "2020-" still match).
      item[:year].to_s[/\A\d{4}/] == post_value
    end
  end
end