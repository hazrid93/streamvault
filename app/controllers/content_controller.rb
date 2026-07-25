# frozen_string_literal: true

class ContentController < ApplicationController
  include ContentParamValidation
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)

    meta_result = torrentio.metadata(@imdb_id, @type)
    @metadata = meta_result.success? ? meta_result.data : nil

    # Stream providers load independently in Turbo frames after the detail page
    # renders, so a slow provider never blocks navigation or a faster result.
    @stream_providers = StreamProvider.provider_entries(rd_api_key: current_user.realdebrid_api_key)

    @library_entry = current_user.library_entries.find_by(imdb_id: @imdb_id)
    @wishlist_entry = current_user.wishlist_entries.find_by(imdb_id: @imdb_id)
    @in_library = @library_entry.present?
    @in_wishlist = @wishlist_entry.present?

    if @type == "show"
      @episode_progress = current_user.episode_progresses.for_show(@imdb_id).index_by { |ep| [ ep.season_number, ep.episode_number ] }
      @selected_season = params[:season]&.to_i || 1
      # Show progress = last watched episode (ordered by watched_at so
      # the result is deterministic — find_by without ORDER BY returns
      # whichever row the DB happens to find first).
      @progress = current_user.watch_history_entries
        .where(show_imdb_id: @imdb_id, content_type: :episode)
        .order(watched_at: :desc).first&.progress_percentage
    else
      # Movie progress
      @progress = current_user.watch_history_entries
        .find_by(imdb_id: @imdb_id, content_type: :movie)
        &.progress_percentage
    end

    # Recommendations also load after first paint through a lazy Turbo frame.
    # They are optional and should never delay opening a title.

    # Prefetch stream listings in the background so the next title the
    # user opens is instant.  Triggers a full per-account warm (once per
    # TTL) rather than just the similar titles.
    prefetch_stream_cache
  end

  def status
    imdb_id = params[:imdb_id]
    type = params[:type]
    return if reject_invalid_imdb_id!(imdb_id) || reject_invalid_content_type!(type)

    library_entry = current_user.library_entries.find_by(imdb_id: imdb_id)
    wishlist_entry = current_user.wishlist_entries.find_by(imdb_id: imdb_id)

    render json: {
      in_library: library_entry.present?,
      in_wishlist: wishlist_entry.present?,
      library_entry_id: library_entry&.id,
      wishlist_entry_id: wishlist_entry&.id
    }
  end

  def episode_streams
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]&.to_i
    @episode = params[:episode]&.to_i

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)

    meta = torrentio.metadata(@imdb_id, @type)
    @show_title = meta.success? ? meta.data[:title] : @imdb_id
    @poster_url = meta.success? ? meta.data[:poster_url] : nil
    @episode_title = ""
    @episode_duration_seconds = nil
    if meta.success? && meta.data[:episodes]
      ep = meta.data[:episodes].find { |e| e[:season] == @season && e[:episode] == @episode }
      @episode_title = ep&.dig(:title).to_s
      @episode_duration_seconds = ep&.dig(:runtime_seconds)
    end

    @stream_providers = StreamProvider.provider_entries(rd_api_key: current_user.realdebrid_api_key)

    render layout: false
  end

  def similar_results
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    @similar = begin
      result = TmdbService.new.recommendations_for_imdb_id(@imdb_id)
      result.success? ? result.data.first(20) : []
    rescue StandardError => error
      Rails.logger.warn("[ContentController] similar titles unavailable: #{error.message}")
      []
    end
    render partial: "content/similar_results", layout: false
  end

  # One provider per request. The browser starts these frames concurrently and
  # displays each result as soon as it arrives.
  def stream_results
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]&.to_i
    @episode = params[:episode]&.to_i
    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    entry = StreamProvider.provider(params[:provider], rd_api_key: current_user.realdebrid_api_key)
    unless entry
      @provider_id = params[:provider].to_s.gsub(/[^a-z0-9_-]/i, "").first(30).presence || "unknown"
      @provider_label = "Unknown provider"
      @streams = []
      @streams_error = "This stream provider is not configured."
      render partial: "content/stream_provider_results", layout: false
      return
    end

    @provider_id = entry.fetch(:id)
    @provider_label = entry.fetch(:label)
    result = entry.fetch(:service).streams(
      @imdb_id,
      @type,
      season: @season,
      episode: @episode,
      title: params[:title],
      preferred_languages: current_user.preferred_stream_languages,
      default_language: current_user.default_stream_language
    )

    # An expired/unauthorized RD key can make an RD-configured provider return
    # no list at all. Automatic/local mode retries that same provider without
    # RD configuration so local playback choices still appear.
    if (result.failure? || result.data.empty?) && LocalTorrentService.enabled? &&
       current_user.streaming_preference != "realdebrid" && current_user.has_realdebrid_key?
      local_entry = StreamProvider.provider(@provider_id, rd_api_key: nil)
      result = local_entry.fetch(:service).streams(
        @imdb_id,
        @type,
        season: @season,
        episode: @episode,
        title: params[:title],
        preferred_languages: current_user.preferred_stream_languages,
        default_language: current_user.default_stream_language
      ) if local_entry
    end

    @streams = result.success? ? result.data : []
    @streams_error = result.failure? ? result.error_message : nil
    @stream_title = params[:title]
    @poster_url = params[:poster_url]
    @duration = params[:duration]

    render partial: "content/stream_provider_results", layout: false
  end

  private

  # Trigger a full per-account stream cache warm in the background
  # (once per TTL).  cached_fetch no-ops on fresh entries, so this is
  # cheap for returning users.
  def prefetch_stream_cache
    return unless current_user.has_realdebrid_key?
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
      Rails.logger.error("[ContentController] stream prefetch error: #{e.message}")
    end
  end

  # Fetch streams from all configured providers in parallel, merging results.
  # Per-provider caching (stale-while-revalidate, keyed per-RealDebrid-
  # account) is handled inside each service's #streams — so this method
  # just merges the (possibly cached) provider results.  No controller-
  # level cache is applied here, because the previous shared Rails.cache
  # was keyed without the RD key and could surface one user's resolve URLs
  # (which embed their RD key) to another user.
  def fetch_provider_streams(imdb_id, type, season: nil, episode: nil, title: nil)
    fetch_provider_streams_uncached(imdb_id, type, season: season, episode: episode, title: title)
  end

  def fetch_provider_streams_uncached(imdb_id, type, season: nil, episode: nil, title: nil)
    providers = StreamProvider.providers(rd_api_key: current_user&.realdebrid_api_key)
    all_streams = []

    Rails.logger.info("[ContentController] fetch_provider_streams: #{providers.length} providers for #{imdb_id} (#{type})")

    # Query all providers concurrently — don't let a slow Comet block Torrentio.
    threads = providers.map do |provider|
      Thread.new do
        name = provider.class.name
        start = Time.current
        result = provider.streams(
          imdb_id,
          type,
          season: season,
          episode: episode,
          title: title,
          preferred_languages: current_user.preferred_stream_languages,
          default_language: current_user.default_stream_language
        )
        elapsed = ((Time.current - start) * 1000).round
        count = result.success? ? result.data.length : 0
        Rails.logger.info("[ContentController] #{name} returned #{count} streams in #{elapsed}ms")
        result
      end
    end
    results = threads.map(&:value)

    results.each do |result|
      all_streams.concat(result.data) if result&.success?
    end

    all_streams.empty? ? ServiceResult.failure("No streams available") : ServiceResult.success(StreamOrdering.sort(all_streams))
  end
end
