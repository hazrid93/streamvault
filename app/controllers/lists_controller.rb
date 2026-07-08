# frozen_string_literal: true

# User-created custom lists/collections.  Items are stored denormalised
# (title/poster/year/type at add time) so a list stays renderable even if
# the upstream metadata source changes — same pattern as
# WishlistEntry/LibraryEntry.
class ListsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_list, only: [:show, :destroy, :add_item, :remove_item]
  before_action :authorize_owner!, only: [:show, :destroy, :add_item, :remove_item]

  def index
    @lists = current_user.lists.left_joins(:list_items).order(:name)
  end

  def new
    @list = current_user.lists.new
    # Carry add-target context so the "create" form can bounce to adding
    # the pending item after the list exists.
    @pending_item = params.slice(:imdb_id, :title, :poster_url, :year, :content_type)
  end

  def create
    @list = current_user.lists.new(list_params)
    if @list.save
      # If we arrived from the add-to-list flow, attach the pending item.
      if params[:imdb_id].present? && params[:title].present?
        @list.list_items.create!(
          imdb_id: params[:imdb_id],
          title: params[:title],
          poster_url: params[:poster_url],
          year: params[:year],
          content_type: ListItem.content_types[params[:content_type]] || 0
        )
      end
      redirect_to list_path(@list), notice: "List created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @items = @list.list_items.order(created_at: :desc)
  end

  def destroy
    @list.destroy
    redirect_to lists_path, notice: "List deleted."
  end

  # Lists belonging to the current user, as JSON — consumed by the
  # add-to-list dropdown on poster cards.
  def index_json
    render json: current_user.lists.order(:name).as_json(only: [:id, :name])
  end

  # Add an item to an existing list.  Turbo-aware: responds with a
  # turbo_stream swap for in-page updates, falls back to redirect.
  def add_item
    item = @list.list_items.find_or_initialize_by(imdb_id: params[:imdb_id])
    item.assign_attributes(
      title: params[:title],
      poster_url: params[:poster_url],
      year: params[:year],
      content_type: ListItem.content_types[params[:content_type]] || 0
    )
    item.save

    respond_to do |format|
      format.html { redirect_to list_path(@list), notice: "Added to #{@list.name}." }
      format.turbo_stream { head :ok }
      format.json { render json: { ok: true } }
    end
  end

  def remove_item
    @list.list_items.where(imdb_id: params[:imdb_id]).destroy_all
    redirect_to list_path(@list), notice: "Removed from #{@list.name}.", status: :see_other
  end

  private

  def set_list
    @list = current_user.lists.find(params[:id])
  end

  def authorize_owner!
    return if @list.user_id == current_user.id
    redirect_to lists_path, alert: "That list isn't yours."
  end

  def list_params
    params.require(:list).permit(:name)
  end
end