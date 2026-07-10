class ApplicationController < ActionController::Base
  include Devise::Controllers::Rememberable

  REMEMBER_COOKIE_REFRESH_INTERVAL = 30.days

  before_action :refresh_remember_cookie

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Helper for scoping queries through policies
  def policy_scope(relation)
    authorized_scope(relation, type: :relation)
  end
  helper_method :policy_scope
  helper_method :signups_enabled?

  # Whether new user self-registration is enabled via ENV
  def signups_enabled?
    ENV["ENABLE_SIGNUPS"] == "true"
  end

  private

  # Browsers cap persistent cookies (typically around 400 days), regardless of
  # Devise's configured lifetime. Refresh active users' remember cookie every
  # 30 days so its browser-enforced expiry keeps moving forward.
  def refresh_remember_cookie
    return unless user_signed_in?
    return unless remember_cookie_refresh_due?(current_user)

    remember_me(current_user)
  end

  def remember_cookie_refresh_due?(user)
    scope = Devise::Mapping.find_scope!(user)
    cookie_value = cookies.signed[remember_key(user, scope)]
    generated_at = cookie_value&.third

    generated_at.blank? || Time.at(generated_at.to_f) <= REMEMBER_COOKIE_REFRESH_INTERVAL.ago
  end

  # Rescue from authorization failures
  rescue_from ActionPolicy::Unauthorized do |exception|
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "You are not authorized to perform this action." }
      format.json { render json: { error: "Unauthorized" }, status: :forbidden }
    end
  end

  # Rescue from record not found
  rescue_from ActiveRecord::RecordNotFound do |exception|
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "Record not found." }
      format.json { render json: { error: "Not found" }, status: :not_found }
    end
  end
end
