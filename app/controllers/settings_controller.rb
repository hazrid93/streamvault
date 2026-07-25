# frozen_string_literal: true

class SettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_local_torrent_status, only: :show

  def show
    @user = current_user
  end

  def update
    @user = current_user
    attributes = settings_params
    verify_realdebrid_key = attributes[:realdebrid_api_key].present?

    # Preserve the existing RealDebrid key when the field is left blank.
    attributes.delete(:realdebrid_api_key) unless verify_realdebrid_key

    if @user.update(attributes)
      redirect_after_settings_update(verify_realdebrid_key)
    else
      load_local_torrent_status
      render :show, status: :unprocessable_entity
    end
  end

  def clear_local_torrents
    result = LocalTorrentService.new.clear!
    if result.success?
      redirect_to settings_path, notice: "Temporary local media cleared."
    else
      redirect_to settings_path, alert: result.error_message
    end
  end

  def update_pin
    @user = current_user
    attributes = pin_params

    unless @user.valid_pin?(attributes[:current_pin])
      @user.errors.add(:current_pin, "is incorrect")
      load_local_torrent_status
      return render :show, status: :unprocessable_entity
    end

    if @user.set_pin(attributes[:pin], attributes[:pin_confirmation])
      redirect_to settings_path, notice: "PIN updated successfully."
    else
      load_local_torrent_status
      render :show, status: :unprocessable_entity
    end
  end

  private

  def redirect_after_settings_update(verify_realdebrid_key)
    unless verify_realdebrid_key
      return redirect_to settings_path, notice: "Settings updated."
    end

    result = RealDebridService.new(@user.realdebrid_api_key).verify_key
    if result.success?
      redirect_to settings_path, notice: "Settings updated. RealDebrid connection verified."
    else
      redirect_to settings_path, alert: "Settings saved, but RealDebrid key could not be verified: #{result.error_message}"
    end
  end

  def settings_params
    params.require(:user).permit(:realdebrid_api_key, :streaming_preference, :default_language, preferred_languages: [])
  end

  def pin_params
    params.permit(:current_pin, :pin, :pin_confirmation)
  end

  def load_local_torrent_status
    @local_torrent_status = LocalTorrentService.new.status
  end
end
