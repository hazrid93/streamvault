# frozen_string_literal: true

class LocalTorrentStatusController < ApplicationController
  before_action :authenticate_user!

  def show
    result = LocalTorrentService.new.live_status(params[:info_hash])
    if result.success?
      render json: result.data
    else
      render json: { error: result.error_message }, status: :not_found
    end
  end
end
