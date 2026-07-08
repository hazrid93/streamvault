# frozen_string_literal: true

# Person filmography: clicking a cast member's name on a content detail
# page searches TMDB for that person and lists their movies & shows.
class PersonController < ApplicationController
  before_action :authenticate_user!

  def index
    @name = params[:name].to_s.strip
    @items = []

    if @name.present?
      result = TmdbService.new.filmography_for_name(@name)
      @items = result.success? ? result.data : []
    end
  end
end