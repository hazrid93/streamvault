require "rails_helper"

RSpec.describe "Remember cookie refresh", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  def remember_cookie_was_set?
    Array(response.headers["Set-Cookie"]).join("\n").include?("remember_user_token=")
  end

  it "creates a remember cookie for an authenticated session that lacks one" do
    sign_in user

    get settings_path

    expect(response).to have_http_status(:ok)
    expect(remember_cookie_was_set?).to be(true)
    expect(user.reload.remember_created_at).to be_present
  end

  it "does not refresh a recently issued remember cookie" do
    sign_in user
    get settings_path

    get settings_path

    expect(response).to have_http_status(:ok)
    expect(remember_cookie_was_set?).to be(false)
  end

  it "refreshes a remember cookie after 30 days" do
    travel_to 31.days.ago do
      sign_in user
      get settings_path
    end

    get settings_path

    expect(response).to have_http_status(:ok)
    expect(remember_cookie_was_set?).to be(true)
  end

  it "does not create a remember cookie for signed-out visitors" do
    get settings_path

    expect(response).to redirect_to(new_user_session_path)
    expect(remember_cookie_was_set?).to be(false)
  end
end
