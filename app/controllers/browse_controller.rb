# frozen_string_literal: true

# Unified discovery for movies and series. With +q+, the page searches by
# title and offers type filtering. Without +q+, it browses Cinemeta catalogs
# by content type, sort mode, genre, and year.
class BrowseController < ApplicationController
  before_action :authenticate_user!

  # How many catalog pages to fetch when a post-filter is active, so the
  # filtered dimension still yields a useful number of titles.
  FILTER_FETCH_PAGES = 4
  SEARCH_PAGE_SIZE = 25
  MAX_SEARCH_PAGE_SIZE = 200

  def index
    @query = params[:q].to_s.strip
    @search_mode = @query.present?
    @page = [ params.fetch(:page, 1).to_i, 1 ].max
    torrentio = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key)

    if @search_mode
      load_search_results(torrentio)
    else
      load_catalog_results(torrentio)
    end

    respond_to do |format|
      format.html
      format.turbo_stream
    end
  end

  private

  def load_search_results(torrentio)
    @type = params[:type].presence || "all"
    @type = "all" unless %w[all movie show].include?(@type)
    @per_page = params.fetch(:per_page, SEARCH_PAGE_SIZE).to_i.clamp(1, MAX_SEARCH_PAGE_SIZE)

    result = torrentio.search(@query)
    all_items = result.success? ? result.data : []
    all_items = all_items.select { |item| item[:type] == @type } unless @type == "all"

    @error = result.failure? ? result.error_message : nil
    @total = all_items.length
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [ @total_pages, 1 ].max)
    @items = all_items.slice((@page - 1) * @per_page, @per_page) || []
    @post_filtering = false
    @has_next = false
    @has_prev = @page > 1
  end

  def load_catalog_results(torrentio)
    @type = params[:type].presence || "movie"
    @type = "movie" unless %w[movie show].include?(@type)

    @catalog = params[:catalog].presence || "top"
    @catalog = "top" unless TorrentioService::CATALOGS.key?(@catalog)

    @genre = params[:genre].to_s
    @genre = "" unless TorrentioService.genres_for(@type).include?(@genre)

    @year = params[:year].to_s
    @year = "" unless valid_year?(@year)

    if @catalog == "year"
      # The year catalog uses Cinemeta's genre slot for the year.
      native_value = @year.presence || Date.today.year.to_s
      post_value = @genre
    else
      native_value = @genre.presence
      post_value = @year
    end

    @post_filtering = post_value.present?

    if @post_filtering
      @items = FILTER_FETCH_PAGES.times.each_with_object([]) do |index, items|
        result = torrentio.catalog(
          @type, @catalog,
          genre: native_value,
          skip: index * TorrentioService::CATALOG_PAGE_SIZE,
          limit: TorrentioService::CATALOG_PAGE_SIZE
        )
        page_items = result.success? ? result.data : []
        break items if page_items.blank?

        items.concat(page_items)
        break items if page_items.size < TorrentioService::CATALOG_PAGE_SIZE
      end
      @items = @items.select { |item| matches_post_filter?(item, post_value) }
      @error = nil
      @has_next = false
      @has_prev = false
    else
      result = torrentio.catalog(
        @type, @catalog,
        genre: native_value,
        skip: (@page - 1) * TorrentioService::CATALOG_PAGE_SIZE,
        limit: TorrentioService::CATALOG_PAGE_SIZE
      )
      @items = result.success? ? result.data : []
      @error = result.failure? ? result.error_message : nil
      # Cinemeta catalog page sizes vary, so any non-empty page may have more.
      @has_next = @items.any?
      @has_prev = @page > 1
    end

    @genres = TorrentioService.genres_for(@type)
    @years = (1990..Date.today.year).to_a.reverse
  end

  def valid_year?(value)
    value.match?(/\A\d{4}\z/) && value.to_i.between?(1920, Date.today.year)
  end

  def matches_post_filter?(item, post_value)
    if @catalog == "year"
      item[:genre].to_s.split(",").map(&:strip).include?(post_value)
    else
      item[:year].to_s[/\A\d{4}/] == post_value
    end
  end
end