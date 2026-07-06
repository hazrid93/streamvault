# frozen_string_literal: true

class WatchHistoryController < ApplicationController
  before_action :authenticate_user!

  def index
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 100)

    # Use policy_scope for consistency with library/wishlist/home — if a
    # future policy adds a scope condition (e.g. hide soft-deleted), this
    # controller will honour it rather than silently bypassing it.
    entries = policy_scope(WatchHistoryEntry).recently_watched

    @total = entries.count
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [@total_pages, 1].max)
    @entries = entries.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def destroy
    entry = current_user.watch_history_entries.find(params[:id])

    # WatchHistoryEntry has no callbacks, so delete_all is equivalent to
    # destroy_all but avoids instantiating N AR objects for the delete.
    if entry.movie?
      current_user.watch_history_entries
        .where(content_type: :movie, imdb_id: entry.imdb_id)
        .delete_all
    else
      current_user.watch_history_entries
        .where(content_type: :episode, show_imdb_id: entry.show_imdb_id)
        .delete_all
    end

    redirect_back fallback_location: watch_history_index_path, status: :see_other, notice: "Removed from history."
  end

  def clear_all
    # Wrap both deletes in a transaction so a crash between them can't
    # leave watch_history cleared but episode_progresses intact (or vice
    # versa), which would put "Continue Watching" out of sync with
    # episode-level progress.  delete_all skips callbacks (there are none).
    ActiveRecord::Base.transaction do
      current_user.watch_history_entries.delete_all
      current_user.episode_progresses.delete_all
    end
    redirect_to watch_history_index_path, notice: "Watch history cleared."
  end
end
