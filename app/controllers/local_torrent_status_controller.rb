# frozen_string_literal: true

class LocalTorrentStatusController < ApplicationController
  before_action :authenticate_user!

  def show
    result = LocalTorrentService.new.live_status(params[:info_hash], session_token: params[:session_token])
    if result.success?
      render json: result.data
    else
      render json: { error: result.error_message }, status: :not_found
    end
  end

  def stop
    result = LocalTorrentService.new.stop(
      info_hash: params[:info_hash],
      session_token: params[:session_token]
    )
    if result.success?
      head :no_content
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
    end
  end
end
