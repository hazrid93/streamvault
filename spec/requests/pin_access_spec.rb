# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PIN access", type: :request do
  describe "first-run setup" do
    it "creates the singleton, stores a PIN digest, and signs in" do
      expect {
        post user_session_path, params: { pin: "1234", pin_confirmation: "1234" }
      }.to change(User, :count).by(1)

      user = User.first
      expect(response).to redirect_to(root_path)
      expect(user.email).to eq("streamvault@localhost")
      expect(user.valid_pin?("1234")).to be(true)
      expect(user.pin_digest).not_to eq("1234")

      get settings_path
      expect(response).to have_http_status(:ok)
    end

    it "sets the PIN on the existing operator without replacing their data" do
      user = create(:user, display_name: "Existing operator", realdebrid_api_key: "existing-key")

      expect {
        post user_session_path, params: { pin: "1234", pin_confirmation: "1234" }
      }.not_to change(User, :count)

      expect(response).to redirect_to(root_path)
      expect(user.reload.display_name).to eq("Existing operator")
      expect(user.realdebrid_api_key).to eq("existing-key")
      expect(user.valid_pin?("1234")).to be(true)
    end

    it "rejects PINs that are not exactly four matching digits" do
      post user_session_path, params: { pin: "12ab", pin_confirmation: "9999" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(User.count).to eq(0)
      expect(response.body).to include("must be exactly four digits")
      expect(response.body).to include("does not match PIN")
    end
  end

  describe "unlock and lock" do
    let!(:user) { create(:user).tap { |record| record.set_pin("1234", "1234") } }

    it "rejects the wrong PIN and unlocks with the configured PIN" do
      post user_session_path, params: { pin: "9999" }
      expect(response).to have_http_status(:unprocessable_entity)

      post user_session_path, params: { pin: "1234" }
      expect(response).to redirect_to(root_path)

      get settings_path
      expect(response).to have_http_status(:ok)
    end

    it "locks the current browser session" do
      sign_in user

      delete destroy_user_session_path
      expect(response).to redirect_to(new_user_session_path)

      get settings_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
