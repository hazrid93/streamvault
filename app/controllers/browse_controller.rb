# frozen_string_literal: true

# Browse movies & series by category/genre with a full filter system:
# content type (movie/series), sort mode (popular / new / top rated),
# genre (action, adventure, ...), and pagination.
class BrowseController < ApplicationController
  before_action :authenticate_user!

  def index
    @type = (params[:type].presence || "movie").to_s
    @type = "movie" unless %w[movie show].include?(@type)

    @catalog = (params[:catalog].presence || "top").to_s
    @catalog = "top" unless TorrentioService::CATALOGS.key?(@catalog)

    # For the "year" catalog the genre slot holds a release year.
    year_catalog = @catalog == "year"

    if year_catalog
      @genre = (params[:genre].presence || Date.today.year.to_s).to_s
      @genre = Date.today.year.to_s unless valid_year?(@genre)
    else
      @genre = params[:genre].to_s
      @genre = "" unless TorrentioService.genres_for(@type).include?(@genre)
    end

    @page = (params[:page] || 1).to_i
    @page = 1 if @page < 1

    skip = (@page - 1) * TorrentioService::CATALOG_PAGE_SIZE

    torrentio = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key)
    result = torrentio.catalog(
      @type,
      @catalog,
      genre: (@genre.presence),
      skip: skip,
      limit: TorrentioService::CATALOG_PAGE_SIZE
    )
    @items = result.success? ? result.data : []
    @error = result.failure? ? result.error_message : nil

    # A full page means cinemeta very likely has another page behind it.
    @has_next = @items.size >= TorrentioService::CATALOG_PAGE_SIZE
    @has_prev = @page > 1

    @genres = TorrentioService.genres_for(@type)
    @years = (1990..Date.today.year).to_a.reverse
  end

  private

  def valid_year?(value)
    value.to_s.match?(/\A\d{4}\z/) && value.to_i.between?(1920, Date.today.year)
  end
end