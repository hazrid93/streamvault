# frozen_string_literal: true

class WishlistController < ApplicationController
  before_action :authenticate_user!
  before_action :set_entry, only: [:destroy, :move_to_library]

  def index
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 100)

    entries = policy_scope(WishlistEntry)
    entries = entries.by_type(params[:type]) if params[:type].present?
    entries = entries.recently_added

    @total = entries.count
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [@total_pages, 1].max)
    @entries = entries.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def create
    @entry = current_user.wishlist_entries.build(entry_params)

    if @entry.save
      respond_to do |format|
        format.html { redirect_to wishlist_index_path, notice: "#{@entry.title} added to wishlist." }
        format.json { render json: { ok: true, kind: "wishlist", destroy_url: wishlist_path(@entry), notice: "#{@entry.title} added to wishlist." } }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: wishlist_index_path, alert: @entry.errors.full_messages.join(", ") }
        format.json { render json: { ok: false, error: @entry.errors.full_messages.join(", ") }, status: :unprocessable_content }
      end
    end
  end

  def destroy
    title = @entry.title
    @entry.destroy
    respond_to do |format|
      format.html { redirect_to wishlist_index_path, notice: "#{title} removed from wishlist." }
      format.json { render json: { ok: true, kind: "wishlist" } }
    end
  end

  def move_to_library
    # find_or_initialize_by + assign_attributes so an existing library
    # entry gets its metadata refreshed from the wishlist entry (the
    # old find_or_create_by! skipped the block for existing records,
    # silently keeping stale title/poster/year).  Redirect outside the
    # transaction so the DB connection isn't held across response setup.
    library_entry = ActiveRecord::Base.transaction do
      entry = current_user.library_entries.find_or_initialize_by(imdb_id: @entry.imdb_id)
      entry.assign_attributes(
        content_type: @entry.content_type,
        title: @entry.title,
        poster_url: @entry.poster_url,
        year: @entry.year
      )
      entry.save!
      @entry.destroy!
      entry
    end
    redirect_to library_index_path, notice: "#{library_entry.title} moved to library."
  end

  private

  def set_entry
    @entry = current_user.wishlist_entries.find(params[:id])
  end

  def entry_params
    params.require(:wishlist_entry).permit(:content_type, :imdb_id, :title, :poster_url, :year)
  end
end
