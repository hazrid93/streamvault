# frozen_string_literal: true

# Backward-compatible endpoint for existing /search bookmarks. Discovery now
# lives on /browse so search and catalog filters share one experience.
class SearchController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_to browse_path(request.query_parameters), status: :found
  end
end